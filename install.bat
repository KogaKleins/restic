@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PS_SCRIPT=%SCRIPT_DIR%\setup\install.ps1"
set "LOG_DIR=%SCRIPT_DIR%\runtime\logs"
set "LAUNCHER_LOG=%LOG_DIR%\install-launcher.log"
set "PAUSE_ON_EXIT="
set "SAFE_ARGS=(nenhum)"

if "%~1"=="" set "PAUSE_ON_EXIT=1"
if not "%~1"=="" set "SAFE_ARGS=[ocultados por seguranca]"

if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

(
    echo =========================================================
    echo INSTALL LAUNCH %DATE% %TIME%
    echo ScriptDir : %SCRIPT_DIR%
    echo Target    : %PS_SCRIPT%
    echo Usuario   : %USERNAME%
    echo Host      : %COMPUTERNAME%
    echo Args      : %SAFE_ARGS%
    echo =========================================================
) > "%LAUNCHER_LOG%"

if not exist "%PS_SCRIPT%" (
    echo [ERRO] install.ps1 nao encontrado. >> "%LAUNCHER_LOG%"
    echo [ERRO] Execucao abortada antes de iniciar o PowerShell. >> "%LAUNCHER_LOG%"
    if defined PAUSE_ON_EXIT (
        echo.
        echo install.ps1 nao foi encontrado em "%PS_SCRIPT%".
        pause
    )
    endlocal & exit /b 2
)

pushd "%SCRIPT_DIR%" >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"
popd >nul 2>&1

>> "%LAUNCHER_LOG%" echo [INFO] Codigo de saida do PowerShell: %EXIT_CODE%

if defined PAUSE_ON_EXIT (
    echo.
    if "%EXIT_CODE%"=="0" (
        echo Instalacao finalizada.
    ) else (
        echo Instalacao falhou com codigo %EXIT_CODE%.
    )
    echo Pressione qualquer tecla para fechar.
    pause >nul
)

endlocal & exit /b %EXIT_CODE%