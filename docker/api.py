#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
API HTTP du serveur spotify-downloader (cote NAS / Debian via Docker).

Role : exposer la bibliotheque musicale a un client distant (PC Windows) via
HTTP + token Bearer, SANS SSH au quotidien. Le client compare un "manifest"
(chemin + taille + hash + mtime par fichier) pour calculer un vrai delta
(ajout / modification / suppression) et ne tirer que ce qui a change.

Endpoints (tous proteges par Bearer token sauf /health) :
    GET  /health              -> {"ok": true}                 (sans auth)
    GET  /status              -> etat du dernier sync
    GET  /manifest            -> {"files": [{path,size,mtime,sha256}], ...}
    GET  /file?path=<rel>     -> contenu binaire d'un fichier
    GET  /playlists           -> liste des playlists trackees
    POST /playlists           -> {"url": "..."} ajoute une playlist (dedup)
    DELETE /playlists         -> {"url": "..."} retire une playlist

Config par variables d'environnement :
    API_TOKEN       jeton Bearer attendu (obligatoire)
    MUSIC_DIR       dossier de la bibliotheque      (defaut /musique)
    CONFIG_DIR      dossier de config monte          (defaut /config)
    STATE_DIR       dossier d'etat (status.json)     (defaut /state)
    API_PORT        port d'ecoute                    (defaut 8787)
"""
import hashlib
import json
import os
import re
import time
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse

MUSIC_DIR = Path(os.environ.get("MUSIC_DIR", "/musique")).resolve()
CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/config"))
STATE_DIR = Path(os.environ.get("STATE_DIR", "/state"))
PLAYLISTS_FILE = Path(os.environ.get("SPOTDL_PLAYLISTS", str(CONFIG_DIR / "playlists.txt")))
STATUS_FILE = STATE_DIR / "status.json"
API_TOKEN = os.environ.get("API_TOKEN", "")

# Extensions audio servies par le manifest.
AUDIO_EXT = {".mp3", ".opus", ".m4a", ".flac", ".wav"}

app = FastAPI(title="spotify-downloader API", version="1.0")


# ---------------------------------------------------------------------------
#  Authentification
# ---------------------------------------------------------------------------
def require_token(authorization: str = Header(default="")) -> None:
    if not API_TOKEN:
        raise HTTPException(status_code=503, detail="API_TOKEN non configure cote serveur")
    expected = f"Bearer {API_TOKEN}"
    # Comparaison a temps constant pour eviter les attaques temporelles.
    if not _consteq(authorization.strip(), expected):
        raise HTTPException(status_code=401, detail="Token invalide ou absent")


def _consteq(a: str, b: str) -> bool:
    import hmac
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
def _safe_rel(rel: str) -> Path:
    """Resout un chemin relatif en empechant toute evasion hors de MUSIC_DIR."""
    rel = rel.replace("\\", "/").lstrip("/")
    target = (MUSIC_DIR / rel).resolve()
    if target != MUSIC_DIR and MUSIC_DIR not in target.parents:
        raise HTTPException(status_code=400, detail="Chemin hors de la bibliotheque")
    return target


def _sha256(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _build_manifest(with_hash: bool = True) -> dict:
    files = []
    if MUSIC_DIR.is_dir():
        for p in sorted(MUSIC_DIR.rglob("*")):
            if not p.is_file() or p.suffix.lower() not in AUDIO_EXT:
                continue
            st = p.stat()
            entry = {
                "path": p.relative_to(MUSIC_DIR).as_posix(),
                "size": st.st_size,
                "mtime": int(st.st_mtime),
            }
            if with_hash:
                entry["sha256"] = _sha256(p)
            files.append(entry)
    return {
        "generated": int(time.time()),
        "music_dir": str(MUSIC_DIR),
        "count": len(files),
        "files": files,
    }


_SPOTIFY_URL_RE = re.compile(
    r"https?://open\.spotify\.com/(?:intl-[a-z]+/)?(playlist|album)/([A-Za-z0-9]+)", re.I)


def _spotify_id(url: str):
    m = _SPOTIFY_URL_RE.search(url)
    return m.group(2) if m else None


def _read_playlists() -> list[str]:
    if not PLAYLISTS_FILE.exists():
        return []
    out = []
    for ln in PLAYLISTS_FILE.read_text(encoding="utf-8").splitlines():
        s = ln.strip()
        if s and not s.startswith("#"):
            out.append(s)
    return out


def _write_playlists(urls: list[str], preserve_header: bool = True) -> None:
    header = []
    if preserve_header and PLAYLISTS_FILE.exists():
        for ln in PLAYLISTS_FILE.read_text(encoding="utf-8").splitlines():
            if ln.strip().startswith("#") or not ln.strip():
                header.append(ln)
            else:
                break
    PLAYLISTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    body = "\n".join(header + urls)
    PLAYLISTS_FILE.write_text(body.rstrip("\n") + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
#  Endpoints
# ---------------------------------------------------------------------------
@app.get("/health")
def health() -> dict:
    return {"ok": True, "service": "spotify-downloader", "music_dir": str(MUSIC_DIR)}


@app.get("/status", dependencies=[Depends(require_token)])
def status() -> JSONResponse:
    if STATUS_FILE.exists():
        try:
            return JSONResponse(json.loads(STATUS_FILE.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            pass
    return JSONResponse({"last_sync": None, "message": "aucun sync enregistre"})


@app.get("/manifest", dependencies=[Depends(require_token)])
def manifest(hash: int = Query(default=1, description="1=inclure sha256, 0=non")) -> JSONResponse:
    return JSONResponse(_build_manifest(with_hash=bool(hash)))


@app.get("/file", dependencies=[Depends(require_token)])
def get_file(path: str = Query(...)) -> FileResponse:
    target = _safe_rel(path)
    if not target.is_file():
        raise HTTPException(status_code=404, detail="Fichier introuvable")
    return FileResponse(str(target), filename=target.name,
                        media_type="application/octet-stream")


@app.get("/playlists", dependencies=[Depends(require_token)])
def list_playlists() -> dict:
    return {"playlists": _read_playlists()}


@app.post("/playlists", dependencies=[Depends(require_token)])
def add_playlist(body: dict) -> dict:
    url = (body or {}).get("url", "").strip()
    if not url:
        raise HTTPException(status_code=400, detail="champ 'url' manquant")
    pid = _spotify_id(url)
    if not pid:
        raise HTTPException(status_code=400, detail="URL playlist/album Spotify invalide")
    current = _read_playlists()
    if any(_spotify_id(u) == pid for u in current):
        return {"added": False, "reason": "deja presente", "playlists": current}
    current.append(url)
    _write_playlists(current)
    return {"added": True, "playlists": current}


@app.delete("/playlists", dependencies=[Depends(require_token)])
def remove_playlist(body: dict) -> dict:
    url = (body or {}).get("url", "").strip()
    if not url:
        raise HTTPException(status_code=400, detail="champ 'url' manquant")
    pid = _spotify_id(url)
    current = _read_playlists()
    kept = [u for u in current if not (pid and _spotify_id(u) == pid) and u != url]
    removed = len(current) - len(kept)
    if removed:
        _write_playlists(kept)
    return {"removed": bool(removed), "playlists": kept}


if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("API_PORT", "8787"))
    uvicorn.run(app, host="0.0.0.0", port=port)
