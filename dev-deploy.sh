#!/usr/bin/env bash
#
# dev-deploy.sh — construit les fichiers de paramètres locaux (jamais commités)
# à partir des modèles *.example du dépôt.
#
# Après un `git clone`, c'est LE point d'entrée : il pose les questions
# (ou lit les options), génère les secrets aléatoires, et peut chiffrer /
# déchiffrer les paramètres via sops + age (dossier secrets/).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOPS_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE="$SOPS_KEY_FILE"

log()  { printf '\033[1;34m[dev-deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dev-deploy] attention :\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[dev-deploy] erreur :\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage : ./dev-deploy.sh <commande> [options]

Commandes :
  core        génère core/compose.env        (paramètres du Core)
  periphery   génère periphery/periphery.env (paramètres d'un Periphery)
  init-sops   génère la clé age et configure .sops.yaml (secrets chiffrés)

Options communes :
  --yes              mode non interactif (défauts + secrets aléatoires)
  --force            écrase un fichier .env déjà présent
  --regenerate       ignore un éventuel secret chiffré dans secrets/ et regénère
  --save-secrets     chiffre le fichier généré dans secrets/ (sans question)
  --no-save-secrets  ne chiffre pas (sans question)

Options « core » :
  --host URL           URL publique de Komodo (KOMODO_HOST)
  --tz TZ              fuseau horaire (défaut : Europe/Paris)
  --admin-user NOM     compte admin initial (défaut : admin)
  --admin-password P   mot de passe admin initial (défaut : aléatoire, affiché)
  --server-name NOM    nom du premier Server (défaut : hostname)

Options « periphery » :
  --core-address URL   ws://<ip-du-core>:9120 ou wss://<dns> (REQUIS avec --yes)
  --name NOM           nom du Server / PERIPHERY_CONNECT_AS (défaut : hostname)
  --onboarding-key K   clé d'enrôlement O-... (vide si le Server existe déjà)
  --core-public-key K  clé publique du Core à épingler (vide = trust-on-first-use)

Si sops + age sont configurés et qu'un fichier chiffré correspondant existe
dans secrets/, il est déchiffré au lieu de poser les questions (sauf --regenerate).
EOF
}

# ---------------------------------------------------------------- utilitaires

rand_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# ask <question> <défaut> : lit une réponse (ou renvoie le défaut avec --yes)
ask() {
  local q="$1" def="${2:-}" ans=""
  if [ "$ASSUME_YES" = 1 ]; then
    printf '%s' "$def"
    return 0
  fi
  if [ -n "$def" ]; then
    read -r -p "$q [$def] : " ans
  else
    read -r -p "$q : " ans
  fi
  printf '%s' "${ans:-$def}"
}

# confirm <question> : 0 si l'utilisateur répond oui (toujours non avec --yes)
confirm() {
  local ans=""
  if [ "$ASSUME_YES" = 1 ]; then
    return 1
  fi
  read -r -p "$1 [o/N] : " ans
  case "$ans" in
    o | O | oui | OUI | y | Y | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# set_var <fichier> <clé> <valeur> : remplace (ou décommente) une ligne KEY=...
set_var() {
  local file="$1" key="$2" value="$3"
  value="${value//\\/\\\\}"
  value="${value//|/\\|}"
  value="${value//&/\\&}"
  if grep -Eq "^#? ?${key}=" "$file"; then
    sed -i -E "s|^#? ?${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

# ---------------------------------------------------------------- sops / age

age_recipient() {
  grep -Eo 'age1[0-9a-z]+' "$REPO_DIR/.sops.yaml" 2>/dev/null | head -1 || true
}

sops_ready() {
  command -v sops >/dev/null 2>&1 && [ -n "$(age_recipient)" ]
}

can_decrypt() {
  [ -f "$SOPS_KEY_FILE" ] || [ -n "${SOPS_AGE_KEY:-}" ]
}

decrypt_to() {
  local src="$1" dest="$2" tmp
  tmp="$(mktemp)"
  if sops --decrypt --input-type dotenv --output-type dotenv "$src" >"$tmp"; then
    install -m 600 "$tmp" "$dest"
    rm -f "$tmp"
  else
    rm -f "$tmp"
    die "échec du déchiffrement de ${src#"$REPO_DIR"/} (clé age absente ? fichier corrompu ?)"
  fi
}

encrypt_from() {
  local src="$1" dest="$2" recipient tmp
  recipient="$(age_recipient)"
  [ -n "$recipient" ] || die "aucun destinataire age dans .sops.yaml — lancer : ./dev-deploy.sh init-sops"
  tmp="$(mktemp)"
  # --config /dev/null : le destinataire est fourni via --age, on ne veut pas
  # que sops exige une creation_rule correspondant au chemin du fichier source.
  if sops --config /dev/null --encrypt --input-type dotenv --output-type dotenv \
    --age "$recipient" "$src" >"$tmp"; then
    mv "$tmp" "$dest"
    log "secret chiffré écrit : ${dest#"$REPO_DIR"/} (penser à le commiter)"
  else
    rm -f "$tmp"
    die "échec du chiffrement sops"
  fi
}

# maybe_save_secret <env-en-clair> <cible-chiffrée>
maybe_save_secret() {
  local plain="$1" enc="$2"
  case "$SAVE_SECRETS" in
    no) return 0 ;;
    yes) ;;
    *)
      if ! sops_ready; then
        return 0
      fi
      if ! confirm "Chiffrer ce fichier dans ${enc#"$REPO_DIR"/} pour le commiter ?"; then
        return 0
      fi
      ;;
  esac
  sops_ready || die "sops/age non configurés — lancer : ./dev-deploy.sh init-sops"
  mkdir -p "$(dirname "$enc")"
  encrypt_from "$plain" "$enc"
}

# ---------------------------------------------------------------- commandes

cmd_core() {
  local target="$REPO_DIR/core/compose.env"
  local example="$REPO_DIR/core/compose.env.example"
  local enc="$REPO_DIR/secrets/core.env.sops"

  if [ -f "$target" ] && [ "$FORCE" != 1 ]; then
    die "core/compose.env existe déjà (relancer avec --force pour l'écraser)"
  fi

  if [ "$REGENERATE" != 1 ] && [ -f "$enc" ] && sops_ready && can_decrypt; then
    log "secret chiffré trouvé : restauration depuis secrets/core.env.sops"
    decrypt_to "$enc" "$target"
    log "core/compose.env restauré (mode 600)."
    return 0
  fi

  local host tz server_name admin_user admin_pass
  host="${OPT_HOST:-$(ask "URL publique de Komodo, avec http:// ou https:// (KOMODO_HOST)" "https://komodo.example.com")}"
  # KOMODO_HOST doit être une URL complète : on répare une saisie « ip:port ».
  case "$host" in
    http://* | https://*) ;;
    *)
      host="http://${host}"
      warn "KOMODO_HOST sans schéma : corrigé en ${host}"
      ;;
  esac
  tz="${OPT_TZ:-$(ask "Fuseau horaire (TZ)" "Europe/Paris")}"
  server_name="${OPT_SERVER_NAME:-$(ask "Nom du premier Server (hostname conseillé)" "$(hostname)")}"
  admin_user="${OPT_ADMIN_USER:-$(ask "Compte admin initial" "admin")}"
  admin_pass="${OPT_ADMIN_PASS:-}"
  local admin_pass_generated=0
  if [ -z "$admin_pass" ]; then
    admin_pass="$(rand_secret | cut -c1-24)"
    admin_pass_generated=1
  fi

  install -m 600 "$example" "$target"
  set_var "$target" KOMODO_HOST "$host"
  set_var "$target" TZ "$tz"
  set_var "$target" KOMODO_FIRST_SERVER_NAME "$server_name"
  set_var "$target" PERIPHERY_CONNECT_AS "$server_name"
  set_var "$target" KOMODO_INIT_ADMIN_USERNAME "$admin_user"
  set_var "$target" KOMODO_INIT_ADMIN_PASSWORD "$admin_pass"
  set_var "$target" KOMODO_DATABASE_PASSWORD "$(rand_secret)"
  set_var "$target" KOMODO_JWT_SECRET "$(rand_secret)"
  set_var "$target" KOMODO_WEBHOOK_SECRET "$(rand_secret)"

  log "core/compose.env généré (mode 600)."
  if [ "$admin_pass_generated" = 1 ]; then
    log "compte admin initial : ${admin_user} / ${admin_pass}"
    log "(affiché une seule fois — à changer après la première connexion)"
  fi
  maybe_save_secret "$target" "$enc"
}

cmd_periphery() {
  local target="$REPO_DIR/periphery/periphery.env"
  local example="$REPO_DIR/periphery/periphery.env.example"

  if [ -f "$target" ] && [ "$FORCE" != 1 ]; then
    die "periphery/periphery.env existe déjà (relancer avec --force pour l'écraser)"
  fi

  local name
  name="${OPT_NAME:-$(ask "Nom du Server (PERIPHERY_CONNECT_AS, hostname conseillé)" "$(hostname)")}"
  [ -n "$name" ] || die "nom de Server vide"

  local enc="$REPO_DIR/secrets/periphery.${name}.env.sops"
  if [ "$REGENERATE" != 1 ] && [ -f "$enc" ] && sops_ready && can_decrypt; then
    log "secret chiffré trouvé : restauration depuis ${enc#"$REPO_DIR"/}"
    decrypt_to "$enc" "$target"
    log "periphery/periphery.env restauré (mode 600)."
    return 0
  fi

  local core_address tz onboarding core_pub
  core_address="${OPT_CORE_ADDRESS:-$(ask "Adresse du Core (ws://<ip>:9120 ou wss://<dns>)" "")}"
  [ -n "$core_address" ] || die "adresse du Core requise (ex. ws://192.168.1.10:9120)"
  # L'adresse doit être une URL websocket : on répare les saisies courantes.
  case "$core_address" in
    ws://* | wss://*) ;;
    http://*)
      core_address="ws://${core_address#http://}"
      warn "adresse en http:// : corrigée en ${core_address}"
      ;;
    https://*)
      core_address="wss://${core_address#https://}"
      warn "adresse en https:// : corrigée en ${core_address}"
      ;;
    *)
      core_address="ws://${core_address}"
      warn "adresse sans schéma : corrigée en ${core_address}"
      ;;
  esac
  tz="${OPT_TZ:-$(ask "Fuseau horaire (TZ)" "Europe/Paris")}"
  onboarding="${OPT_ONBOARDING_KEY:-$(ask "Clé d'enrôlement O-... (vide si le Server existe déjà)" "")}"
  core_pub="${OPT_CORE_PUBLIC_KEY:-$(ask "Clé publique du Core à épingler (vide = trust-on-first-use)" "")}"

  install -m 600 "$example" "$target"
  set_var "$target" PERIPHERY_CORE_ADDRESS "$core_address"
  set_var "$target" PERIPHERY_CONNECT_AS "$name"
  set_var "$target" TZ "$tz"
  set_var "$target" PERIPHERY_ONBOARDING_KEY "$onboarding"
  if [ -n "$core_pub" ]; then
    set_var "$target" PERIPHERY_CORE_PUBLIC_KEYS "$core_pub"
  fi

  log "periphery/periphery.env généré (mode 600) pour le Server « ${name} »."
  if [ -n "$onboarding" ]; then
    log "après la première connexion réussie : vider PERIPHERY_ONBOARDING_KEY puis redéployer."
  fi
  maybe_save_secret "$target" "$enc"
}

cmd_init_sops() {
  command -v age-keygen >/dev/null 2>&1 || die "age-keygen introuvable (Debian/Ubuntu : apt install age)"
  command -v sops >/dev/null 2>&1 || die "sops introuvable : https://github.com/getsops/sops/releases"

  if [ ! -f "$SOPS_KEY_FILE" ]; then
    mkdir -p "$(dirname "$SOPS_KEY_FILE")"
    (umask 077 && age-keygen -o "$SOPS_KEY_FILE")
    log "clé age générée : $SOPS_KEY_FILE"
    warn "SAUVEGARDER cette clé privée hors du dépôt (gestionnaire de mots de passe) !"
  else
    log "clé age existante : $SOPS_KEY_FILE"
  fi

  local recipient
  recipient="$(age-keygen -y "$SOPS_KEY_FILE")"
  if grep -q "CHANGE_ME_AGE_RECIPIENT" "$REPO_DIR/.sops.yaml"; then
    sed -i "s|CHANGE_ME_AGE_RECIPIENT|${recipient}|" "$REPO_DIR/.sops.yaml"
    log ".sops.yaml mis à jour avec le destinataire ${recipient} (à commiter)."
  elif grep -q "$recipient" "$REPO_DIR/.sops.yaml"; then
    log ".sops.yaml référence déjà cette clé."
  else
    warn ".sops.yaml contient déjà un autre destinataire — ajouter ${recipient} à la main si besoin."
  fi
}

# ---------------------------------------------------------------- entrée

ASSUME_YES=0
FORCE=0
REGENERATE=0
SAVE_SECRETS=""
OPT_HOST=""
OPT_TZ=""
OPT_ADMIN_USER=""
OPT_ADMIN_PASS=""
OPT_SERVER_NAME=""
OPT_CORE_ADDRESS=""
OPT_NAME=""
OPT_ONBOARDING_KEY=""
OPT_CORE_PUBLIC_KEY=""

CMD="${1:-}"
if [ -z "$CMD" ] || [ "$CMD" = "-h" ] || [ "$CMD" = "--help" ]; then
  usage
  exit 0
fi
shift

# req <option> <valeur> : échoue si la valeur manque
req() {
  [ -n "${2:-}" ] || die "l'option $1 requiert une valeur"
  printf '%s' "$2"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --force) FORCE=1 ;;
    --regenerate) REGENERATE=1 ;;
    --save-secrets) SAVE_SECRETS=yes ;;
    --no-save-secrets) SAVE_SECRETS=no ;;
    --host) OPT_HOST="$(req "$1" "${2:-}")"; shift ;;
    --tz) OPT_TZ="$(req "$1" "${2:-}")"; shift ;;
    --admin-user) OPT_ADMIN_USER="$(req "$1" "${2:-}")"; shift ;;
    --admin-password) OPT_ADMIN_PASS="$(req "$1" "${2:-}")"; shift ;;
    --server-name) OPT_SERVER_NAME="$(req "$1" "${2:-}")"; shift ;;
    --core-address) OPT_CORE_ADDRESS="$(req "$1" "${2:-}")"; shift ;;
    --name) OPT_NAME="$(req "$1" "${2:-}")"; shift ;;
    --onboarding-key) OPT_ONBOARDING_KEY="$(req "$1" "${2:-}")"; shift ;;
    --core-public-key) OPT_CORE_PUBLIC_KEY="$(req "$1" "${2:-}")"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "option inconnue : $1 (voir --help)" ;;
  esac
  shift
done

case "$CMD" in
  core) cmd_core ;;
  periphery) cmd_periphery ;;
  init-sops) cmd_init_sops ;;
  *)
    usage
    die "commande inconnue : $CMD"
    ;;
esac
