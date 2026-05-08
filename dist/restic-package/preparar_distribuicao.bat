@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "PS_SCRIPT=%PROJECT_DIR%\setup\prepare_distribution.ps1"
set "DEFAULT_OUTPUT=%PROJECT_DIR%\dist\restic-package"
set "PAUSE_ON_EXIT="

if "%~1"=="" set "PAUSE_ON_EXIT=1"

if not exist "%PS_SCRIPT%" (
    echo [ERRO] prepare_distribution.ps1 nao encontrado em "%PS_SCRIPT%".
    if defined PAUSE_ON_EXIT pause
    endlocal & exit /b 2
)

pushd "%PROJECT_DIR%" >nul 2>&1
if "%~1"=="" (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -OutputDir "%DEFAULT_OUTPUT%" -Force
) else (
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*
)
set "EXIT_CODE=%ERRORLEVEL%"
popd >nul 2>&1

if defined PAUSE_ON_EXIT (
    echo.
    if "%EXIT_CODE%"=="0" (
        echo Exportacao concluida.
    ) else (
        echo Exportacao falhou com codigo %EXIT_CODE%.
    )
    pause
)

endlocal & exit /b %EXIT_CODE%