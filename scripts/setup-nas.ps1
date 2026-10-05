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

$ErrorActionPreference = 'Continue'
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

# --- Cle SSH dediee : 1 seul prompt mot de passe pour toute l'install --------
# On ne "cache" PAS le mot de passe (ce serait du clair sur disque) : on
# installe une cle publique dediee sur le NAS. Tu tapes ton mot de passe UNE
# fois (pour poser la cle), ensuite toutes les commandes passent par la cle,
# sans aucun prompt -- cette fois-ci comme les suivantes.
$KeyPath = Join-Path $env:USERPROFILE '.ssh\id_spotdl_nas'
$SshOpts = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=10')

function Invoke-Sshk { param([string]$Cmd,[switch]$Tty)
    # Les here-strings PowerShell contiennent des CRLF ; bash recoit alors un
    # \r colle a chaque commande (cd: '...docker\r': introuvable). On force LF.
    $Cmd = $Cmd -replace "`r`n","`n" -replace "`r","`n"
    $a = @('-i',$KeyPath,'-o','BatchMode=yes') + $SshOpts
    if($Tty){ $a += '-t' }
    $a += @($SshTarget, $Cmd)
    & ssh @a 2>&1
}
function Invoke-Scpk { param([string]$Src,[string]$RemoteRel)
    $a = @('-i',$KeyPath,'-o','BatchMode=yes','-r') + $SshOpts + @($Src, "${SshTarget}:$RemoteRel")
    & scp @a 2>&1
}

if(-not (Test-Path $KeyPath)){
    W "Generation d'une cle SSH dediee ($KeyPath)..." Gray
    $sshDir = Split-Path $KeyPath
    if(-not (Test-Path $sshDir)){ New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
    & ssh-keygen -t ed25519 -N '""' -f $KeyPath -C 'spotify-downloader-nas' 2>&1 | Out-Null
}
$pubKey = (Get-Content "$KeyPath.pub" -Raw).Trim()

W ""
W "  NAS      : $SshTarget" Cyan
W "  Dossier  : $remoteDir (sur le NAS)" Cyan
W "  Port API : $ApiPort" Cyan
W "  Dest     : $Dest (local)" Cyan
W ""

# --- 1. Installation de la cle (UN SEUL prompt mot de passe) -----------------
W "[1/5] Connexion SSH + installation de la cle..." Yellow
# Teste si la cle fonctionne deja (relance du script -> aucun prompt).
$probe = Invoke-Sshk "echo SSHOK" 
if($probe -notmatch 'SSHOK'){
    W "  Premiere connexion : entre ton mot de passe SSH UNE SEULE FOIS." Gray
    # ssh-copy-id n'existe pas sur Windows -> on pousse la cle a la main.
    $install = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pubKey' ~/.ssh/authorized_keys 2>/dev/null || echo '$pubKey' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo KEYOK"
    $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $res = (& ssh @SshOpts $SshTarget $install 2>&1 | Out-String)
    $ErrorActionPreference = $prevEAP
    if($res -notmatch 'KEYOK'){
        W "Installation de la cle echouee : $res" Red
        exit 1
    }
    $probe = Invoke-Sshk "echo SSHOK"
    if($probe -notmatch 'SSHOK'){
        W "La cle a ete posee mais l'auth par cle ne passe pas : $probe" Red
        W "Verifie que le NAS autorise PubkeyAuthentication (sshd_config)." Yellow
        exit 1
    }
}
$uname = (Invoke-Sshk "uname -a" | Where-Object { $_ -match 'Linux|GNU' } | Select-Object -First 1)
W "  Connecte sans mot de passe : $uname" Green

# --- 2. Copie du projet (scp) ------------------------------------------------
W "[2/5] Copie du projet sur le NAS..." Yellow
Invoke-Sshk "mkdir -p $remoteDir" | Out-Null
# On copie le strict necessaire au build (pas la musique ni les .git).
$items = @('bin','docker','settings.ini','playlists.txt','README.md')
foreach($it in $items){
    $src = Join-Path $Root $it
    if(Test-Path $src){
        Invoke-Scpk $src "$remoteDir/" | Out-Null
    }
}
W "  Projet copie dans $remoteDir" Green

# --- 3. Verification de Docker -----------------------------------------------
W "[3/5] Verification de Docker..." Yellow
$dockerCheck = Invoke-Sshk "command -v docker >/dev/null 2>&1 && echo HAS_DOCKER || echo NO_DOCKER"
if($dockerCheck -match 'NO_DOCKER'){
    W "  Docker introuvable sur le NAS." Red
    W "  Installe-le d'abord : curl -fsSL https://get.docker.com | sh  puis  sudo usermod -aG docker $NasUser" Gray
    exit 1
}
W "  Docker present." Green

# --- 4. Pull + up (sans sudo : dorvak est dans le groupe docker) -------------
W "[4/5] Pull de l'image et demarrage du conteneur..." Yellow
$remote = @"
cd $remoteDir/docker || exit 1
[ -f .env ] || cp .env.example .env
sed -i 's/^API_PORT=.*/API_PORT=$ApiPort/' .env
__MUSICDIR__
if docker compose pull; then docker compose up -d; else echo 'PULL_KO -> build local'; docker compose up -d --build; fi
"@
$mdLine = if($MusicDir){ "sed -i 's/^MUSIC_DIR=.*/MUSIC_DIR=$($MusicDir.Replace('/','\/'))/' .env" } else { '' }
$remote = $remote.Replace('__MUSICDIR__', $mdLine)
Invoke-Sshk $remote | ForEach-Object { W "    $_" DarkGray }

# --- 5. Recuperation automatique du token (avec retry) -----------------------
W "[5/5] Recuperation du token API..." Yellow
$token = ''
foreach($try in 1..10){
    Start-Sleep -Seconds 2
    # Lu VIA le conteneur (root interne) -> pas de sudo cote hote.
    $raw = Invoke-Sshk "cd $remoteDir/docker && docker compose exec -T downloader cat /state/api_token 2>/dev/null | tr -d '\r\n'"
    $cand = @($raw) | Where-Object { $_ -match '^[0-9a-f]{32,}$' } | Select-Object -First 1
    if($cand){ $token = "$cand".Trim(); break }
    W "  ...conteneur pas encore pret (tentative $try/10)" DarkGray
}
if($token -notmatch '^[0-9a-f]{32,}$'){
    W "  Token non recupere automatiquement." Yellow
    W "  Recupere-le : ssh -i `"$KeyPath`" $SshTarget `"cd $remoteDir/docker && docker compose exec downloader cat /state/api_token`"" Gray
    $token = Read-Host "Colle le token ici (ou laisse vide pour finir plus tard)"
} else {
    W "  Token recupere." Green
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
