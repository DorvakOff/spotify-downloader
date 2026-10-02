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
└── Musique\            <- sortie (créée automatiquement)
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
| `normaliser` | Normalisation loudness | `non` |
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
