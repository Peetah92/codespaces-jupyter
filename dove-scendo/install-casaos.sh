#!/usr/bin/env bash
# Installa (o aggiorna) "Dove scendo" su un server CasaOS e lo rende raggiungibile via Tailscale.
#
#   curl -fsSL https://raw.githubusercontent.com/Peetah92/codespaces-jupyter/claude/train-arrival-position-estimator-kniy5d/dove-scendo/install-casaos.sh | sudo bash
#
# Variabili facoltative:
#   PORT=38471     porta di partenza (se è occupata si usa la prima libera successiva)
#   HTTPS=1        pubblica anche https://<server>.<tailnet>.ts.net con "tailscale serve"
#   NO_TAILSCALE=1 non installare né configurare Tailscale
#   TOKEN=...      token API da salvare sul server (altrimenti viene chiesto; invio vuoto = nessun token)
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Peetah92/codespaces-jupyter/${BRANCH:-claude/train-arrival-position-estimator-kniy5d}/dove-scendo"
APP_DIR="${APP_DIR:-/DATA/AppData/dove-scendo}"
PORT="${PORT:-38471}"

say() { printf '\n\033[1;31m▶\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mErrore:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "esegui lo script con sudo."
command -v docker >/dev/null || die "Docker non trovato: questo non sembra un server CasaOS."
docker compose version >/dev/null 2>&1 || die "manca 'docker compose' (plugin Compose v2)."
command -v curl >/dev/null || die "manca curl."

port_busy() {
  # porta in ascolto sull'host o già pubblicata da un altro container
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 0
  if command -v ss >/dev/null; then ss -ltnH "( sport = :$1 )" | grep -q . && return 0; fi
  docker ps --format '{{.Ports}}' | grep -Eq "(^|[:,[:space:]])$1->" && return 0
  return 1
}

# Se l'app è già installata, tieni la sua porta
if [ -f "$APP_DIR/docker-compose.yml" ]; then
  OLD_PORT="$(grep -Eo 'published: "[0-9]+"' "$APP_DIR/docker-compose.yml" | grep -Eo '[0-9]+' || true)"
  [ -n "${OLD_PORT:-}" ] && PORT="$OLD_PORT"
  docker compose -p dove-scendo -f "$APP_DIR/docker-compose.yml" down >/dev/null 2>&1 || true
fi
while port_busy "$PORT"; do PORT=$((PORT + 1)); done

say "Scarico l'app in $APP_DIR (porta $PORT)"
mkdir -p "$APP_DIR/html" "$APP_DIR/nginx"
curl -fsSL "$REPO_RAW/nginx.conf.template" -o "$APP_DIR/nginx/default.conf.template"
curl -fsSL "$REPO_RAW/index.html" -o "$APP_DIR/html/index.html.new"
mv "$APP_DIR/html/index.html.new" "$APP_DIR/html/index.html"
curl -fsSL "$REPO_RAW/docker-compose.yml" \
  | sed -E "s/(published|port_map): \"[0-9]+\"/\1: \"$PORT\"/; s/:38471/:$PORT/" \
  > "$APP_DIR/docker-compose.yml"

# Token API sul server: letto da nginx, mai mandato ai dispositivi
ENV_FILE="$APP_DIR/.env"
if [ -z "${TOKEN:-}" ] && ! grep -qs '^API_TOKEN=.' "$ENV_FILE" && [ -r /dev/tty ]; then
  printf '\nToken API di opentransportdata.swiss (invio per saltare): '
  read -rs TOKEN </dev/tty || TOKEN=""
  echo
fi
if [ -n "${TOKEN:-}" ]; then
  umask 077
  printf 'API_TOKEN=%s\n' "$TOKEN" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "Token salvato in $ENV_FILE (leggibile solo da root)."
elif grep -qs '^API_TOKEN=.' "$ENV_FILE"; then
  echo "Uso il token già salvato in $ENV_FILE."
else
  echo "Nessun token sul server: ogni dispositivo dovrà inserire il proprio."
fi

say "Avvio il container"
ENV_ARGS=()
[ -f "$ENV_FILE" ] && ENV_ARGS=(--env-file "$ENV_FILE")
docker compose -p dove-scendo "${ENV_ARGS[@]}" -f "$APP_DIR/docker-compose.yml" up -d
sleep 2
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
[ "$code" = "200" ] || die "la pagina non risponde su 127.0.0.1:$PORT (codice $code). Controlla: docker logs dove-scendo"
echo "OK: http://127.0.0.1:$PORT/ risponde."
if [ "$(curl -s "http://127.0.0.1:$PORT/api/config" || true)" = '{"proxy": true}' ]; then
  api="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/formation?evu=SBBP&operationDate=$(date +%F)&trainNumber=1" || true)"
  case "$api" in
    200|400) echo "OK: il server raggiunge l'API FFS con il token.";;
    401|403) echo "Attenzione: l'API FFS rifiuta il token salvato sul server (codice $api). Riesegui con TOKEN=... per cambiarlo.";;
    *) echo "Attenzione: l'API FFS non risponde dal server (codice $api).";;
  esac
fi

if [ "${NO_TAILSCALE:-0}" = "1" ]; then
  say "Fatto. Apri http://<ip-del-server>:$PORT"
  exit 0
fi

if ! command -v tailscale >/dev/null; then
  say "Installo Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if ! tailscale status >/dev/null 2>&1; then
  say "Collega il server al tuo account Tailscale: apri il link che compare qui sotto"
  tailscale up
fi

TS_NAME="$(tailscale status --json | sed -n 's/.*"DNSName": *"\([^"]*\)".*/\1/p' | head -n1 | sed 's/\.$//')"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 || true)"

if [ "${HTTPS:-0}" = "1" ]; then
  say "Pubblico anche in HTTPS dentro la tailnet"
  tailscale serve --bg --https=443 "http://127.0.0.1:$PORT"
fi

say "Fatto. Dal telefono, con Tailscale attivo, apri:"
[ -n "$TS_NAME" ] && echo "   http://${TS_NAME%%.*}:$PORT   (nome breve, serve MagicDNS)"
[ -n "$TS_IP" ] && echo "   http://$TS_IP:$PORT"
[ "${HTTPS:-0}" = "1" ] && [ -n "$TS_NAME" ] && echo "   https://$TS_NAME"
echo
echo "Per aggiornare l'app in futuro, riesegui lo stesso comando."
