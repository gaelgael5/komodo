#!/usr/bin/env bash
#
# deploy-mcp.sh — déploie le serveur MCP (agents IA) sur CET hôte,
# normalement celui du Core.
#
# Prérequis côté Komodo (voir mcp/README.md) :
#   - un compte dédié `svc-agents` créé dans l'UI, permissions minimales ;
#   - l'auth MCP reste activée : les clients se connectent avec ce compte.
#
# Usage :
#   scripts/deploy-mcp.sh
# Si mcp/mcp.env n'existe pas encore, ./dev-deploy.sh mcp est lancé d'abord
# (les options passées ici lui sont transmises telles quelles).
#
# Idempotent : relançable sans risque.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/mcp/mcp.env"
COMPOSE_FILE="$REPO_DIR/mcp/compose.yaml"
PROJECT=komodo-mcp

log()  { printf '\033[1;34m[deploy-mcp]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy-mcp] attention :\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[deploy-mcp] erreur :\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker est requis : https://docs.docker.com/engine/install/"
docker compose version >/dev/null 2>&1 || die "le plugin docker compose v2 est requis"

if [ ! -f "$ENV_FILE" ]; then
  log "mcp/mcp.env absent : lancement de ./dev-deploy.sh mcp"
  "$REPO_DIR/dev-deploy.sh" mcp "$@"
fi

log "validation du compose…"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" config -q

log "démarrage du serveur MCP…"
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

port="$(grep -E '^KOMODO_MCP_PORT=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)"
port="${port:-8000}"

ok=0
if command -v curl >/dev/null 2>&1; then
  log "attente de la disponibilité (http://localhost:${port}/ready)…"
  for _ in $(seq 1 15); do
    if curl -fsS -o /dev/null "http://localhost:${port}/ready"; then
      ok=1
      break
    fi
    sleep 2
  done
  if [ "$ok" != 1 ]; then
    warn "/ready ne répond pas 200 (Komodo injoignable depuis le conteneur ?)"
    warn "voir : docker compose -p $PROJECT -f mcp/compose.yaml --env-file mcp/mcp.env logs"
  fi
else
  warn "curl absent : vérification de disponibilité sautée."
fi

log "serveur MCP déployé."
cat <<EOF

  Endpoint MCP : http://<ip-de-cet-hote>:${port}/mcp

  Connexion d'un client (exemple Claude Code) :
    claude mcp add --transport http komodo http://<ip-de-cet-hote>:${port}/mcp
  puis « Authenticate » avec le compte Komodo dédié (svc-agents).

  Détails et modèle de sécurité : mcp/README.md
EOF
