#!/usr/bin/env bash
# Synchronise toutes les playlists trackees (playlists.txt) vers MUSIC_DIR.
# Lance par le cron interne du conteneur. Ecrit un status.json lu par l'API.
set -uo pipefail

CONFIG_DIR="${CONFIG_DIR:-/config}"
MUSIC_DIR="${MUSIC_DIR:-/musique}"
STATE_DIR="${STATE_DIR:-/state}"
PLAYLISTS_FILE="${SPOTDL_PLAYLISTS:-$CONFIG_DIR/playlists.txt}"
STATUS_FILE="$STATE_DIR/status.json"
LOCK="$STATE_DIR/sync.lock"

mkdir -p "$MUSIC_DIR" "$STATE_DIR"

# Un seul sync a la fois (le cron ne doit pas chevaucher un run en cours).
exec 9>"$LOCK"
if ! flock -n 9; then
    echo "[sync] un autre sync est deja en cours -- abandon."
    exit 0
fi

START_TS=$(date +%s)
START_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[sync] demarrage $START_ISO"

write_status() {
    # $1=state  $2=message
    local now_iso count
    now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    count=$(find "$MUSIC_DIR" -type f \
        \( -iname '*.mp3' -o -iname '*.opus' -o -iname '*.m4a' -o -iname '*.flac' -o -iname '*.wav' \) \
        2>/dev/null | wc -l | tr -d ' ')
    cat > "$STATUS_FILE" <<EOF
{
  "state": "$1",
  "message": "$2",
  "started": "$START_ISO",
  "finished": "$now_iso",
  "duration_s": $(( $(date +%s) - START_TS )),
  "track_count": $count
}
EOF
}

if [ ! -f "$PLAYLISTS_FILE" ]; then
    echo "[sync] aucun playlists.txt ($PLAYLISTS_FILE) -- rien a faire."
    write_status "idle" "aucune playlist trackee"
    exit 0
fi

# downloader.py lit SPOTDL_* depuis l'environnement (base, format, sync, etc.).
# On force le mode sync (ajout + retrait des titres retires de la playlist).
export SPOTDL_SYNC="oui"

write_status "running" "synchronisation en cours"

python3 /app/bin/downloader.py --file "$PLAYLISTS_FILE"
RC=$?

if [ $RC -eq 0 ]; then
    echo "[sync] termine OK"
    write_status "ok" "synchronisation terminee"
else
    echo "[sync] termine avec code $RC"
    write_status "error" "echec (code $RC)"
fi
exit $RC
