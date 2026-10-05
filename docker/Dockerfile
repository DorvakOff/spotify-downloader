# spotify-downloader -- image serveur (NAS Debian 13)
# Contient : Python 3.12, spotdl, ffmpeg, Deno (client YouTube), FastAPI.
FROM python:3.12-slim

LABEL org.opencontainers.image.title="spotify-downloader" \
      org.opencontainers.image.description="Sync de playlists Spotify + API HTTP (bridge NAS<->Windows)"

ENV PYTHONUNBUFFERED=1 \
    PYTHONUTF8=1 \
    PYTHONIOENCODING=utf-8 \
    MUSIC_DIR=/musique \
    CONFIG_DIR=/config \
    STATE_DIR=/state \
    SPOTDL_BASE=/musique \
    SPOTDL_PLAYLISTS=/config/playlists.txt \
    API_PORT=8787 \
    SYNC_INTERVAL=10m

# ffmpeg (encodage + loudnorm), ca-certificates, flock (util-linux), curl (healthcheck).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates curl util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Dependances Python : spotdl + l'API.
COPY bin/requirements.txt /app/bin/requirements.txt
COPY docker/requirements-api.txt /app/docker/requirements-api.txt
RUN pip install --no-cache-dir -r /app/bin/requirements.txt \
    && pip install --no-cache-dir -r /app/docker/requirements-api.txt \
    && pip install --no-cache-dir spotdl

# Deno pour le client YouTube de spotdl (installe dans ~/.spotdl).
RUN python3 -m spotdl --download-deno || true

# Code applicatif.
COPY bin/ /app/bin/
COPY docker/ /app/docker/
COPY settings.ini.example /app/settings.ini
COPY playlists.txt /app/playlists.txt

RUN chmod +x /app/docker/entrypoint.sh /app/docker/sync-playlists.sh

VOLUME ["/musique", "/config", "/state"]
EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${API_PORT}/health" || exit 1

ENTRYPOINT ["/app/docker/entrypoint.sh"]
