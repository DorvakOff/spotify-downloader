#!/usr/bin/env bash
# Point d'entree du conteneur spotify-downloader.
#  1. Genere un API_TOKEN au 1er boot (ecrit dans /state/api_token) s'il n'est
#     pas deja fourni par l'environnement.
#  2. Lance un sync initial, puis une boucle de sync periodique (SYNC_INTERVAL).
#  3. Demarre l'API HTTP (uvicorn) au premier plan.
set -uo pipefail

STATE_DIR="${STATE_DIR:-/state}"
CONFIG_DIR="${CONFIG_DIR:-/config}"
MUSIC_DIR="${MUSIC_DIR:-/musique}"
TOKEN_FILE="$STATE_DIR/api_token"
API_PORT="${API_PORT:-8787}"
# Intervalle entre deux syncs. Accepte 6h, 90m, 3600 (secondes), etc.
SYNC_INTERVAL="${SYNC_INTERVAL:-10m}"
# Lancer un sync des le demarrage ? (oui/non)
SYNC_ON_START="${SYNC_ON_START:-oui}"

mkdir -p "$STATE_DIR" "$CONFIG_DIR" "$MUSIC_DIR"

# --- Token -----------------------------------------------------------------
if [ -z "${API_TOKEN:-}" ]; then
    if [ -f "$TOKEN_FILE" ]; then
        API_TOKEN="$(cat "$TOKEN_FILE")"
    else
        API_TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        echo "$API_TOKEN" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE" 2>/dev/null || true
        echo "[entrypoint] API_TOKEN genere -> $TOKEN_FILE"
    fi
fi
export API_TOKEN
echo "[entrypoint] token pret (${#API_TOKEN} caracteres). Port API: $API_PORT"

# --- Seed de la config -----------------------------------------------------
# Copie les exemples si le volume config est vide (1er lancement).
if [ ! -f "$CONFIG_DIR/playlists.txt" ] && [ -f /app/playlists.txt ]; then
    cp /app/playlists.txt "$CONFIG_DIR/playlists.txt"
    echo "[entrypoint] playlists.txt initialise dans $CONFIG_DIR"
fi
if [ ! -f "$CONFIG_DIR/settings.ini" ] && [ -f /app/settings.ini ]; then
    cp /app/settings.ini "$CONFIG_DIR/settings.ini"
    echo "[entrypoint] settings.ini initialise dans $CONFIG_DIR"
fi

# --- Conversion de l'intervalle en secondes --------------------------------
interval_seconds() {
    local v="$1"
    case "$v" in
        *h) echo $(( ${v%h} * 3600 )) ;;
        *m) echo $(( ${v%m} * 60 )) ;;
        *s) echo "${v%s}" ;;
        *)  echo "$v" ;;
    esac
}
INTERVAL_S="$(interval_seconds "$SYNC_INTERVAL")"
echo "[entrypoint] intervalle de sync : $SYNC_INTERVAL ($INTERVAL_S s)"

# --- Boucle de sync periodique (en arriere-plan) ---------------------------
sync_loop() {
    if [ "$SYNC_ON_START" = "oui" ]; then
        echo "[loop] sync initial..."
        /app/docker/sync-playlists.sh || true
    fi
    while true; do
        echo "[loop] prochain sync dans $INTERVAL_S s"
        sleep "$INTERVAL_S"
        echo "[loop] sync periodique..."
        /app/docker/sync-playlists.sh || true
    done
}
sync_loop &

# --- API au premier plan (PID 1 du conteneur) ------------------------------
# Plusieurs workers : un worker unique sature des que le client ouvre plusieurs
# connexions simultanees (telechargements en parallele) -> requetes en attente.
API_WORKERS="${API_WORKERS:-4}"
echo "[entrypoint] demarrage de l'API sur 0.0.0.0:$API_PORT ($API_WORKERS workers)"
exec python3 -m uvicorn api:app --app-dir /app/docker --host 0.0.0.0 --port "$API_PORT" --workers "$API_WORKERS"
