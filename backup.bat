@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "PS_SCRIPT=%PROJECT_DIR%\app\backup.ps1"
set "LOG_DIR=%PROJECT_DIR%\runtime\logs"
set "LAUNCHER_LOG=%LOG_DIR%\backup-launcher.log"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

(
    echo =========================================================
    echo BACKUP LAUNCH %DATE% %TIME%
    echo ProjectDir: %PROJECT_DIR%
    echo Target    : %PS_SCRIPT%
    echo Usuario   : %USERNAME%
    echo Host      : %COMPUTERNAME%
    echo =========================================================
) > "%LAUNCHER_LOG%"

if not exist "%PS_SCRIPT%" (
    echo [ERRO] backup.ps1 nao encontrado. >> "%LAUNCHER_LOG%"
    echo [ERRO] Execucao abortada antes de iniciar o PowerShell. >> "%LAUNCHER_LOG%"
    endlocal & exit /b 2
)

pushd "%PROJECT_DIR%" >nul 2>&1
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"
popd >nul 2>&1

>> "%LAUNCHER_LOG%" echo [INFO] Codigo de saida do PowerShell: %EXIT_CODE%

endlocal & exit /b %EXIT_CODE%