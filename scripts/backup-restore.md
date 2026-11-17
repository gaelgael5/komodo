# Sauvegarde et restauration de la base Komodo

Doc amont : <https://komo.do/docs/setup/backup>

## Ce qui est déjà en place

- Le compose du Core monte `COMPOSE_KOMODO_BACKUPS_PATH`
  (défaut : `/etc/komodo/backups`) sur `/backups` dans le conteneur Core.
- Komodo crée automatiquement au premier démarrage la Procedure
  **« Backup Core Database »**, planifiée tous les jours à 01:00.
- Chaque sauvegarde est un dossier daté de dumps gzip ; les **14 dernières**
  sont conservées (réglable via `KOMODO_CLI_MAX_BACKUPS` dans l'environnement
  du Core).

```text
/etc/komodo/backups
├── 2025-08-12_03-00-01/
│   ├── Action.gz
│   ├── Alerter.gz
│   └── ...
├── 2025-08-13_03-00-01/
└── Stats.gz
```

> ⚠️ Les dumps ne sont **pas chiffrés**. Si un outil externe les copie hors
> de l'hôte (PBS, restic, rsync…), s'assurer qu'il chiffre de son côté.
> Penser à inclure `/etc/komodo/backups` dans la sauvegarde de la VM.

## Déclencher une sauvegarde à la main

Dans l'UI : **Procedures → Backup Core Database → Run**. Ou en CLI sur l'hôte
du Core :

```bash
docker compose -p komodo -f core/compose.yaml --env-file core/compose.env \
  exec core km database backup -y
```

## Restauration

La restauration utilise l'image `ghcr.io/moghtech/komodo-cli`. Elle écrit dans
la base **cible** sans la vider : pour repartir proprement, restaurer dans une
base vide (ou supprimer la base au préalable).

### Scénario : reconstruire le Core de zéro

1. Recréer la VM / le LXC (CPU `host` pour AVX), installer Docker.
2. `git clone` de ce dépôt, puis restaurer les paramètres :

   ```bash
   ./dev-deploy.sh core   # déchiffre secrets/core.env.sops si présent
   ```

   > Les identifiants MongoDB doivent être **ceux d'origine** — c'est tout
   > l'intérêt des secrets chiffrés dans `secrets/`.

3. Remettre en place les fichiers de `/etc/komodo/backups`
   (depuis la sauvegarde de la VM ou le stockage externe).
4. Démarrer la pile : `scripts/bootstrap-core.sh`.
5. Arrêter le Core le temps de la restauration (la base doit rester up) :

   ```bash
   docker compose -p komodo -f core/compose.yaml --env-file core/compose.env stop core periphery
   ```

6. Restaurer la dernière sauvegarde dans la base `komodo` :

   ```bash
   docker run --rm --network komodo_default \
     -v /etc/komodo/backups:/backups \
     -e KOMODO_CLI_DATABASE_TARGET_ADDRESS=mongo:27017 \
     -e KOMODO_CLI_DATABASE_TARGET_USERNAME="<KOMODO_DATABASE_USERNAME>" \
     -e KOMODO_CLI_DATABASE_TARGET_PASSWORD="<KOMODO_DATABASE_PASSWORD>" \
     -e KOMODO_CLI_DATABASE_TARGET_DB_NAME=komodo \
     ghcr.io/moghtech/komodo-cli km database restore -y
     # ajouter : --restore-folder 2025-08-14_03-00-01  pour un dossier précis
   ```

7. Relancer : `docker compose -p komodo -f core/compose.yaml --env-file core/compose.env up -d`.
8. Vérifier l'UI, puis que chaque Periphery distant repasse « OK »
   (les clés des Servers sont dans la base restaurée ; en cas de blocage,
   ré-enrôler l'hôte concerné avec une nouvelle Onboarding Key).

## À vérifier régulièrement

- [ ] des dossiers datés récents existent dans `/etc/komodo/backups` ;
- [ ] la sauvegarde VM / externe inclut bien ce chemin ;
- [ ] un test de restauration a été fait au moins une fois (le point 6
      peut cibler une base jetable `komodo-restore-test` pour s'entraîner).
