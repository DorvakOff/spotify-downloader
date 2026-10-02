#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Spotify Downloader - pilote spotdl avec une jolie interface.

Usages :
    python downloader.py "<URL Spotify>"              # telechargement simple
    python downloader.py --sync "<URL Spotify>"       # synchronise (ajoute les nouveautes)
    python downloader.py --retry                      # retente les titres de _missing.txt
    python downloader.py --file playlists.txt         # plusieurs URLs (une par ligne)
    python downloader.py "<url1>" "<url2>" ...         # plusieurs URLs d'un coup

Config : settings.ini a la racine du projet.
"""
import argparse
import configparser
import os
import re
import subprocess
import sys
import time
import unicodedata
from datetime import datetime
from pathlib import Path

# Sortie du script en UTF-8 (noms avec Ø, accents, etc.).
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

HERE = Path(__file__).resolve().parent          # dossier bin/
ROOT = HERE.parent                               # racine du projet
CFG_PATH = ROOT / "settings.ini"


def _truthy(val: str) -> bool:
    return str(val).strip().lower() in ("oui", "yes", "true", "1", "o", "y")


# ===========================================================================
#  Interface : couleurs ANSI, cadres, barre de progression
# ===========================================================================
class C:
    RESET = "\033[0m"; BOLD = "\033[1m"; DIM = "\033[2m"
    GREEN = "\033[92m"; RED = "\033[91m"; YELLOW = "\033[93m"
    CYAN = "\033[96m"; MAGENTA = "\033[95m"; GREY = "\033[90m"
    BADGE_OK = "\033[1;97;42m"    # blanc gras / vert
    BADGE_SKIP = "\033[1;97;44m"  # blanc gras / bleu
    BADGE_ERR = "\033[1;97;41m"   # blanc gras / rouge
    BADGE_NORM = "\033[1;97;45m"  # blanc gras / magenta
    BADGE_DUP = "\033[1;30;103m"  # noir / jaune vif


def _enable_ansi() -> None:
    if sys.platform == "win32":
        try:
            import ctypes
            k = ctypes.windll.kernel32
            k.SetConsoleMode(k.GetStdHandle(-11), 7)
        except Exception:
            pass


_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def _strip_ansi(s: str) -> str:
    return _ANSI_RE.sub("", s)


def _disp_width(s: str) -> int:
    """Largeur d'affichage en colonnes (emoji / caracteres larges = 2), hors ANSI."""
    s = _strip_ansi(s)
    w = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        if unicodedata.east_asian_width(ch) in ("W", "F") or ord(ch) >= 0x1F000:
            w += 2
        else:
            w += 1
    return w


def box(title: str, lines: list[str], color: str = C.CYAN) -> str:
    inner = max([_disp_width(title)] + [_disp_width(ln) for ln in lines]) + 2
    inner = max(inner, 56)

    def row(content: str, bold: bool = False) -> str:
        pad = max(inner - 1 - _disp_width(content), 0)
        body = f" {C.BOLD if bold else ''}{content}{C.RESET if bold else ''}"
        return f"{color}║{C.RESET}{body}{' ' * pad}{color}║{C.RESET}"

    out = [f"{color}╔{'═' * inner}╗{C.RESET}", row(title, bold=True),
           f"{color}╟{'─' * inner}╢{C.RESET}"]
    out += [row(ln) for ln in lines]
    out.append(f"{color}╚{'═' * inner}╝{C.RESET}")
    return "\n".join(out)


def _fmt_eta(seconds: float) -> str:
    if seconds <= 0 or seconds != seconds:  # 0 ou NaN
        return "--:--"
    seconds = int(seconds)
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h:d}:{m:02d}:{s:02d}" if h else f"{m:d}:{s:02d}"


def progress_bar(done: int, total: int, start_ts: float | None = None, width: int = 32) -> str:
    """Barre + ETA + debit. '[####----] 12/54 22%  ETA 1:30  18/min'."""
    total = max(total, 1)
    frac = min(done / total, 1.0)
    filled = int(frac * width)
    bar = "█" * filled + "░" * (width - filled)
    pct = int(frac * 100)
    col = C.GREEN if frac >= 1 else C.CYAN
    out = f"{col}[{bar}]{C.RESET} {C.BOLD}{done}/{total}{C.RESET} {col}{pct:3d}%{C.RESET}"
    if start_ts and done > 0 and frac < 1.0:
        elapsed = time.time() - start_ts
        rate = done / elapsed if elapsed > 0 else 0  # titres/s
        if rate > 0:
            eta = (total - done) / rate
            out += f"  {C.GREY}ETA {_fmt_eta(eta)}  {rate * 60:.0f}/min{C.RESET}"
    return out


# ===========================================================================
#  Dependances : spotdl, Deno, ffmpeg
# ===========================================================================
def _spotdl_dir() -> Path:
    return Path.home() / ".spotdl"


def _ffmpeg_path() -> str:
    """Chemin vers ffmpeg : d'abord le PATH, sinon celui installe par spotdl."""
    from shutil import which
    p = which("ffmpeg")
    if p:
        return p
    local = _spotdl_dir() / ("ffmpeg.exe" if sys.platform == "win32" else "ffmpeg")
    if local.exists():
        return str(local)
    return "ffmpeg"  # dernier recours (echouera proprement si absent)


def ensure_deps() -> None:
    try:
        subprocess.run([sys.executable, "-m", "spotdl", "--version"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError):
        print(f"{C.YELLOW}[setup] spotdl absent -- installation...{C.RESET}")
        subprocess.run([sys.executable, "-m", "pip", "install", "spotdl"], check=True)

    deno = _spotdl_dir() / ("deno.exe" if sys.platform == "win32" else "deno")
    if not deno.exists():
        print(f"{C.YELLOW}[setup] Deno absent -- installation...{C.RESET}")
        try:
            subprocess.run([sys.executable, "-m", "spotdl", "--download-deno"], check=True)
        except subprocess.CalledProcessError:
            print(f"{C.YELLOW}[!] installation de Deno echouee.{C.RESET}")

    # ffmpeg : requis pour l'encodage ET la normalisation loudness.
    # Auto-installe via spotdl (dans ~/.spotdl) s'il n'est ni dans le PATH
    # ni deja telecharge -- comme spotdl et Deno.
    from shutil import which
    local_ffmpeg = _spotdl_dir() / ("ffmpeg.exe" if sys.platform == "win32" else "ffmpeg")
    if which("ffmpeg") is None and not local_ffmpeg.exists():
        print(f"{C.YELLOW}[setup] ffmpeg absent -- installation...{C.RESET}")
        try:
            subprocess.run([sys.executable, "-m", "spotdl", "--download-ffmpeg"], check=True)
        except subprocess.CalledProcessError:
            print(f"{C.RED}[!] installation de ffmpeg echouee. "
                  f"Installe-le : winget install Gyan.FFmpeg{C.RESET}")


# ===========================================================================
#  Config
# ===========================================================================
def load_config() -> dict:
    cfg = configparser.ConfigParser()
    d = {
        "base": str(ROOT / "Musique"),
        "format": "mp3", "bitrate": "320k",
        "providers": "soundcloud youtube-music bandcamp",
        "template": r"{list-name}\{artists} - {title}.{output-ext}",
        "threads": "8", "skip_existants": "oui", "scan_complet": "non",
        "normaliser": "oui", "sync": "non",
    }
    if CFG_PATH.exists():
        cfg.read(CFG_PATH, encoding="utf-8")
        g = lambda sec, key: cfg.get(sec, key, fallback=d[key]).strip()
        if cfg.has_section("sortie"):
            d["base"] = g("sortie", "base")
        if cfg.has_section("qualite"):
            d["format"] = g("qualite", "format"); d["bitrate"] = g("qualite", "bitrate")
            d["providers"] = g("qualite", "providers")
            d["normaliser"] = g("qualite", "normaliser")
        if cfg.has_section("avance"):
            d["template"] = g("avance", "template"); d["threads"] = g("avance", "threads")
            d["skip_existants"] = g("avance", "skip_existants")
            d["scan_complet"] = g("avance", "scan_complet")
            d["sync"] = g("avance", "sync")
    # Separateur de dossier dans le template : normalise selon l'OS.
    # settings.ini utilise '\' (Windows) ; sous Linux (NAS/Docker) il faut '/'.
    d["template"] = d["template"].replace("\\", "/").replace("/", os.sep)

    # Surcharges par variables d'environnement (pratique en Docker : le compose
    # fixe la config sans editer settings.ini dans l'image).
    env_map = {
        "SPOTDL_BASE": "base", "SPOTDL_FORMAT": "format",
        "SPOTDL_BITRATE": "bitrate", "SPOTDL_PROVIDERS": "providers",
        "SPOTDL_THREADS": "threads", "SPOTDL_NORMALISER": "normaliser",
        "SPOTDL_SYNC": "sync", "SPOTDL_SKIP": "skip_existants",
    }
    for env_key, cfg_key in env_map.items():
        v = os.environ.get(env_key)
        if v:
            d[cfg_key] = v.strip()
    return d


def _norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", text.lower())


# ===========================================================================
#  Normalisation loudness (ReplayGain via ffmpeg loudnorm, EBU R128)
# ===========================================================================
def normalize_loudness(files: list[Path], target_i: float = -14.0) -> int:
    """Normalise le volume des fichiers a target_i LUFS (standard streaming).
    Reecrit chaque fichier via ffmpeg loudnorm. Retourne le nombre traite."""
    ff = _ffmpeg_path()
    done = 0
    total = len(files)
    start = time.time()
    for i, f in enumerate(files, 1):
        tmp = f.with_suffix(f.suffix + ".norm.tmp")
        cmd = [
            ff, "-y", "-i", str(f),
            "-af", f"loudnorm=I={target_i}:TP=-1.5:LRA=11",
            "-c:a", "libmp3lame" if f.suffix.lower() == ".mp3" else "copy",
            "-b:a", "320k", "-map_metadata", "0", "-id3v2_version", "3",
            str(tmp),
        ]
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            tmp.replace(f)
            done += 1
        except subprocess.CalledProcessError:
            if tmp.exists():
                tmp.unlink()
        sys.stdout.write("\r\033[2K")
        sys.stdout.write(f"  {progress_bar(i, total, start)}   "
                         f"{C.BADGE_NORM} NORM {C.RESET} {f.name[:40]}")
        sys.stdout.flush()
    sys.stdout.write("\r\033[2K")
    return done


# ===========================================================================
#  Detection de doublons / quasi-doublons
# ===========================================================================
def find_duplicates(base: Path, ext: str) -> list[tuple[str, list[Path]]]:
    """Regroupe les fichiers dont le titre normalise est identique."""
    groups: dict[str, list[Path]] = {}
    for p in base.rglob(f"*.{ext}"):
        key = _norm(p.stem.split(" - ", 1)[-1])  # titre seul, normalise
        if key:
            groups.setdefault(key, []).append(p)
    return [(k, v) for k, v in groups.items() if len(v) > 1]


# ===========================================================================
#  Un telechargement spotdl (avec backoff rate-limit)
# ===========================================================================
def run_spotdl(action: str, url: str, cfg: dict, base: Path, log_fh,
               threads_override: int | None = None) -> dict:
    """Lance `spotdl <action> <url>` et pilote l'affichage.
    action = 'download' ou 'sync'. Retourne un dict de resultats."""
    output = str(base / cfg["template"])
    threads = threads_override or int(cfg["threads"])
    cmd = [sys.executable, "-m", "spotdl", action, url,
           "--output", output, "--format", cfg["format"],
           "--bitrate", cfg["bitrate"], "--threads", str(threads),
           "--ffmpeg", _ffmpeg_path()]
    providers = cfg["providers"].split()
    if providers:
        cmd += ["--audio", *providers]
    if action == "download":
        if _truthy(cfg["skip_existants"]):
            cmd += ["--overwrite", "skip"]
            if _truthy(cfg["scan_complet"]):
                cmd.append("--scan-for-songs")
        else:
            cmd += ["--overwrite", "force"]

    child_env = dict(os.environ)
    child_env["PYTHONUTF8"] = "1"
    child_env["PYTHONIOENCODING"] = "utf-8"

    total = 0
    done = 0
    playlist_name = ""
    failed = []
    rate_limited = False
    start = time.time()

    def _redraw(badge="", text=""):
        bar = progress_bar(done, total if total else 1, start)
        sys.stdout.write("\r\033[2K  " + bar)
        if badge:
            sys.stdout.write(f"   {badge}")
        if text:
            sys.stdout.write(f" {text if len(text) <= 42 else text[:39] + '...'}")
        sys.stdout.flush()

    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8", errors="replace",
                            bufsize=1, env=child_env)
    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            line = raw.rstrip("\n").strip()
            if not line:
                continue
            log_fh.write(line + "\n")

            if re.search(r"429|rate.?limit|too many requests", line, re.I):
                rate_limited = True

            m = re.search(r"Found\s+(\d+)\s+songs?\s+in\s+(.+?)\s*\((?:Playlist|Album)\)", line)
            if m:
                total = int(m.group(1)); playlist_name = m.group(2).strip()
                _redraw(f"{C.BADGE_SKIP} LIRE {C.RESET}", "playlist lue"); continue
            m = re.search(r"Found\s+(\d+)\s+songs", line)
            if m:
                total = int(m.group(1)); _redraw(f"{C.BADGE_SKIP} LIRE {C.RESET}", "playlist lue"); continue

            md = re.search(r'Downloaded\s+"(.+?)"', line)
            if md:
                done += 1; _redraw(f"{C.BADGE_OK}  OK  {C.RESET}", md.group(1)); continue
            ms = re.search(r"Skipping\s+(.+?)\s+\(file already exists\)", line)
            if ms:
                done += 1; _redraw(f"{C.BADGE_SKIP} SKIP {C.RESET}", ms.group(1)); continue
            m2 = re.search(r"No results found for song:\s*(.+?)\s*$", line)
            if m2:
                t = m2.group(1).strip(); failed.append(t); done += 1
                sys.stdout.write("\r\033[2K")
                print(f"  {C.BADGE_ERR} ERR  {C.RESET} {t}")
                _redraw(); continue
        proc.wait()
    except KeyboardInterrupt:
        # Ctrl+C : on arrete spotdl proprement, sans trace rouge Python.
        try:
            proc.terminate()
            proc.wait(timeout=5)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        sys.stdout.write("\r\033[2K")
        print(f"\n{C.YELLOW}Interrompu (Ctrl+C). Arret en cours...{C.RESET}")
        raise  # remonte pour arreter proprement main()
    sys.stdout.write("\r\033[2K")
    return {"total": total, "done": done, "playlist_name": playlist_name,
            "failed": failed, "rate_limited": rate_limited}


# ===========================================================================
#  Resolution du dossier de playlist + ecriture _missing.txt
# ===========================================================================
def playlist_dir(base: Path, playlist_name: str, new_norms: set, after_files: list[Path]) -> Path:
    if playlist_name:
        safe = re.sub(r'[<>:"/\\|?*]', "", playlist_name).strip().rstrip(".")
        cand = base / safe
        if cand.is_dir():
            return cand
        target = _norm(playlist_name)
        for d in base.iterdir():
            if d.is_dir() and _norm(d.name) == target:
                return d
    run_parents = {p.parent for p in after_files if _norm(p.stem) in new_norms}
    if len(run_parents) == 1:
        return run_parents.pop()
    return base


def write_missing(pl_dir: Path, missing: list[str], url: str, providers: str) -> Path | None:
    missing_path = pl_dir / "_missing.txt"
    if missing:
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        lines = [f"# Titres manquants - {pl_dir.name}", f"# Genere le {stamp}",
                 f"# Playlist : {url}",
                 f"# {len(missing)} titre(s) introuvable(s) sur : {providers}", ""]
        lines += [f"- {lbl}" for lbl in missing]
        missing_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return missing_path
    if missing_path.exists():
        try:
            missing_path.unlink()
        except OSError:
            pass
    return None


PLAYLISTS_FILE = Path(os.environ.get("SPOTDL_PLAYLISTS", str(ROOT / "playlists.txt")))

_SPOTIFY_URL_RE = re.compile(
    r"https?://open\.spotify\.com/(?:intl-[a-z]+/)?(playlist|album)/([A-Za-z0-9]+)", re.I)


def _spotify_ref(url: str):
    """Retourne (type, id) si url est une playlist/album Spotify, sinon None."""
    m = _SPOTIFY_URL_RE.search(url)
    return (m.group(1).lower(), m.group(2)) if m else None


def remember_playlists(urls: list[str]) -> int:
    """Ajoute dans playlists.txt les URLs playlist/album absentes (dedup par id).
    Retourne le nombre d'URLs ajoutees."""
    refs = [(u, _spotify_ref(u)) for u in urls]
    refs = [(u, r) for (u, r) in refs if r is not None]  # garde seulement playlist/album
    if not refs:
        return 0

    # IDs deja presents dans le fichier
    existing_ids = set()
    lines = []
    if PLAYLISTS_FILE.exists():
        lines = PLAYLISTS_FILE.read_text(encoding="utf-8").splitlines()
        for ln in lines:
            r = _spotify_ref(ln)
            if r:
                existing_ids.add(r[1])

    to_add, seen = [], set()
    for url, (_kind, pid) in refs:
        if pid in existing_ids or pid in seen:
            continue
        seen.add(pid)
        to_add.append(url)

    if not to_add:
        return 0

    with PLAYLISTS_FILE.open("a", encoding="utf-8") as f:
        if lines and lines[-1].strip() != "":
            f.write("\n")
        for url in to_add:
            f.write(url + "\n")
    return len(to_add)


def collect_missing_from_file(base: Path) -> list[str]:
    """Lit tous les _missing.txt sous base et renvoie les titres (dedup)."""
    titles, seen = [], set()
    for mf in base.rglob("_missing.txt"):
        for ln in mf.read_text(encoding="utf-8").splitlines():
            ln = ln.strip()
            if ln.startswith("- "):
                t = ln[2:].strip()
                k = _norm(t)
                if k and k not in seen:
                    seen.add(k); titles.append(t)
    return titles


# ===========================================================================
#  main
# ===========================================================================
def main() -> int:
    ap = argparse.ArgumentParser(description="Spotify Downloader")
    ap.add_argument("urls", nargs="*", help="URL(s) Spotify")
    ap.add_argument("--sync", action="store_true", help="synchronise (ajoute les nouveautes)")
    ap.add_argument("--retry", action="store_true", help="retente les titres de _missing.txt")
    ap.add_argument("--file", metavar="F", help="fichier listant des URLs (une par ligne)")
    ap.add_argument("--normaliser", action="store_true", help="force la normalisation loudness")
    ap.add_argument("--dups", action="store_true", help="liste seulement les doublons")
    args = ap.parse_args()

    _enable_ansi()
    cfg = load_config()
    base = Path(cfg["base"])
    base.mkdir(parents=True, exist_ok=True)
    ext = cfg["format"]

    # Mode "lister les doublons" uniquement
    if args.dups:
        dups = find_duplicates(base, ext)
        if not dups:
            print(f"{C.GREEN}Aucun doublon detecte.{C.RESET}")
            return 0
        print(box("DOUBLONS", [f"{C.YELLOW}{len(dups)}{C.RESET} titre(s) en double"], C.YELLOW))
        for _, paths in dups:
            print(f"\n  {C.BADGE_DUP} DUP  {C.RESET} {paths[0].stem.split(' - ', 1)[-1]}")
            for p in paths:
                print(f"      {C.GREY}{p}{C.RESET}")
        return 0

    ensure_deps()

    # Construire la liste d'URLs a traiter
    urls = list(args.urls)
    if args.file:
        fp = Path(args.file)
        if fp.exists():
            urls += [ln.strip() for ln in fp.read_text(encoding="utf-8").splitlines()
                     if ln.strip() and not ln.strip().startswith("#")]
    if args.retry:
        missing_titles = collect_missing_from_file(base)
        if not missing_titles:
            print(f"{C.GREEN}Aucun titre manquant a retenter.{C.RESET}")
            return 0
        print(f"{C.CYAN}Retry de {len(missing_titles)} titre(s) manquant(s)...{C.RESET}")
        urls += missing_titles  # spotdl accepte des requetes texte "Artiste - Titre"

    if not urls:
        print(f"{C.RED}[ERREUR] Aucune URL fournie.{C.RESET}")
        print("Usage : python downloader.py \"<URL Spotify>\" [--sync] [--retry] [--file f] [--normaliser] [--dups]")
        return 1

    action = "sync" if (args.sync or _truthy(cfg["sync"])) else "download"
    do_norm = args.normaliser or _truthy(cfg["normaliser"])

    print()
    print(box("SPOTIFY  DOWNLOADER", [
        f"{C.GREY}Sortie    {C.RESET}: {base}",
        f"{C.GREY}Format    {C.RESET}: {C.BOLD}{cfg['format']} {cfg['bitrate']}{C.RESET}",
        f"{C.GREY}Sources   {C.RESET}: {cfg['providers']}",
        f"{C.GREY}Threads   {C.RESET}: {cfg['threads']}   {C.GREY}Skip{C.RESET}: {cfg['skip_existants']}"
        f"   {C.GREY}Mode{C.RESET}: {action}   {C.GREY}Normaliser{C.RESET}: {'oui' if do_norm else 'non'}",
        f"{C.GREY}A traiter {C.RESET}: {len(urls)} source(s)",
    ], color=C.CYAN))
    print()

    before = set(_norm(p.stem) for p in base.rglob(f"*.{ext}"))

    # Log complet horodate du run
    log_dir = base
    log_path = log_dir / "_download.log"
    agg_failed, agg_total, agg_done = [], 0, 0
    last_playlist_name = ""

    with log_path.open("a", encoding="utf-8") as log_fh:
        log_fh.write(f"\n===== {datetime.now():%Y-%m-%d %H:%M:%S} | mode={action} | {len(urls)} source(s) =====\n")
        for idx, url in enumerate(urls, 1):
            if len(urls) > 1:
                print(f"{C.MAGENTA}[{idx}/{len(urls)}]{C.RESET} {url}")
            # 1er essai + 1 retry avec moins de threads si rate-limit
            res = run_spotdl(action, url, cfg, base, log_fh)
            if res["rate_limited"]:
                wait = 20
                print(f"\n  {C.YELLOW}Rate-limit detecte -- pause {wait}s puis retry a threads reduits...{C.RESET}")
                time.sleep(wait)
                res = run_spotdl(action, url, cfg, base, log_fh,
                                 threads_override=max(2, int(cfg["threads"]) // 2))
            agg_failed += res["failed"]
            agg_total += res["total"]
            agg_done += res["done"]
            last_playlist_name = res["playlist_name"] or last_playlist_name
            # barre finale a 100% pour cette source
            final = res["total"] if res["total"] else max(res["done"], 1)
            print(f"  {progress_bar(final, final)}")
            print()

    after_files = list(base.rglob(f"*.{ext}"))
    after = set(_norm(p.stem) for p in after_files)
    new_norms = after - before

    # Memorise les playlists/albums traites dans playlists.txt (pour re-sync).
    # On ne le fait pas en mode --file (la liste vient deja de ce fichier).
    added_pl = 0
    if not args.file:
        added_pl = remember_playlists(list(args.urls))

    # Manquants reels (dedup, et pas presents sur le disque)
    missing, seen = [], set()
    for lbl in agg_failed:
        title = lbl.split(" - ", 1)[-1]
        nt = _norm(title)
        if not nt or nt in seen:
            continue
        seen.add(nt)
        if not any(nt in d for d in after):
            missing.append(lbl)

    # Normalisation loudness des fichiers ajoutes ce run
    normalized = 0
    if do_norm and new_norms:
        new_files = [p for p in after_files if _norm(p.stem) in new_norms]
        if new_files:
            print(f"{C.MAGENTA}Normalisation loudness ({len(new_files)} fichier(s))...{C.RESET}")
            normalized = normalize_loudness(new_files)
            print(f"  {C.GREEN}{normalized} fichier(s) normalise(s) a -14 LUFS.{C.RESET}\n")

    # Doublons
    dups = find_duplicates(base, ext)

    ok = (agg_total - len(missing)) if agg_total else len(after)
    denom = agg_total if agg_total else max(len(after), 1)
    summary = [
        f"{C.GREEN}✓ {ok}/{denom}{C.RESET} titre(s) presents sur le disque",
        f"{C.CYAN}+{len(new_norms)}{C.RESET} ajoute(s) ce run   {C.GREY}({len(after)} au total){C.RESET}",
    ]
    if normalized:
        summary.append(f"{C.MAGENTA}♪ {normalized}{C.RESET} normalise(s) a -14 LUFS")
    if missing:
        summary.append(f"{C.RED}✗ {len(missing)}{C.RESET} introuvable(s) -> _missing.txt")
    if dups:
        summary.append(f"{C.YELLOW}⧉ {len(dups)}{C.RESET} doublon(s) -- 'downloader.py --dups' pour la liste")
    if added_pl:
        summary.append(f"{C.CYAN}+{added_pl}{C.RESET} playlist(s) ajoutee(s) a playlists.txt")
    print(box("RESUME", summary, color=C.GREEN if not missing else C.YELLOW))
    print()

    # _missing.txt dans le dossier de la (derniere) playlist
    pl_dir = playlist_dir(base, last_playlist_name, new_norms, after_files)
    url_for_log = urls[0] if len(urls) == 1 else f"{len(urls)} sources"
    mp = write_missing(pl_dir, missing, url_for_log, cfg["providers"])
    if missing:
        for lbl in missing:
            print(f"  {C.RED}-{C.RESET} {lbl}")
        print(f"\n{C.GREY}Liste ecrite dans : {mp}{C.RESET}")
    elif agg_total:
        print(f"  {C.GREEN}Tous les titres ont ete importes. 🎉{C.RESET}")

    print(f"\n{C.GREY}Fichiers dans : {base}{C.RESET}")
    print(f"{C.GREY}Log complet   : {log_path}{C.RESET}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(f"\n{C.YELLOW}Annule par l'utilisateur.{C.RESET}")
        sys.exit(130)
