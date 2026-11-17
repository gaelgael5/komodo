#!/usr/bin/env bash
#
# add-periphery.sh — enrôle CET hôte Docker comme Periphery d'un Core existant.
#
# Procédure d'enrôlement (détails dans le README) :
#   1. Sur le Core (UI) : Settings -> Onboarding Keys -> New
#      -> copier la clé « O-... » (affichée une seule fois).
#   2. Sur cet hôte :
#        git clone <ce dépôt> && cd <dépôt>
#        scripts/add-periphery.sh
#      Le script demande l'adresse du Core, le nom du Server et la clé O-...
#      (options possibles : --core-address, --name, --onboarding-key, …
#       elles sont transmises telles quelles à ./dev-deploy.sh periphery).
#   3. Vérifier dans l'UI que le Server apparaît et passe « OK ».
#   4. Vider PERIPHERY_ONBOARDING_KEY de periphery/periphery.env (elle ne sert
#      qu'au premier contact), puis relancer ce script pour redéployer.
#
# Idempotent : relançable sans risque.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/periphery/periphery.env"
COMPOSE_FILE="$REPO_DIR/periphery/compose.yaml"
PROJECT=komodo-periphery

log()  { printf '\033[1;34m[add-periphery]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[add-periphery] attention :\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[add-periphery] erreur :\033[0m %s\n' "$*" >&2; exit 1; }

maybe_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

command -v docker >/dev/null 2>&1 || die "docker est requis : https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "le plugin docker compose v2 est requis"

if [ ! -f "$ENV_FILE" ]; then
  log "periphery/periphery.env absent : lancement de ./dev-deploy.sh periphery"
  "$REPO_DIR/dev-deploy.sh" periphery "$@"
fi

root_dir="$(grep -E '^PERIPHERY_ROOT_DIRECTORY=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
root_dir="${root_dir:-/etc/komodo}"
log "création du répertoire racine Periphery : $root_dir/stacks"
maybe_sudo mkdir -p "$root_dir/stacks"

log "validation du compose…"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q

log "démarrage du Periphery…"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

sleep 3
log "derniers logs du Periphery :"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 15 periphery || true

connect_as="$(grep -E '^PERIPHERY_CONNECT_AS=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
cat <<EOF

  Étapes suivantes :
    1. Dans l'UI du Core : Servers -> « ${connect_as:-<nom>} » doit passer « OK ».
       (La connexion est SORTANTE depuis cet hôte : rien à ouvrir ici.)
    2. Une fois la connexion établie, vider PERIPHERY_ONBOARDING_KEY
       dans periphery/periphery.env puis relancer ce script.
    3. Déclarer l'hôte dans syncs/servers.toml (même nom) et commiter.
EOF
