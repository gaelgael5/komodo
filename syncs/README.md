# Komodo as code — Resource Syncs

Ce dossier contient les déclarations TOML des ressources Komodo
(serveurs, stacks…). Komodo les compare aux ressources existantes (diff)
et propose les créations / mises à jour correspondantes.

Doc amont : <https://komo.do/docs/automate/sync-resources>

## Conventions de nommage

- **Serveurs** (`servers.toml`) : le `name` est le hostname de la machine,
  identique au `PERIPHERY_CONNECT_AS` de l'hôte. Minuscules, tirets.
- **Stacks** (`stacks.toml`) : nom court du service (`immich`, `grafana`…),
  minuscules, tirets. Pas de vocabulaire interne : des noms neutres et parlants.
- **Tags** : au minimum `homelab` ; ajouter un tag par usage si besoin
  (`media`, `monitoring`…). Les tags permettent de filtrer les syncs
  (`Match Tags`) et les vues UI.
- Un fichier par type de ressource. Si un type grossit trop, le scinder
  (ex. `stacks.media.toml`) — Komodo lit tous les fichiers du dossier.

## Workflow Git → Sync

1. Modifier les TOML dans une branche, ouvrir une PR (ou commit direct sur `main`).
2. Komodo (Resource Sync) poll le dépôt — ou reçoit un webhook — et calcule le diff.
3. Dans l'UI, la page du Resource Sync affiche les **Pending Changes**.
4. **Exécuter la sync manuellement** après relecture (`Execute Sync`).

## Créer le Resource Sync dans Komodo (une fois, après installation du Core)

Dans l'UI : **Syncs → New Resource Sync**, puis dans la config :

| Champ           | Valeur                                    |
| --------------- | ----------------------------------------- |
| Name            | `homelab`                                 |
| Git Provider    | `github.com`                              |
| Repo            | `gaelgael5/komodo`                        |
| Branch          | `main`                                    |
| Resource Path   | `syncs`                                   |

Équivalent déclaratif (qu'on peut coller dans un sync « racine » créé en UI) :

```toml
[[resource_sync]]
name = "homelab"
[resource_sync.config]
repo = "gaelgael5/komodo"
branch = "main"
resource_path = ["syncs"]
```

> Si le dépôt est privé : déclarer un compte Git dans Komodo
> (Settings → Providers) et renseigner `git_account`.

### Webhook (optionnel)

Pour que Komodo recalcule le diff à chaque push, ajouter sur le dépôt GitHub
(Settings → Webhooks) un webhook :

- **URL** : `https://<KOMODO_HOST>/listener/github/sync/homelab/refresh`
- **Content-type** : `application/json`
- **Secret** : la valeur de `KOMODO_WEBHOOK_SECRET`

`/refresh` ne fait que recalculer le diff (sans appliquer). L'exécution
automatique au push (`/sync`) existe, mais garder l'exécution manuelle
tant que le dépôt n'est pas stabilisé.

## ⚠️ Garde-fou : option `delete`

La config d'un Resource Sync possède une option `delete` qui **supprime de
Komodo toute ressource non déclarée dans ces fichiers**. Elle est
**désactivée par défaut et doit le rester** tant que l'inventaire complet
n'est pas décrit ici : l'activer avec un `servers.toml`/`stacks.toml`
incomplet supprimerait les ressources créées à la main dans l'UI.

Ne l'activer (en toute connaissance de cause) que le jour où ce dossier
est la source de vérité exhaustive.
