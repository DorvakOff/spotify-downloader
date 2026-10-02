#!/usr/bin/env pwsh
# ============================================================
#  Spotify Downloader - lanceur PowerShell 7
#  Double-clique download.bat, ou lance : pwsh ./download.ps1
# ============================================================

$ErrorActionPreference = 'Stop'

# --- Encodage UTF-8 de bout en bout ---
# Page de code console en UTF-8 (sinon les accents / caracteres speciaux
# comme Ø sortent en ◆).
try { chcp 65001 > $null } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
# Force la sortie de Python (et spotdl) en UTF-8.
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"

Set-Location $PSScriptRoot

# Couleurs
function Write-C($Text, $Color = 'White') { Write-Host $Text -ForegroundColor $Color }

# Palette : accent cyan/teal (plus doux que le magenta).
$Accent = 'Cyan'
$Border = 'DarkCyan'

Write-Host ""
$w = 48
$title = "SPOTIFY  DOWNLOADER"
$tpad = $w - 2 - $title.Length
Write-C ("  ╭" + ("─" * $w) + "╮") $Border
Write-Host ("  │  ") -ForegroundColor $Border -NoNewline
Write-Host $title -ForegroundColor $Accent -NoNewline
Write-Host ((" " * $tpad) + "│") -ForegroundColor $Border
Write-C ("  ╰" + ("─" * $w) + "╯") $Border
Write-Host ""

# ---- 1) Python present ? ----
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-C "[ERREUR] Python introuvable. Installe Python 3.9+ depuis" Red
    Write-C "         https://www.python.org/downloads/ (coche 'Add to PATH')." Red
    Read-Host "Appuie sur Entree pour quitter"
    exit 1
}

# ---- 2) spotdl present ? sinon installation ----
& python -m spotdl --version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-C "[setup] spotdl absent - installation..." Yellow
    & python -m pip install --upgrade pip
    & python -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt')
    & python -m spotdl --version *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-C "[ERREUR] Installation de spotdl echouee." Red
        Read-Host "Appuie sur Entree pour quitter"
        exit 1
    }
    Write-C "[setup] spotdl installe." Green
}

# ---- 3) Deno present ? sinon installation ----
$deno = Join-Path $env:USERPROFILE ".spotdl\deno.exe"
if (-not (Test-Path $deno)) {
    Write-C "[setup] Deno absent - installation (requis par certains titres YouTube)..." Yellow
    & python -m spotdl --download-deno
}

# ---- 4) Menu navigable aux fleches ↑ ↓ + Entree ----
function Show-Menu {
    param([string[]]$Items, [string]$Title = "Que veux-tu faire ?")
    $sel = 0
    # Capturer Ctrl+C comme une touche normale pour l'annuler proprement
    # (sinon il tue le process et laisse le terminal dans un etat bizarre).
    $prevCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    [Console]::CursorVisible = $false
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor DarkGray
    Write-Host ""
    $startTop = [Console]::CursorTop
    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $startTop)
            foreach ($i in 0..($Items.Count - 1)) {
                [Console]::Write("`e[2K")
                if ($i -eq $sel) {
                    Write-Host ("   ❯ " + $Items[$i]) -ForegroundColor Black -BackgroundColor Cyan
                } else {
                    Write-Host ("     " + $Items[$i]) -ForegroundColor Gray
                }
            }
            [Console]::Write("`e[2K"); Write-Host ""
            [Console]::Write("`e[2K")
            Write-Host "  ↑/↓ naviguer   Entree valider   Echap/Ctrl+C annuler" -ForegroundColor DarkGray
            [Console]::SetCursorPosition(0, $startTop)

            $key = [Console]::ReadKey($true)
            # Ctrl+C -> annulation
            if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq 'C') { return -1 }
            switch ($key.Key) {
                "UpArrow"   { $sel = (($sel - 1) + $Items.Count) % $Items.Count }
                "DownArrow" { $sel = ($sel + 1) % $Items.Count }
                "Enter"     { return $sel }
                "Escape"    { return -1 }
            }
            if ($key.KeyChar -match '^[1-9]$') {
                $n = [int]$key.KeyChar.ToString() - 1
                if ($n -lt $Items.Count) { return $n }
            }
        }
    } finally {
        [Console]::CursorVisible = $true
        [Console]::TreatControlCAsInput = $prevCtrlC
        # descendre sous le menu pour que la suite s'affiche proprement
        try { [Console]::SetCursorPosition(0, $startTop + $Items.Count + 2) } catch {}
    }
}

$items = @(
    "Telecharger une playlist / album / titre",
    "Synchroniser une playlist (ajoute les nouveautes)",
    "Retenter les titres manquants (_missing.txt)",
    "Lister les doublons",
    "Telecharger PLUSIEURS playlists (fichier)"
)
$idx = Show-Menu -Items $items
if ($idx -lt 0) { Write-C "Annule." Yellow; exit 0 }

$py = Join-Path $PSScriptRoot 'downloader.py'
Write-Host ""

switch ($idx) {
    2 { & python $py --retry }
    3 { & python $py --dups }
    4 {
        $f = Read-Host "Chemin du fichier (defaut: playlists.txt a la racine)"
        if ([string]::IsNullOrWhiteSpace($f)) { $f = Join-Path (Split-Path $PSScriptRoot) 'playlists.txt' }
        & python $py --file $f
    }
    Default {
        $sync = ($idx -eq 1)
        Write-C "Colle l'URL d'une playlist / album / titre Spotify :" Cyan
        $url = Read-Host "URL"
        if ([string]::IsNullOrWhiteSpace($url)) {
            Write-C "[ERREUR] Aucune URL fournie." Red
            Read-Host "Appuie sur Entree pour quitter"; exit 1
        }
        Write-Host ""
        if ($sync) { & python $py --sync $url } else { & python $py $url }
    }
}

Write-Host ""
Read-Host "Termine. Appuie sur Entree pour fermer"
