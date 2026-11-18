# Komodo — infrastructure du homelab

Dépôt d'installation et de configuration de [Komodo v2](https://komo.do)
(pilotage des hôtes Docker du homelab) : composes, scripts d'installation,
« Komodo as code » (Resource Syncs) et secrets chiffrés.

## Architecture

- **1 Core** central (UI + API + MongoDB + Periphery local), installé une
  seule fois sur une VM dédiée.
- **1 Periphery** par hôte Docker supplémentaire. En v2, c'est le Periphery
  qui ouvre une **websocket sortante** vers le Core (`ws://<core>:9120`),
  authentifiée par paire de clés : **aucun port à ouvrir** sur les hôtes
  pilotés, seul le port `9120` du Core est exposé.

```text
                ┌─────────────────────────────┐
                │        VM Core              │
                │  MongoDB ── Komodo Core :9120 ◄──── UI / API / webhooks
                │              ▲              │
                │   Periphery ─┘ (local)      │
                └──────────────▲──────────────┘
                 ws sortante   │   ws sortante
            ┌──────────────────┴───────────────────┐
   ┌────────┴────────┐                    ┌────────┴────────┐
   │  hôte Docker A  │                    │  hôte Docker B  │
   │  Periphery      │                    │  Periphery      │
   └─────────────────┘                    └─────────────────┘
```

## Contenu du dépôt

```text
.
├── dev-deploy.sh             # point d'entrée après clone : construit les fichiers de paramètres
├── core/
│   ├── compose.yaml          # MongoDB 8 + Core + Periphery local
│   └── compose.env.example   # modèle (les vraies valeurs vont dans compose.env, jamais commité)
├── periphery/
│   ├── compose.yaml          # Periphery seul, pour les autres hôtes
│   └── periphery.env.example
├── syncs/                    # "Komodo as code" : Resource Syncs en TOML
├── secrets/                  # paramètres chiffrés sops+age (*.env.sops commités)
├── scripts/
│   ├── bootstrap-core.sh     # première installation du Core
│   ├── add-periphery.sh      # enrôler un nouvel hôte
│   ├── update.sh             # pull + redéploiement
│   └── backup-restore.md     # sauvegarde / restauration de la base
├── .sops.yaml                # destinataire age des secrets
├── .gitignore                # exclut tout .env en clair, clés privées, backups
└── .pre-commit-config.yaml   # gitleaks + shellcheck avant chaque commit
```

## Prérequis

| Quoi | Détail |
| --- | --- |
| Docker + compose v2 | sur chaque hôte (`docker compose version` ≥ 2.24) |
| CPU avec AVX | **VM du Core uniquement** : MongoDB 5+ l'exige. Sur Proxmox, type de CPU de la VM = `host` |
| Réseau | les hôtes pilotés doivent joindre le Core sur `9120` (sortant) ; rien d'entrant chez eux. Le port `9120` doit être libre sur la VM du Core (`ss -tlnp | grep 9120`) |
| `git` | sur chaque hôte (clone du dépôt) |
| `sops` + `age` | optionnel mais recommandé, pour les secrets chiffrés (voir [`secrets/README.md`](secrets/README.md)) |
| `pre-commit` | sur la machine où l'on commite : `pipx install pre-commit && pre-commit install` |

## 1. Installer le Core

Sur la VM du Core :

```bash
git clone https://github.com/gaelgael5/komodo.git
cd komodo
```

```bash
./dev-deploy.sh init-sops   # optionnel (recommandé) : secrets chiffrés
```

```bash
./dev-deploy.sh core        # questions : URL publique, TZ, nom du Server, admin…
```

Réponses attendues :

- **URL publique (`KOMODO_HOST`)** : URL complète **avec schéma**. Le nom DNS
  prévu (`https://komodo.example.com`) s'il existe déjà, sinon
  `http://<ip-du-core>:9120` en attendant (bascule DNS : voir section 6).
  Le script ajoute `http://` si le schéma est oublié.
- **Nom du premier Server** : le hostname proposé par défaut convient.

> Les mots de passe (base, admin) et secrets (JWT, webhook) sont générés
> aléatoirement ; le mot de passe admin est affiché **une seule fois**.
> Si sops est configuré, le script propose de chiffrer le résultat dans
> `secrets/core.env.sops` → le commiter pour pouvoir réinstaller à l'identique.

```bash
scripts/bootstrap-core.sh
```

Le script valide le compose, crée `/etc/komodo/{stacks,syncs,backups}`,
démarre la pile (`docker compose -p komodo -f core/compose.yaml --env-file
core/compose.env up -d`), attend que l'UI réponde et affiche la clé publique
du Core.

Première connexion : `http://<ip-du-core>:9120`, avec le compte admin créé
par `dev-deploy.sh`. Vérifier que le Server local est **OK**.

## 2. Enrôler un hôte Docker (Periphery)

**Sur le Core (UI)** — une fois :

1. `Settings → Onboarding Keys → New` ;
2. copier la clé `O-…` (affichée une seule fois). Les clés d'enrôlement sont
   réutilisables ; on peut leur donner une expiration et des tags par défaut.

**Sur le nouvel hôte** :

```bash
git clone https://github.com/gaelgael5/komodo.git
cd komodo
scripts/add-periphery.sh
```

Le script demande (ou accepte en options) :

- l'adresse du Core : `ws://<ip-du-core>:9120` en direct, ou
  `wss://komodo.example.com` derrière un reverse proxy TLS ;
- le nom du Server (`PERIPHERY_CONNECT_AS`) — convention : le hostname ;
- la clé d'enrôlement `O-…`.

Équivalent non interactif :

```bash
scripts/add-periphery.sh --yes \
  --core-address ws://192.168.1.10:9120 \
  --name "$(hostname)" \
  --onboarding-key "O-..."
```

**Comment ça marche** (v2) : au premier contact, le Periphery crée son Server
dans Komodo sous le nom donné, génère sa propre paire de clés et envoie sa clé
publique au Core ; sa clé privée ne quitte jamais l'hôte. La clé publique du
Core est épinglée localement (`/config/keys/core.pub`, écrite à la première
connexion — *trust-on-first-use*). Pour éviter le TOFU, coller la clé publique
affichée par `bootstrap-core.sh` à la question « clé publique du Core » du
script (elle est alors inscrite en dur dans `PERIPHERY_CORE_PUBLIC_KEYS`).

**Après enrôlement** :

1. vérifier dans l'UI que le Server passe **OK** ;
2. vider `PERIPHERY_ONBOARDING_KEY` dans `periphery/periphery.env`
   (la clé ne sert qu'au premier contact) et relancer `scripts/add-periphery.sh` ;
3. déclarer l'hôte dans [`syncs/servers.toml`](syncs/README.md) et commiter.

## 3. Komodo as code (Resource Syncs)

Les ressources Komodo (serveurs, stacks…) sont déclarées en TOML dans
[`syncs/`](syncs/README.md), qui explique les conventions, la création du
Resource Sync dans l'UI et le webhook GitHub.

> ⚠️ L'option `delete` des Resource Syncs (suppression des ressources non
> déclarées) reste **désactivée** — voir le garde-fou dans
> [`syncs/README.md`](syncs/README.md).

## 4. Mises à jour

Sur chaque machine concernée :

```bash
scripts/update.sh          # git pull + docker compose pull + up -d
```

Les versions sont volontairement figées : `mongo:8` et
`COMPOSE_KOMODO_IMAGE_TAG="2"` (suit les patchs de la v2 sans saut de
majeure). Pour épingler plus finement, mettre un tag précis (ex. `"2.1.4"`)
dans le fichier env, tester, puis propager.

## 5. Sauvegarde / restauration

Sauvegarde quotidienne automatique dans `/etc/komodo/backups` (14 jours).
Procédure complète, y compris reconstruction du Core de zéro :
[`scripts/backup-restore.md`](scripts/backup-restore.md).

## 6. DNS et reverse proxy (à faire à la main)

- Créer l'entrée DNS choisie pour `KOMODO_HOST` (ex. `komodo.example.com`).
- Déclarer un virtual host sur le reverse proxy existant vers
  `http://<ip-du-core>:9120`, avec **support websocket** (HTTP upgrade) —
  nécessaire pour l'UI et pour les Periphery en `wss://`.
- Si les webhooks GitHub doivent arriver depuis Internet, n'exposer
  publiquement que le chemin `/listener` (le reste de l'UI peut rester
  accessible uniquement depuis le LAN/VPN).

**Basculer `KOMODO_HOST` une fois le DNS en place** (si l'installation a été
faite avec l'IP) :

```bash
sed -i 's|^KOMODO_HOST=.*|KOMODO_HOST=https://komodo.example.com|' core/compose.env
```

```bash
scripts/update.sh --no-pull
```

Si les secrets chiffrés sont utilisés, rechiffrer pour que `secrets/core.env.sops`
reste le reflet de la réalité (commande dans [`secrets/README.md`](secrets/README.md)),
puis commiter.

## 7. Préparation pour les agents IA (MCP) — documentation seulement

L'accès des agents IA passera par l'API Komodo via un serveur MCP tiers
([`MP-Tool/komodo-mcp-server`](https://github.com/MP-Tool/komodo-mcp-server)).
Rien n'est installé par ce dépôt ; le jour venu :

1. **Créer un utilisateur dédié** dans Komodo : `Settings → Users → New User`
   (type *Service User*), nommé par ex. `svc-agents`. Ne pas lui donner le
   rôle admin.
2. **Limiter ses droits** : par défaut un nouvel utilisateur ne voit rien
   (`KOMODO_TRANSPARENT_MODE=false`). Lui accorder au cas par cas des
   permissions `Read` / `Execute` sur les seules ressources utiles — de
   préférence via un *User Group* déclaré dans les syncs, par ex. :

   ```toml
   [[user_group]]
   name = "agents-ia"
   users = ["svc-agents"]
   all.Server = "Read"
   all.Stack = { level = "Execute" }   # Execute = agir, sans modifier la config
   ```

   Ne pas donner `Write` (modification de config) ni accès aux `Settings`.
3. **Créer une clé d'API** pour cet utilisateur (profil de l'utilisateur →
   *API Keys*) : une paire clé/secret dédiée, révocable indépendamment.
4. **Restreindre le serveur MCP** : lors de sa configuration, n'activer que
   les niveaux `komodo:read` et `komodo:operate` (lecture et opérations
   start/stop/deploy), jamais le niveau d'administration/écriture — se
   référer au README du serveur MCP pour la variable exacte. Les permissions
   Komodo côté utilisateur restent le garde-fou principal : même un MCP mal
   configuré ne peut pas dépasser les droits de `svc-agents`.

## Règles du dépôt

- **Aucun secret en clair** : les `.env` sont générés localement
  (mode 600, gitignorés) ; seuls les `*.env.sops` chiffrés sont commités.
  `pre-commit` + gitleaks bloquent toute fuite avant commit.
- Scripts bash : `set -euo pipefail`, idempotents, validés `shellcheck`.
- Composes validés par `docker compose … config -q` avant commit.
- Commits en [Conventional Commits](https://www.conventionalcommits.org/fr/)
  (`feat:`, `fix:`, `docs:`…), petits et explicites.
- Noms et valeurs neutres (pas de vocabulaire interne).
