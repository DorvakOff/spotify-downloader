<#
.SYNOPSIS
    Synchronise la bibliotheque musicale du NAS vers un dossier local (cle USB).
    Delta 3 etats : ajout, modification, suppression (mode miroir par defaut).

.DESCRIPTION
    Dialogue avec l'API HTTP du conteneur NAS (manifest + /file) via un token
    Bearer. Aucune connexion SSH : tout passe par HTTP.

    - AJOUT      : fichier present sur le NAS, absent en local        -> telecharge
    - MODIF      : present des deux cotes, taille/hash different       -> re-telecharge
    - SUPPRESSION: absent du NAS, present en local                     -> supprime (miroir)

    Config lue depuis settings.ini (section [nas]) a la racine du projet,
    ou via les parametres ci-dessous (qui priment).

.PARAMETER Server    URL de base de l'API, ex. http://192.168.1.50:8787
.PARAMETER Token     Token Bearer de l'API.
.PARAMETER Dest      Dossier local de destination (cle USB), ex. U:\MUSIC
.PARAMETER NoDelete  Desactive la suppression locale (sync ajout+modif seulement).
.PARAMETER NoHash    Compare par taille+mtime seulement (plus rapide, moins sur).
.PARAMETER Yes       N'affiche pas la confirmation avant les suppressions.

.EXAMPLE
    .\sync-from-nas.ps1 -Server http://192.168.1.50:8787 -Token abc... -Dest U:\MUSIC
#>
[CmdletBinding()]
param(
    [string]$Server,
    [string]$Token,
    [string]$Dest,
    [switch]$NoDelete,
    [switch]$NoHash,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- Palette (coherente avec download.ps1) ---
function W([string]$t,[string]$c='Gray'){ Write-Host $t -ForegroundColor $c }

# --- Chargement de la config [nas] depuis settings.ini -----------------------
$Root = Split-Path -Parent $PSScriptRoot    # scripts/ -> racine du projet
$Ini  = Join-Path $Root 'settings.ini'

function Get-IniValue([string]$path,[string]$section,[string]$key){
    if(-not (Test-Path $path)){ return $null }
    $cur=''; foreach($line in Get-Content $path -Encoding UTF8){
        $l=$line.Trim()
        if($l -match '^\[(.+)\]$'){ $cur=$Matches[1]; continue }
        if($cur -eq $section -and $l -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$"){
            return $Matches[1].Trim()
        }
    }
    return $null
}

if(-not $Server){ $Server = Get-IniValue $Ini 'nas' 'server' }
if(-not $Token ){ $Token  = Get-IniValue $Ini 'nas' 'token'  }
if(-not $Dest  ){ $Dest   = Get-IniValue $Ini 'nas' 'dest'   }

if(-not $Server -or -not $Token -or -not $Dest){
    W "Configuration NAS incomplete." Red
    W "Renseigne [nas] server/token/dest dans settings.ini, ou passe -Server -Token -Dest." Yellow
    W "Astuce : lance d'abord setup-nas.ps1 pour installer le serveur et recuperer le token." Gray
    exit 1
}

$Server = $Server.TrimEnd('/')
$headers = @{ Authorization = "Bearer $Token" }

W ""
W "  Serveur : $Server" Cyan
W "  Dest    : $Dest" Cyan
W "  Mode    : $([string]::Format('{0}', $(if($NoDelete){'ajout + modif (sans suppression)'}else{'MIROIR (ajout + modif + suppression)'})))" Cyan
W ""

# --- Verif de connectivite ---------------------------------------------------
try {
    $h = Invoke-RestMethod -Uri "$Server/health" -TimeoutSec 10
    if(-not $h.ok){ throw "reponse health inattendue" }
} catch {
    W "Impossible de joindre l'API ($Server/health) : $($_.Exception.Message)" Red
    exit 1
}

# --- Recuperation du manifest distant ---------------------------------------
$hashParam = if($NoHash){ 0 } else { 1 }
W "Recuperation du manifest distant..." Gray
try {
    $manifest = Invoke-RestMethod -Uri "$Server/manifest?hash=$hashParam" -Headers $headers -TimeoutSec 120
} catch {
    W "Echec /manifest : $($_.Exception.Message)" Red
    if($_.Exception.Response.StatusCode.value__ -eq 401){ W "-> Token invalide." Yellow }
    exit 1
}
$remote = @{}
foreach($f in $manifest.files){ $remote[$f.path] = $f }
W ("  $($manifest.count) fichier(s) sur le NAS.") Gray

# --- Index local -------------------------------------------------------------
if(-not (Test-Path $Dest)){ New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
$DestFull = (Resolve-Path $Dest).Path
$audioExt = @('.mp3','.opus','.m4a','.flac','.wav')
$localFiles = Get-ChildItem -Path $DestFull -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $audioExt -contains $_.Extension.ToLower() }
$local = @{}
foreach($lf in $localFiles){
    $rel = $lf.FullName.Substring($DestFull.Length).TrimStart('\','/').Replace('\','/')
    $local[$rel] = $lf
}

function Get-Sha256([string]$path){
    (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLower()
}

# --- Calcul du delta 3 etats -------------------------------------------------
$toAdd=@(); $toUpdate=@(); $toDelete=@()
foreach($path in $remote.Keys){
    $r = $remote[$path]
    if(-not $local.ContainsKey($path)){
        $toAdd += $path; continue
    }
    $lf = $local[$path]
    $diff = $false
    if($lf.Length -ne $r.size){ $diff = $true }
    elseif(-not $NoHash -and $r.sha256){
        if((Get-Sha256 $lf.FullName) -ne $r.sha256){ $diff = $true }
    }
    if($diff){ $toUpdate += $path }
}
foreach($path in $local.Keys){
    if(-not $remote.ContainsKey($path)){ $toDelete += $path }
}

W ""
W ("  + {0} ajout(s)" -f $toAdd.Count)    Green
W ("  ~ {0} modif(s)" -f $toUpdate.Count) Cyan
W ("  - {0} suppression(s)" -f $toDelete.Count) $(if($NoDelete){'DarkGray'}else{'Red'})
W ""

if($toAdd.Count -eq 0 -and $toUpdate.Count -eq 0 -and ($NoDelete -or $toDelete.Count -eq 0)){
    W "Deja a jour. Rien a faire." Green
    exit 0
}

# --- Confirmation des suppressions (filet de securite) -----------------------
if(-not $NoDelete -and $toDelete.Count -gt 0 -and -not $Yes){
    W "Les fichiers suivants seront SUPPRIMES localement (absents du NAS) :" Yellow
    $toDelete | Select-Object -First 15 | ForEach-Object { W "    - $_" DarkGray }
    if($toDelete.Count -gt 15){ W "    ... et $($toDelete.Count - 15) autre(s)" DarkGray }
    $ans = Read-Host "Confirmer la suppression de $($toDelete.Count) fichier(s) ? (o/N)"
    if($ans -notmatch '^[oOyY]'){ W "Suppressions annulees -- sync ajout/modif seulement." Yellow; $toDelete=@() }
}

# --- Telechargement (ajout + modif) -----------------------------------------
function Download-One([string]$rel){
    $target = Join-Path $DestFull ($rel -replace '/','\')
    $dir = Split-Path -Parent $target
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$target.part"
    $uri = "$Server/file?path=" + [uri]::EscapeDataString($rel)
    Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $tmp -TimeoutSec 600 | Out-Null
    Move-Item -Path $tmp -Destination $target -Force
}

$work = @($toAdd + $toUpdate)
$n = $work.Count; $i = 0
foreach($rel in $work){
    $i++
    $pct = [int](($i/$n)*100)
    Write-Host ("`r[{0,3}%] {1}/{2}  {3}" -f $pct,$i,$n,($rel.Substring([Math]::Max(0,$rel.Length-48)))) -NoNewline -ForegroundColor Cyan
    try { Download-One $rel }
    catch { Write-Host ""; W "  ERREUR sur $rel : $($_.Exception.Message)" Red }
}
if($n -gt 0){ Write-Host "" }

# --- Suppressions (miroir) ---------------------------------------------------
foreach($rel in $toDelete){
    $target = Join-Path $DestFull ($rel -replace '/','\')
    if(Test-Path $target){ Remove-Item $target -Force -ErrorAction SilentlyContinue }
}
# Nettoyage des dossiers vides laisses par les suppressions.
if($toDelete.Count -gt 0){
    Get-ChildItem $DestFull -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }
}

W ""
W ("Termine : +{0} ~{1} -{2}" -f $toAdd.Count,$toUpdate.Count,$toDelete.Count) Green
