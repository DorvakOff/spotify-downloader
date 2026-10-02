<#
.SYNOPSIS
    Assistant d'installation du serveur spotify-downloader sur un NAS Debian.
    Utilise SSH UNE SEULE FOIS (install) ; ensuite tout passe par l'API HTTP.

.DESCRIPTION
    1. Demande les identifiants SSH du NAS (hote, utilisateur).
    2. Copie le projet sur le NAS (via scp) dans ~/spotify-downloader.
    3. Installe Docker si absent, puis lance `docker compose up -d --build`.
    4. Recupere le token API genere et l'ecrit dans settings.ini [nas],
       avec l'URL du serveur et le dossier de destination local.

    Prerequis : ssh.exe et scp.exe (inclus dans Windows 10/11), un acces SSH
    actif sur le NAS (mot de passe ou cle), et Docker installable (sudo).

.PARAMETER NasHost   Hote/IP du NAS, ex. 192.168.1.50
.PARAMETER NasUser   Utilisateur SSH, ex. debian
.PARAMETER ApiPort   Port de l'API (defaut 8787)
.PARAMETER Dest      Dossier local (cle USB) a enregistrer pour le sync, ex. U:\MUSIC
.PARAMETER MusicDir  Dossier musique cote NAS (defaut ~/spotify-downloader/musique)
#>
[CmdletBinding()]
param(
    [string]$NasHost,
    [string]$NasUser,
    [int]$ApiPort = 8787,
    [string]$Dest,
    [string]$MusicDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function W([string]$t,[string]$c='Gray'){ Write-Host $t -ForegroundColor $c }

$Root = Split-Path -Parent $PSScriptRoot
$Ini  = Join-Path $Root 'settings.ini'

# --- Prerequis locaux --------------------------------------------------------
foreach($bin in 'ssh','scp'){
    if(-not (Get-Command $bin -ErrorAction SilentlyContinue)){
        W "$bin introuvable. Active 'OpenSSH Client' dans Windows (Parametres > Applications > Fonctionnalites facultatives)." Red
        exit 1
    }
}

# --- Saisie interactive si besoin --------------------------------------------
if(-not $NasHost){ $NasHost = Read-Host "Hote/IP du NAS (ex. 192.168.1.50)" }
if(-not $NasUser){ $NasUser = Read-Host "Utilisateur SSH (ex. debian)" }
if(-not $Dest){
    $Dest = Read-Host "Dossier local de destination pour le sync (ex. U:\MUSIC)"
}
$remoteDir = "~/spotify-downloader"
$SshTarget = "$NasUser@$NasHost"

W ""
W "  NAS      : $SshTarget" Cyan
W "  Dossier  : $remoteDir (sur le NAS)" Cyan
W "  Port API : $ApiPort" Cyan
W "  Dest     : $Dest (local)" Cyan
W ""
W "SSH ne sera utilise QUE pour cette installation. Entre ton mot de passe quand demande." Gray
W ""

# --- 1. Test SSH -------------------------------------------------------------
W "[1/5] Test de la connexion SSH..." Yellow
$whoami = ssh -o StrictHostKeyChecking=accept-new $SshTarget "echo OK; uname -a" 2>&1
if($LASTEXITCODE -ne 0 -or $whoami -notmatch 'OK'){
    W "Connexion SSH echouee : $whoami" Red
    exit 1
}
W "  Connecte : $whoami" Green

# --- 2. Copie du projet (scp) ------------------------------------------------
W "[2/5] Copie du projet sur le NAS..." Yellow
ssh $SshTarget "mkdir -p $remoteDir" 2>&1 | Out-Null
# On copie le strict necessaire au build (pas la musique ni les .git).
$items = @('bin','docker','settings.ini','playlists.txt','README.md')
foreach($it in $items){
    $src = Join-Path $Root $it
    if(Test-Path $src){
        scp -r -o StrictHostKeyChecking=accept-new $src "${SshTarget}:$remoteDir/" 2>&1 | Out-Null
    }
}
W "  Projet copie dans $remoteDir" Green

# --- 3. Installation de Docker si absent -------------------------------------
W "[3/5] Verification/installation de Docker..." Yellow
$dockerCheck = ssh $SshTarget "command -v docker >/dev/null 2>&1 && echo HAS_DOCKER || echo NO_DOCKER" 2>&1
if($dockerCheck -match 'NO_DOCKER'){
    W "  Docker absent -- installation via get.docker.com (sudo requis)..." Gray
    $install = "curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker $NasUser"
    ssh -t $SshTarget $install 2>&1 | ForEach-Object { W "    $_" DarkGray }
} else {
    W "  Docker deja present." Green
}

# --- 4. Build + up -----------------------------------------------------------
W "[4/5] Build et demarrage du conteneur (peut prendre quelques minutes)..." Yellow
$envSetup = @"
cd $remoteDir/docker
[ -f .env ] || cp .env.example .env
sed -i 's/^API_PORT=.*/API_PORT=$ApiPort/' .env
"@
if($MusicDir){
    $md = $MusicDir.Replace('/','\/')
    $envSetup += "`nsed -i 's/^MUSIC_DIR=.*/MUSIC_DIR=$md/' .env"
}
$up = "$envSetup`n(sudo docker compose up -d --build || docker compose up -d --build)"
ssh -t $SshTarget $up 2>&1 | ForEach-Object { W "    $_" DarkGray }

# --- 5. Recuperation du token ------------------------------------------------
W "[5/5] Recuperation du token API..." Yellow
Start-Sleep -Seconds 3
$token = ssh $SshTarget "cd $remoteDir/docker; (sudo docker compose exec -T downloader cat /state/api_token 2>/dev/null || docker compose exec -T downloader cat /state/api_token 2>/dev/null) | tr -d '\r\n'" 2>&1
$token = ($token | Select-Object -Last 1).ToString().Trim()
if($token -notmatch '^[0-9a-f]{32,}$'){
    W "  Token non recupere automatiquement (reponse : $token)." Yellow
    W "  Recupere-le manuellement : ssh $SshTarget 'cd $remoteDir/docker; docker compose exec downloader cat /state/api_token'" Gray
    $token = Read-Host "Colle le token ici (ou laisse vide pour finir plus tard)"
}

$serverUrl = "http://${NasHost}:$ApiPort"

# --- Ecriture de [nas] dans settings.ini -------------------------------------
if($token){
    W "Enregistrement dans settings.ini [nas]..." Gray
    $content = if(Test-Path $Ini){ Get-Content $Ini -Raw -Encoding UTF8 } else { "" }
    # Retire une ancienne section [nas] si presente.
    $content = [regex]::Replace($content, '(?ms)^\[nas\].*?(?=^\[|\Z)', '')
    $block = @"

[nas]
# Bridge NAS <-> Windows (genere par setup-nas.ps1).
server = $serverUrl
token = $token
dest = $Dest
"@
    ($content.TrimEnd() + "`n" + $block).TrimStart() | Set-Content $Ini -Encoding UTF8
    W "  settings.ini mis a jour." Green
}

W ""
W "============================================================" Green
W " Installation terminee." Green
W "============================================================" Green
W " Serveur API : $serverUrl" Cyan
W " Verifie     : curl $serverUrl/health" Gray
W ""
W " Pour synchroniser vers ta cle USB (quotidien, sans SSH) :" Cyan
W "   .\scripts\sync-from-nas.ps1" Gray
W ""
if($token){ W " Le token a ete enregistre dans settings.ini." Gray }
