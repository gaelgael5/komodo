# Agents IA — serveur MCP pour Komodo

Déploiement de [`MP-Tool/komodo-mcp-server`](https://github.com/MP-Tool/komodo-mcp-server)
(v1.x) : un serveur [MCP](https://modelcontextprotocol.io) HTTP persistant qui
expose l'API Komodo aux assistants IA (Claude Code, Claude Desktop, VS Code…).

## Modèle de sécurité (3 couches)

1. **Permissions Komodo** (garde-fou principal) : l'auth MCP est activée —
   chaque client se connecte avec un **compte Komodo** et chaque appel d'outil
   est vérifié par Komodo avec les permissions de ce compte. Un agent avec le
   compte `svc-agents` ne peut rien faire de plus que `svc-agents`.
2. **Surface d'outils réduite** : les outils de niveau `komodo:admin`
   (create/update/delete/prune), le terminal distant (`komodo_exec`) et la
   gestion des clés d'API sont retirés de la liste des outils, côté serveur
   (`MCP_TOOLS_EXCLUDED_*` dans `mcp.env`). Il ne reste que
   `komodo:read` (list/info/logs/stats) et `komodo:operate`
   (deploy/start/stop/restart).
3. **Confirmations destructives** : les actions restantes considérées
   sensibles demandent une confirmation humaine dans le client MCP
   (`MCP_CONFIRM_DESTRUCTIVE=true`, refus si le client ne sait pas demander).

S'y ajoute la redaction automatique des secrets dans toutes les sorties
d'outils (activée par défaut en amont).

## 1. Créer le compte Komodo dédié aux agents

Dans l'UI Komodo :

1. **Settings → Users → New User** : créer un *service user* `svc-agents`
   (pas de rôle admin). Activer le compte (`Enabled`).
2. Lui donner des droits **minimaux et ciblés**, de préférence via un
   *User Group* versionné dans [`../syncs/users.toml`](../syncs/users.toml)
   (modèle commenté) : `Read` sur les Servers, `Execute` sur les seules
   Stacks/Deployments que les agents doivent pouvoir manœuvrer.
   `Execute` permet d'agir (deploy/start/stop) **sans** modifier la config.
3. Ne jamais donner : rôle admin, `Write`, ni de permissions sur les
   ressources sensibles (Resource Syncs, Builders…).

> Pas besoin de clé d'API dans la configuration recommandée : les clients
> s'authentifient en direct avec le compte. Une clé d'API `svc-agents` ne
> sert qu'au mode stdio (voir plus bas).

## 2. Déployer le serveur MCP (sur l'hôte du Core)

```bash
./dev-deploy.sh mcp          # questions : URL du Core, port
scripts/deploy-mcp.sh
```

L'endpoint MCP est alors : `http://<ip-de-l-hote>:8000/mcp`
(healthcheck : `http://<ip>:8000/ready`).

## 3. Connecter un client

### Claude Code

```bash
claude mcp add --transport http komodo http://<ip-de-l-hote>:8000/mcp
```

Puis `/mcp` dans Claude Code → `komodo` → *Authenticate* : une page de
connexion s'ouvre, s'identifier avec `svc-agents` (ou son propre compte —
chacun garde ses propres permissions).

### Autres clients

Claude Desktop, VS Code / GitHub Copilot : exemples prêts à l'emploi dans
[`examples/` du dépôt amont](https://github.com/MP-Tool/komodo-mcp-server/tree/main/examples).

### Alternative stdio (sans serveur déployé)

Un client local peut lancer le serveur en stdio avec une clé d'API de
`svc-agents` (profil de l'utilisateur → API Keys) :

```json
{
  "mcpServers": {
    "komodo": {
      "command": "docker",
      "args": ["run", "--rm", "-i", "-e", "MCP_TRANSPORT=stdio",
               "-e", "KOMODO_URL", "-e", "KOMODO_API_KEY", "-e", "KOMODO_API_SECRET",
               "ghcr.io/mp-tool/komodo-mcp-server:1"],
      "env": {
        "KOMODO_URL": "http://<ip-du-core>:9120",
        "KOMODO_API_KEY": "<clé>",
        "KOMODO_API_SECRET": "<secret>"
      }
    }
  }
}
```

⚠️ En stdio, les exclusions d'outils de `mcp.env` ne s'appliquent pas
(c'est le client qui lance le serveur) : les permissions du compte
`svc-agents` restent alors le seul garde-fou — raison de plus pour les
garder minimales.

## Mise à jour

`scripts/update.sh` sur l'hôte met aussi à jour le serveur MCP si
`mcp/mcp.env` est présent. L'image est épinglée sur le tag majeur `1`.

## Révocation

- Couper tous les agents : désactiver le compte `svc-agents` dans l'UI
  (ou arrêter la stack : `docker compose -p komodo-mcp -f mcp/compose.yaml --env-file mcp/mcp.env down`).
- Révoquer un seul agent en stdio : supprimer sa clé d'API.
