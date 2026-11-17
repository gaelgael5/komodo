#!/usr/bin/env bash
#
# update.sh — met à jour le dépôt (git pull) puis redéploie ce qui tourne
# sur CETTE machine : le Core si core/compose.env existe, le Periphery si
# periphery/periphery.env existe.
#
# Usage :
#   scripts/update.sh [--no-pull] [--prune]
#     --no-pull   ne fait pas de git pull (redéploiement seul)
#     --prune     supprime les anciennes images docker après mise à jour
#
# Idempotent : relançable sans risque.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m[update]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[update] erreur :\033[0m %s\n' "$*" >&2; exit 1; }

NO_PULL=0
PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-pull) NO_PULL=1 ;;
    --prune) PRUNE=1 ;;
    *) die "option inconnue : $1" ;;
  esac
  shift
done

command -v docker >/dev/null 2>&1 || die "docker est requis"
docker compose version >/dev/null 2>&1 || die "le plugin docker compose v2 est requis"

if [ "$NO_PULL" != 1 ]; then
  log "git pull --ff-only…"
  git -C "$REPO_DIR" pull --ff-only
fi

updated=0

if [ -f "$REPO_DIR/core/compose.env" ]; then
  log "mise à jour du Core…"
  docker compose -p komodo -f "$REPO_DIR/core/compose.yaml" \
    --env-file "$REPO_DIR/core/compose.env" pull
  docker compose -p komodo -f "$REPO_DIR/core/compose.yaml" \
    --env-file "$REPO_DIR/core/compose.env" up -d
  updated=1
fi

if [ -f "$REPO_DIR/periphery/periphery.env" ]; then
  log "mise à jour du Periphery…"
  docker compose -p komodo-periphery -f "$REPO_DIR/periphery/compose.yaml" \
    --env-file "$REPO_DIR/periphery/periphery.env" pull
  docker compose -p komodo-periphery -f "$REPO_DIR/periphery/compose.yaml" \
    --env-file "$REPO_DIR/periphery/periphery.env" up -d
  updated=1
fi

if [ "$updated" != 1 ]; then
  die "ni core/compose.env ni periphery/periphery.env : rien à mettre à jour sur cette machine"
fi

if [ "$PRUNE" = 1 ]; then
  log "nettoyage des anciennes images…"
  docker image prune -f
fi

log "terminé."
