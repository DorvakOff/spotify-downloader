#!/usr/bin/env python3
"""Nettoie les fichiers orphelins de la bibliotheque musicale du NAS.

Un ORPHELIN est un fichier audio physiquement present dans un dossier de
playlist (ex. "Boom boom/") qui n'est PLUS suivi par le fichier .spotdl de
CE dossier. Cela arrive quand un titre est retire d'une playlist Spotify :
`spotdl sync` le retire de son suivi mais laisse parfois le fichier sur le
disque (ancien telechargement, ou nom/hash modifie par la normalisation
loudnorm -> spotdl ne le reconnait plus comme "le sien" et ne le supprime pas).

La detection est SCOPEE PAR DOSSIER : chaque fichier doit etre suivi par le
.spotdl de sa propre playlist. Un meme titre present dans deux playlists est
donc traite independamment (legitime dans l'une, orphelin dans l'autre).

DRY-RUN PAR DEFAUT : sans --apply, le script LISTE seulement, ne supprime rien.

Usage :
    python3 prune-orphans.py [--music DIR] [--apply]

    --music DIR   Racine de la bibliotheque (defaut: $MUSIC_DIR ou /musique).
    --apply       Supprime reellement les orphelins (sinon dry-run).
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

AUDIO_EXT = (".mp3", ".opus", ".m4a", ".flac", ".wav")
SYNC_SUBDIR = ".spotdl-sync"


def norm(s: str) -> str:
    """Normalise un libelle pour comparaison tolerante (casse/ponctuation)."""
    s = (s or "").lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return s.strip()


def load_playlists(syncdir: str) -> dict[str, set[str]]:
    """Mappe nom-de-playlist normalise -> ensemble des cles de titres suivis."""
    playlists: dict[str, set[str]] = {}
    for f in glob.glob(os.path.join(syncdir, "*.spotdl")):
        try:
            data = json.load(open(f, encoding="utf-8"))
        except Exception as e:  # fichier .spotdl illisible : on l'ignore
            print(f"[prune] WARN lecture {os.path.basename(f)} : {e}", file=sys.stderr)
            continue
        songs = data.get("songs", []) if isinstance(data, dict) else data
        keys: set[str] = set()
        plname = ""
        for s in songs:
            plname = plname or s.get("list_name", "") or s.get("playlist", "")
            name = s.get("name", "")
            arts = s.get("artists") or ([s.get("artist")] if s.get("artist") else [])
            for a in arts:
                keys.add(norm(f"{a} {name}"))
            keys.add(norm(name))
        playlists[norm(plname)] = keys
    return playlists


def is_tracked(filename: str, keys: set[str]) -> bool:
    """Le fichier correspond-il a un titre suivi par ce .spotdl ?"""
    base = os.path.splitext(filename)[0]          # "Artist - Title"
    kfull = norm(base)
    ktitle = norm(base.split(" - ")[-1]) if " - " in base else kfull
    if kfull in keys or ktitle in keys:
        return True
    # Match souple : un titre suivi suffisamment long contenu dans le nom.
    return any(t and len(t) > 8 and (t in kfull or kfull in t) for t in keys)


def find_orphans(music: str) -> list[str]:
    """Retourne les chemins absolus des fichiers orphelins (scope par dossier)."""
    syncdir = os.path.join(music, SYNC_SUBDIR)
    playlists = load_playlists(syncdir)
    orphans: list[str] = []
    for root, _dirs, files in os.walk(music):
        if SYNC_SUBDIR in root or root == music:
            continue
        folder = os.path.basename(root)
        keys = playlists.get(norm(folder))
        for fn in files:
            if not fn.lower().endswith(AUDIO_EXT):
                continue
            # Pas de .spotdl pour ce dossier, OU titre non suivi -> orphelin.
            if keys is None or not is_tracked(fn, keys):
                orphans.append(os.path.join(root, fn))
    return orphans


def main() -> int:
    ap = argparse.ArgumentParser(description="Nettoie les orphelins (.spotdl).")
    ap.add_argument("--music", default=os.environ.get("MUSIC_DIR", "/musique"),
                    help="Racine de la bibliotheque musicale.")
    ap.add_argument("--apply", action="store_true",
                    help="Supprime reellement (sinon dry-run, defaut).")
    args = ap.parse_args()

    music = os.path.abspath(args.music)
    if not os.path.isdir(music):
        print(f"[prune] dossier introuvable : {music}", file=sys.stderr)
        return 2

    orphans = find_orphans(music)
    mode = "APPLY (suppression)" if args.apply else "DRY-RUN (liste seule)"
    print(f"[prune] mode={mode}  racine={music}")
    print(f"[prune] {len(orphans)} orphelin(s) detecte(s)\n")

    freed = 0
    for p in sorted(orphans):
        rel = os.path.relpath(p, music)
        try:
            size = os.path.getsize(p)
        except OSError:
            size = 0
        if args.apply:
            try:
                os.remove(p)
                freed += size
                print(f"  SUPPRIME  {rel}")
            except OSError as e:
                print(f"  ECHEC     {rel} : {e}", file=sys.stderr)
        else:
            print(f"  (dry-run) {rel}")

    if args.apply:
        print(f"\n[prune] termine : {len(orphans)} supprime(s), "
              f"{freed / 1024 / 1024:.1f} Mo liberes.")
    else:
        print("\n[prune] dry-run : rien supprime. Relance avec --apply pour appliquer.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
