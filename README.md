# Spotify Downloader

Télécharge des playlists / albums / titres Spotify en **MP3 320 kbps** (compatibilité DJ maximale), avec un sous-dossier par playlist, les tags propres, une **barre de progression (ETA + débit)**, des **badges colorés** (OK / SKIP / ERR), un `_missing.txt` des titres introuvables, et plein d'options pratiques.

> Spotify étant du streaming avec DRM, l'audio est récupéré sur SoundCloud / YouTube Music / Bandcamp à partir des métadonnées de la playlist Spotify (via `spotdl`).

## Arborescence

```
spotify-downloader\
├── download.bat        <- double-clique ICI (menu navigable aux flèches)
├── settings.ini        <- ta config
├── README.md
├── playlists.txt       <- (optionnel) liste d'URLs à télécharger en lot
├── bin\
│   ├── download.ps1    <- interface PowerShell 7 (menu ↑↓ + Entrée)
│   ├── downloader.py   <- moteur
│   └── requirements.txt
├── docker\             <- serveur NAS (Debian) : image + API + sync auto
│   ├── Dockerfile
│   ├── compose.yml
│   ├── .env.example
│   ├── api.py          <- API HTTP (manifest / file / playlists)
│   ├── entrypoint.sh   <- token + boucle de sync + API
│   └── sync-playlists.sh
├── scripts\            <- client Windows (bridge vers le NAS)
│   ├── setup-nas.ps1   <- install du serveur via SSH (one-shot)
│   ├── sync-from-nas.ps1 <- sync NAS → clé USB (delta 3 états)
│   └── playlists.ps1   <- gérer les playlists suivies à distance
└── Musique\            <- sortie locale (créée automatiquement)
```

## Utilisation

**Double-clic sur `download.bat`** → un menu navigable aux **flèches ↑ ↓** (ou touches 1-5), valide avec **Entrée** :

1. Télécharger une playlist / album / titre
2. Synchroniser une playlist (ajoute les nouveautés, retire les retirés)
3. Retenter les titres manquants (`_missing.txt`)
4. Lister les doublons
5. Télécharger plusieurs playlists (fichier `playlists.txt`)

### En ligne de commande

```powershell
python bin\downloader.py "<URL>"              # téléchargement simple
python bin\downloader.py --sync "<URL>"       # synchronisation
python bin\downloader.py --retry              # retente les manquants
python bin\downloader.py --file playlists.txt # plusieurs URLs
python bin\downloader.py --normaliser "<URL>" # + normalisation loudness
python bin\downloader.py --dups               # liste les doublons
python bin\downloader.py "<url1>" "<url2>"    # plusieurs URLs d'un coup
```

## Fonctionnalités

- **Barre de progression** avec ETA et débit (titres/min), badges OK / SKIP / ERR colorés.
- **Sync de playlist** (`--sync`) : suit une playlist qui évolue.
- **Retry ciblé** (`--retry`) : relit tous les `_missing.txt` et retente uniquement ces titres.
- **Normalisation loudness** (`--normaliser` ou `normaliser = oui`) : harmonise le volume à **-14 LUFS** (EBU R128) via ffmpeg — idéal pour un set DJ.
- **Détection de doublons** (`--dups`) : regroupe les titres présents plusieurs fois.
- **Lot de playlists** (`--file`) : une URL par ligne (lignes `#` ignorées).
- **Backoff rate-limit** : si YouTube/SoundCloud throttle, pause puis retry à threads réduits.
- **Log complet** : `Musique\_download.log` horodaté à chaque run.
- **Auto-install** : `spotdl`, **Deno** (titres YouTube protégés) et **ffmpeg** s'installent automatiquement s'ils sont absents (dans `~/.spotdl`).

## Configuration — `settings.ini`

| Réglage | Rôle | Défaut |
|---------|------|--------|
| `base` | Dossier de sortie | `...\Musique` |
| `format` / `bitrate` | Qualité | `mp3` / `320k` |
| `providers` | Sources dans l'ordre | `soundcloud youtube-music bandcamp` |
| `normaliser` | Normalisation loudness | `oui` |
| `template` | Nommage | `{list-name}\{artists} - {title}.{output-ext}` |
| `threads` | Téléchargements simultanés | `8` |
| `skip_existants` | Ne pas re-télécharger | `oui` |
| `scan_complet` | Re-scan complet (plus lent) | `non` |
| `sync` | Mode sync par défaut | `non` |

### Dossier de sortie sur clé USB

```ini
[sortie]
base = U:\MUSIC
```

## Prérequis

- **PowerShell 7** (`pwsh`) — `winget install Microsoft.PowerShell`
- **Python 3.9+** dans le PATH

`spotdl`, `ffmpeg` et `Deno` s'installent tout seuls au premier lancement.

## Dépannage

- **Titres de niche introuvables** : garde `providers = soundcloud ...` en premier.
- **Rate limit / lenteur** : baisse `threads` à `4` (le backoff gère déjà les pics).
- **Volumes DJ inégaux** : active `normaliser = oui`.

---

# Mode NAS + bridge Windows (sync automatique)

Déploiement en **deux côtés** : un serveur sur ton NAS (Debian 13 + Docker) qui
synchronise les playlists toutes les **10 min**, et un client Windows qui tire
la bibliothèque vers une clé USB **via une API HTTP + token** (jamais de SSH au
quotidien).

```
┌──────────── NAS (Debian 13 + Docker) ────────────┐        ┌──── PC Windows ────┐
│  conteneur spotify-downloader                      │  HTTP  │ sync-from-nas.ps1  │
│   • sync playlists.txt → /musique  (toutes 10 min) │ ◄──────│  delta 3 états     │
│   • API : /manifest /file /playlists /status        │ +token │  → clé USB (miroir)│
└─────────────────────────────────────────────────────┘        └────────────────────┘
```

## 1. Serveur NAS (Debian 13)

**Option A — image pré-buildée (ghcr.io, recommandé) :** aucune compilation sur
le NAS.

```bash
git clone https://github.com/DorvakOff/spotify-downloader.git
cd spotify-downloader/docker
cp .env.example .env          # édite MUSIC_DIR, API_PORT, SYNC_INTERVAL...
docker compose pull           # tire l'image publiée par GitHub Actions
docker compose up -d
```

**Option B — build local** (si tu veux builder sur le NAS) :

```bash
docker compose up -d --build
```

**Récupère le token** généré au 1er démarrage :

```bash
docker compose exec downloader cat /state/api_token
```

Vérifie que l'API répond : `curl http://localhost:8787/health`

**Réglages** (dans `docker/.env`) :

| Variable | Rôle | Défaut |
|----------|------|--------|
| `MUSIC_DIR` | Dossier musique sur le NAS | `./musique` |
| `API_PORT` | Port de l'API | `8787` |
| `SYNC_INTERVAL` | Fréquence du sync (`10m`, `6h`, `3600`) | `10m` |
| `SYNC_ON_START` | Sync au démarrage | `oui` |
| `SPOTDL_*` | Qualité (format, bitrate, providers, threads, normaliser) | cf. `settings.ini` |

Les playlists suivies sont dans `docker/config/playlists.txt` (créé au 1er boot).

## 2. Client Windows

**Install guidée (une seule fois, via SSH)** — installe Docker sur le NAS, lance
le conteneur, récupère le token et l'enregistre dans `settings.ini` :

```powershell
.\scripts\setup-nas.ps1
```

**Sync quotidien (via API, sans SSH)** — tire le NAS vers ta clé USB en calculant
un vrai delta :

```powershell
.\scripts\sync-from-nas.ps1
```

- **Ajout** : nouveau sur le NAS → téléchargé
- **Modif** : taille/hash différent → re-téléchargé
- **Suppression** : absent du NAS → supprimé localement (**mode miroir par défaut**)

Options : `-NoDelete` (ajout+modif seulement), `-NoHash` (compare taille/mtime,
plus rapide), `-Yes` (pas de confirmation avant suppressions).

**Gérer les playlists suivies à distance** (sans SSH) :

```powershell
.\scripts\playlists.ps1 list
.\scripts\playlists.ps1 add    https://open.spotify.com/playlist/XXXX
.\scripts\playlists.ps1 remove https://open.spotify.com/playlist/XXXX
```

La config du bridge est stockée dans `settings.ini` :

```ini
[nas]
server = http://192.168.1.50:8787
token = <token généré>
dest = U:\MUSIC
```

## Sécurité

Le token donne un accès **en lecture** à toute la bibliothèque sur le port de
l'API. À garder sur **réseau local** (ou derrière un VPN) — ne l'expose pas nu
sur Internet sans HTTPS/reverse-proxy.
