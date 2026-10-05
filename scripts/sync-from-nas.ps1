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
    [switch]$Mirror,
    [switch]$NoHash,
    [switch]$Yes,
    [int]$Parallel = 0   # 0 = AUTO (concurrence adaptative) ; N>0 = fixe
)
# Si lance sous Windows PowerShell 5.1 (pas de ForEach-Object -Parallel), on se
# relance automatiquement sous pwsh 7 pour profiter du telechargement parallele.
if($PSVersionTable.PSVersion.Major -lt 7){
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if($pwsh){
        $fwd = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
        if($Server){ $fwd += @('-Server',$Server) }
        if($Token ){ $fwd += @('-Token',$Token) }
        if($Dest  ){ $fwd += @('-Dest',$Dest) }
        if($Mirror){ $fwd += '-Mirror' }
        if($NoHash){ $fwd += '-NoHash' }
        if($Yes   ){ $fwd += '-Yes' }
        if($Parallel -gt 0){ $fwd += @('-Parallel',"$Parallel") }
        & $pwsh.Source @fwd
        exit $LASTEXITCODE
    }
    Write-Host "pwsh 7 introuvable : telechargement en mode sequentiel (plus lent). Installe PowerShell 7 pour le parallelisme." -ForegroundColor Yellow
}
# Suppression locale UNIQUEMENT si -Mirror est passe (defaut sur : jamais de
# suppression, pour ne pas effacer le contenu existant d'une cle USB).
$NoDelete = -not $Mirror

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # masque la barre native d'Invoke-WebRequest
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

$modeTxt = if($Mirror){ 'MIROIR (ajout + modif + suppression)' } else { 'ajout + modif (sans suppression)' }
W ""
W "  == Sync NAS -> local =======================================" Cyan
W ("     Serveur : {0}" -f $Server) Gray
W ("     Dest    : {0}" -f $Dest) Gray
W ("     Mode    : {0}" -f $modeTxt) $(if($Mirror){'Yellow'}else{'Gray'})
W "  ============================================================" Cyan
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
    # IMPORTANT : recuperer les octets bruts et decoder en UTF-8 explicitement.
    # Invoke-RestMethod devine mal l'encodage -> les accents/caracteres speciaux
    # (ø, é, ä...) sont corrompus, ce qui casse le matching ET les URL /file (404).
    $resp = Invoke-WebRequest -Uri "$Server/manifest?hash=$hashParam" -Headers $headers -TimeoutSec 120 -UseBasicParsing
    $bytes = $resp.RawContentStream.ToArray()
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    $manifest = $json | ConvertFrom-Json
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
$rp = Resolve-Path -LiteralPath $Dest -ErrorAction SilentlyContinue
$DestFull = if($rp){ $rp.Path } else { [System.IO.Path]::GetFullPath($Dest) }
$DestFull = $DestFull.TrimEnd('\','/')
$audioExt = @('.mp3','.opus','.m4a','.flac','.wav')
$localFiles = Get-ChildItem -Path $DestFull -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -and ($audioExt -contains $_.Extension.ToLower()) }
$local = @{}
foreach($lf in $localFiles){
    $rel = $lf.FullName.Substring($DestFull.Length).TrimStart('\','/').Replace('\','/')
    $local[$rel] = $lf
}

function Get-Sha256([string]$path){
    try {
        $h = Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop
        if($h -and $h.Hash){ return $h.Hash.ToLower() }
    } catch { }
    return $null   # illisible/verrouille -> traite comme "different" (re-telecharge)
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
W ("  Delta : {0} a ajouter   {1} a mettre a jour   {2} a supprimer" -f `
   $toAdd.Count,$toUpdate.Count,$toDelete.Count) White
W ""

if($toAdd.Count -eq 0 -and $toUpdate.Count -eq 0 -and ($NoDelete -or $toDelete.Count -eq 0)){
    W "  Deja a jour -- rien a faire." Green
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

# --- Telechargement (ajout + modif), EN PARALLELE ADAPTATIF ------------------
$work = @($toAdd + $toUpdate)
$n = $work.Count
$cols = try { [Console]::WindowWidth } catch { 100 }

# Pre-cree TOUS les dossiers cible AVANT la boucle parallele : plusieurs
# runspaces creant le meme sous-dossier en meme temps peuvent se bloquer.
$work | ForEach-Object { Split-Path -Parent (Join-Path $DestFull ($_ -replace '/','\')) } |
    Sort-Object -Unique | ForEach-Object {
        if(-not (Test-Path -LiteralPath $_)){ New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

function Format-Duration([double]$s){
    if($s -lt 0){ $s = 0 }
    $ts = [TimeSpan]::FromSeconds([int]$s)
    if($ts.TotalHours -ge 1){ return ("{0}h{1:00}m{2:00}s" -f [int]$ts.TotalHours,$ts.Minutes,$ts.Seconds) }
    if($ts.TotalMinutes -ge 1){ return ("{0}m{1:00}s" -f $ts.Minutes,$ts.Seconds) }
    return ("{0}s" -f $ts.Seconds)
}

# Concurrence : fixe si -Parallel N>0, sinon ADAPTATIF (auto).
$auto  = ($Parallel -le 0)
$MIN_C = 2; $MAX_C = 32
$conc  = if($auto){ 8 } else { [Math]::Max(1,$Parallel) }   # depart raisonnable en auto

# ThreadJob est bien plus fiable que ForEach-Object -Parallel pour un pool de
# telechargements (ce dernier peut "perdre" un runspace et figer la collecte).
$hasThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
if(-not $hasThreadJob){
    try { Import-Module ThreadJob -ErrorAction Stop; $hasThreadJob = $true } catch { $hasThreadJob = $false }
}

$dl = {
    param($rel,$DestFull,$Server,$Token)
    [System.Net.ServicePointManager]::DefaultConnectionLimit = 64
    try {
        $target = Join-Path $DestFull ($rel -replace '/','\')
        $tmp = "$target.part"
        $uri = "$Server/file?path=" + [uri]::EscapeDataString($rel)
        $hc = [System.Net.Http.HttpClient]::new()
        $hc.Timeout = [TimeSpan]::FromSeconds(120)
        $req = [System.Net.Http.HttpRequestMessage]::new('GET', $uri)
        $req.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
        $resp = $hc.Send($req); $resp.EnsureSuccessStatusCode() | Out-Null
        $st = $resp.Content.ReadAsStream(); $fs = [System.IO.File]::Create($tmp)
        $st.CopyTo($fs); $fs.Close(); $st.Dispose(); $resp.Dispose(); $hc.Dispose()
        Move-Item -LiteralPath $tmp -Destination $target -Force
        [pscustomobject]@{ rel=$rel; ok=$true; err=$null }
    } catch { [pscustomobject]@{ rel=$rel; ok=$false; err=$_.Exception.Message } }
}

$done = 0; $errors = @(); $start = Get-Date
$lastBytes = 0.0

if($hasThreadJob){
    $i = 0; $jobs = [System.Collections.Generic.List[object]]::new()
    $lastDraw = (Get-Date).AddSeconds(-1)
    # Fenetre pour l'adaptatif : debit mesure sur ~2s, decision monter/descendre.
    $winStart = Get-Date; $winBytes = 0.0; $prevTp = 0.0
    # Fenetre d'AFFICHAGE : debit "recent" (depuis le dernier redraw ~1s).
    $dispStart = Get-Date; $dispBytes = 0.0; $curTp = 0.0
    while($i -lt $n -or $jobs.Count -gt 0){
        # Remplit le pool jusqu'a $conc.
        while($jobs.Count -lt $conc -and $i -lt $n){
            $rel = $work[$i]; $i++
            $j = Start-ThreadJob -ScriptBlock $dl -ArgumentList $rel,$DestFull,$Server,$Token
            $jobs.Add($j) | Out-Null
        }
        # Collecte NON bloquante des jobs termines.
        $finished = @($jobs | Where-Object { $_.State -in 'Completed','Failed','Stopped' })
        $batchErr = 0
        foreach($j in $finished){
            $r = Receive-Job -Job $j -ErrorAction SilentlyContinue
            Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
            $jobs.Remove($j) | Out-Null
            $done++
            if($r -and -not $r.ok){ $errors += $r; $batchErr++ }
            if($r){ $b = [double]($remote[$r.rel].size); $lastBytes += $b; $winBytes += $b; $dispBytes += $b }
        }

        # Adaptatif : toutes les ~2s, on juge le debit de la fenetre et on ajuste.
        if($auto){
            $winSec = ((Get-Date) - $winStart).TotalSeconds
            if($winSec -ge 2){
                $tp = ($winBytes/1MB) / $winSec
                if($batchErr -gt 0){
                    $conc = [Math]::Max($MIN_C, [int][Math]::Floor($conc/2))     # erreurs -> recule
                } elseif($tp -ge ($prevTp * 1.05)){
                    $conc = [Math]::Min($MAX_C, $conc + 4)                        # debit en hausse -> pousse
                } elseif($tp -lt ($prevTp * 0.9)){
                    $conc = [Math]::Max($MIN_C, $conc - 2)                        # debit en baisse -> recule un peu
                }
                $prevTp = $tp; $winStart = Get-Date; $winBytes = 0.0
            }
        }

        # Redessine AU MOINS chaque seconde (meme si aucun job n'a fini).
        if(((Get-Date) - $lastDraw).TotalMilliseconds -ge 1000 -or $finished.Count -gt 0){
            $elapsed = (Get-Date) - $start
            # Debit RECENT : on ne cloture la fenetre que si elle a dure >=2s ET
            # recu des octets. Sinon on GARDE la derniere valeur (evite les 0,0
            # parasites entre deux rafales de fins de telechargement).
            $dispSec = ((Get-Date) - $dispStart).TotalSeconds
            if($dispSec -ge 2 -and $dispBytes -gt 0){
                $curTp = ($dispBytes/1MB) / $dispSec
                $dispStart = Get-Date; $dispBytes = 0.0
            } elseif($done -eq 0){
                $curTp = 0
            }
            # ETA base sur le debit moyen (plus stable que l'instantane).
            $rate = if($elapsed.TotalSeconds -gt 0){ $done / $elapsed.TotalSeconds } else { 0 }
            $eta = if($rate -gt 0){ ($n - $done) / $rate } else { 0 }
            $pct = if($n -gt 0){ [int](($done/$n)*100) } else { 0 }
            # Barre de progression visuelle.
            $barW = 22
            $fill = [int][Math]::Round($barW * $pct / 100)
            $bar  = ('#' * $fill) + ('-' * ($barW - $fill))
            $cTxt = if($auto){ "x$conc" } else { "x$conc" }
            $line = ("  {0,3}%  [{1}]  {2,4}/{3}   {4,5:N1} Mo/s   {5,-4}  {6} / -{7}" -f `
                     $pct,$bar,$done,$n,$curTp,$cTxt,(Format-Duration $elapsed.TotalSeconds),(Format-Duration $eta))
            if($line.Length -gt ($cols-1)){ $line = $line.Substring(0,$cols-1) }
            Write-Host ("`r" + $line.PadRight($cols-1)) -NoNewline -ForegroundColor Cyan
            $lastDraw = Get-Date
        }
        if($jobs.Count -ge $conc -or ($i -ge $n -and $jobs.Count -gt 0)){
            Start-Sleep -Milliseconds 150   # pool plein ou en vidange : petite pause
        }
    }
} else {
    # Repli sequentiel (ThreadJob indisponible).
    foreach($rel in $work){
        $r = & $dl $rel $DestFull $Server $Token
        $done++
        if($r -and -not $r.ok){ $errors += $r }
        if($r){ $lastBytes += [double]($remote[$r.rel].size) }
        $elapsed = (Get-Date) - $start
        $rate = if($elapsed.TotalSeconds -gt 0){ $done / $elapsed.TotalSeconds } else { 0 }
        $mbps = if($elapsed.TotalSeconds -gt 0){ ($lastBytes/1MB)/$elapsed.TotalSeconds } else { 0 }
        $eta = if($rate -gt 0){ ($n - $done) / $rate } else { 0 }
        $pct = [int](($done/$n)*100)
        $line = "[{0,3}%] {1}/{2}  {3:N1} Mo/s  seq  ecoule {4}  ETA {5}" -f `
                $pct,$done,$n,$mbps,(Format-Duration $elapsed.TotalSeconds),(Format-Duration $eta)
        if($line.Length -gt ($cols-1)){ $line = $line.Substring(0,$cols-1) }
        Write-Host ("`r" + $line.PadRight($cols-1)) -NoNewline -ForegroundColor Cyan
    }
}
if($n -gt 0){ Write-Host "" }
foreach($e in $errors){ W "  ERREUR sur $($e.rel) : $($e.err)" Red }

# --- Suppressions (miroir) ---------------------------------------------------
foreach($rel in $toDelete){
    $target = Join-Path $DestFull ($rel -replace '/','\')
    if(Test-Path -LiteralPath $target){ Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue }
}
# Nettoyage des dossiers vides laisses par les suppressions.
if($toDelete.Count -gt 0){
    Get-ChildItem $DestFull -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue) } |
        ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }
}

W ""
$totalElapsed = (Get-Date) - $start
$okCount = $done - $errors.Count
W "  ============================================================" Green
W ("     Termine en {0} : {1} fichier(s) OK, {2} ajout(s), {3} maj, {4} suppr." -f `
   (Format-Duration $totalElapsed.TotalSeconds),$okCount,$toAdd.Count,$toUpdate.Count,$toDelete.Count) Green
if($errors.Count -gt 0){ W ("     {0} erreur(s) -- voir ci-dessus." -f $errors.Count) Yellow }
W "  ============================================================" Green
