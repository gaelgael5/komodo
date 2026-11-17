#!/usr/bin/env bash
#
# bootstrap-core.sh — première installation de Komodo Core
# (MongoDB + Core + Periphery local) sur CET hôte.
#
# Idempotent : relançable sans risque (`docker compose up -d` converge).
#
# Usage :
#   scripts/bootstrap-core.sh
# Si core/compose.env n'existe pas encore, ./dev-deploy.sh core est lancé d'abord.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/core/compose.env"
COMPOSE_FILE="$REPO_DIR/core/compose.yaml"
PROJECT=komodo

log()  { printf '\033[1;34m[bootstrap-core]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap-core] attention :\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap-core] erreur :\033[0m %s\n' "$*" >&2; exit 1; }

maybe_sudo() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# ---------------------------------------------------------------- prérequis

command -v docker >/dev/null 2>&1 || die "docker est requis : https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "le plugin docker compose v2 est requis"

if ! grep -qm1 avx /proc/cpuinfo; then
  warn "CPU sans AVX détecté : mongo:8 ne démarrera PAS."
  warn "Sur Proxmox : mettre le type de CPU de la VM à « host », puis redémarrer la VM."
fi

if [ ! -f "$ENV_FILE" ]; then
  log "core/compose.env absent : lancement de ./dev-deploy.sh core"
  "$REPO_DIR/dev-deploy.sh" core
fi

# ------------------------------------------------- répertoires requis sur l'hôte

root_dir="$(grep -E '^PERIPHERY_ROOT_DIRECTORY=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
root_dir="${root_dir:-/etc/komodo}"
backups_path="$(grep -E '^COMPOSE_KOMODO_BACKUPS_PATH=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
backups_path="${backups_path:-/etc/komodo/backups}"

log "création des répertoires : $root_dir/{stacks,syncs} et $backups_path"
maybe_sudo mkdir -p "$root_dir/stacks" "$root_dir/syncs" "$backups_path"

# ---------------------------------------------------------------- déploiement

log "validation du compose…"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q

log "démarrage de la pile Komodo…"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

ok=0
if command -v curl >/dev/null 2>&1; then
  log "attente de la disponibilité du Core (http://localhost:9120)…"
  for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null http://localhost:9120/; then
      ok=1
      break
    fi
    sleep 2
  done
  [ "$ok" = 1 ] || die "Core injoignable après 60 s — voir : docker compose -p $PROJECT logs core"
else
  warn "curl absent : vérification de disponibilité sautée."
fi

core_pub="$(docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" \
  exec -T core cat /config/keys/core.pub 2>/dev/null || true)"

log "Komodo Core est démarré."
cat <<EOF

  UI      : http://<ip-de-cet-hote>:9120 (ou KOMODO_HOST derrière le reverse proxy)
  Compte  : voir KOMODO_INIT_ADMIN_USERNAME / KOMODO_INIT_ADMIN_PASSWORD
            dans core/compose.env (fichier local, mode 600)

  Clé publique du Core — à épingler sur les Periphery distants (optionnel) :
    ${core_pub:-"(non lisible pour l'instant : docker compose -p komodo -f core/compose.yaml --env-file core/compose.env exec core cat /config/keys/core.pub)"}

  Étapes suivantes :
    1. Se connecter à l'UI, vérifier que le Server local est « OK ».
    2. Créer une clé d'enrôlement : Settings -> Onboarding Keys -> New.
    3. Enrôler les autres hôtes avec scripts/add-periphery.sh (voir README).
EOF
