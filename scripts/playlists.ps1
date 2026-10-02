<#
.SYNOPSIS
    Gere les playlists suivies par le NAS a distance (via l'API, sans SSH).

.PARAMETER Action   list (defaut) | add | remove
.PARAMETER Url      URL de la playlist/album (pour add/remove)
.PARAMETER Server   URL de l'API (sinon lue dans settings.ini [nas])
.PARAMETER Token    Token Bearer (sinon lu dans settings.ini [nas])

.EXAMPLE
    .\playlists.ps1 list
    .\playlists.ps1 add  https://open.spotify.com/playlist/XXXX
    .\playlists.ps1 remove https://open.spotify.com/playlist/XXXX
#>
[CmdletBinding()]
param(
    [ValidateSet('list','add','remove')]
    [string]$Action = 'list',
    [string]$Url,
    [string]$Server,
    [string]$Token
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function W([string]$t,[string]$c='Gray'){ Write-Host $t -ForegroundColor $c }

$Root = Split-Path -Parent $PSScriptRoot
$Ini  = Join-Path $Root 'settings.ini'
function Get-IniValue([string]$path,[string]$section,[string]$key){
    if(-not (Test-Path $path)){ return $null }
    $cur=''; foreach($line in Get-Content $path -Encoding UTF8){
        $l=$line.Trim()
        if($l -match '^\[(.+)\]$'){ $cur=$Matches[1]; continue }
        if($cur -eq $section -and $l -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$"){ return $Matches[1].Trim() }
    }
    return $null
}
if(-not $Server){ $Server = Get-IniValue $Ini 'nas' 'server' }
if(-not $Token ){ $Token  = Get-IniValue $Ini 'nas' 'token'  }
if(-not $Server -or -not $Token){ W "Config NAS absente (settings.ini [nas]). Lance setup-nas.ps1." Red; exit 1 }
$Server = $Server.TrimEnd('/')
$headers = @{ Authorization = "Bearer $Token" }

switch($Action){
    'list' {
        $r = Invoke-RestMethod -Uri "$Server/playlists" -Headers $headers
        if($r.playlists.Count -eq 0){ W "Aucune playlist suivie." Yellow; break }
        W "Playlists suivies ($($r.playlists.Count)) :" Cyan
        $i=1; foreach($u in $r.playlists){ W ("  {0}. {1}" -f $i,$u) Gray; $i++ }
    }
    'add' {
        if(-not $Url){ $Url = Read-Host "URL de la playlist/album a ajouter" }
        $r = Invoke-RestMethod -Uri "$Server/playlists" -Headers $headers -Method Post `
             -ContentType 'application/json' -Body (@{url=$Url}|ConvertTo-Json)
        if($r.added){ W "Ajoutee. Total : $($r.playlists.Count)." Green }
        else { W "Non ajoutee ($($r.reason))." Yellow }
    }
    'remove' {
        if(-not $Url){ $Url = Read-Host "URL de la playlist/album a retirer" }
        $r = Invoke-RestMethod -Uri "$Server/playlists" -Headers $headers -Method Delete `
             -ContentType 'application/json' -Body (@{url=$Url}|ConvertTo-Json)
        if($r.removed){ W "Retiree. Reste : $($r.playlists.Count)." Green }
        else { W "Introuvable dans la liste." Yellow }
    }
}
