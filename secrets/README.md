# Secrets chiffrés (sops + age)

Ce dossier reçoit les fichiers d'environnement **chiffrés** avec
[sops](https://github.com/getsops/sops) et [age](https://github.com/FiloSottile/age).
Seuls les fichiers `*.env.sops` sont commités ; tout `.env` en clair est
exclu par le `.gitignore` et bloqué par gitleaks (pre-commit).

Intérêt : après un `git clone`, `./dev-deploy.sh` restaure les paramètres
exacts d'une machine (mots de passe de base, secrets JWT…) au lieu d'en
régénérer de nouveaux — indispensable pour réinstaller le Core sans perdre
la cohérence avec la base existante.

## Mise en place (une fois)

```bash
./dev-deploy.sh init-sops
```

Ce qui est fait :

1. génère une clé age dans `~/.config/sops/age/keys.txt` (si absente) ;
2. inscrit la clé **publique** (destinataire) dans `.sops.yaml` (commité).

> ⚠️ **Sauvegarder `~/.config/sops/age/keys.txt` hors du dépôt**
> (gestionnaire de mots de passe, coffre…). Sans elle, les `*.env.sops`
> sont indéchiffrables.

Prérequis : binaires `sops` et `age` installés. Sur Debian/Ubuntu :

```bash
apt install -y age
```

```bash
curl -sSL -o /usr/local/bin/sops \
  https://github.com/getsops/sops/releases/download/v3.11.0/sops-v3.11.0.linux.amd64 \
  && chmod +x /usr/local/bin/sops
```

## Utilisation courante

- `./dev-deploy.sh core` / `./dev-deploy.sh periphery` proposent
  automatiquement de chiffrer le fichier généré ici (puis `git add` + commit).
- Au prochain clone, les mêmes commandes détectent le fichier chiffré
  et le **déchiffrent** au lieu de poser les questions.

Commandes manuelles si besoin :

```bash
# Chiffrer
sops --config /dev/null --encrypt --input-type dotenv --output-type dotenv \
  --age "$(grep -Eo 'age1[0-9a-z]+' .sops.yaml | head -1)" \
  core/compose.env > secrets/core.env.sops
```

```bash
# Déchiffrer / inspecter
sops --decrypt --input-type dotenv --output-type dotenv secrets/core.env.sops
```

## Nommage

| Fichier                          | Contenu                                   |
| -------------------------------- | ----------------------------------------- |
| `core.env.sops`                  | paramètres du Core (`core/compose.env`)    |
| `periphery.<hostname>.env.sops`  | paramètres du Periphery de l'hôte `<hostname>` |
