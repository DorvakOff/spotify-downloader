@echo off
chcp 65001 >nul
cd /d "%~dp0"

where pwsh >nul 2>&1
if errorlevel 1 (
    echo [ERREUR] PowerShell 7 ^(pwsh^) est introuvable.
    echo Installe-le : winget install Microsoft.PowerShell
    echo ou : https://aka.ms/powershell
    echo.
    pause
    exit /b 1
)

REM start "" /wait : pwsh gere lui-meme Ctrl+C / Echap ; le batch rend la main
REM aussitot pwsh termine, sans afficher le prompt "Terminer (O/N) ?".
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin\download.ps1"
exit /b %errorlevel%
