@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "PS_SCRIPT=%PROJECT_DIR%\setup\control_center.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERRO] control_center.ps1 nao encontrado em "%PS_SCRIPT%".
    pause
    endlocal & exit /b 2
)

pushd "%PROJECT_DIR%" >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"
popd >nul 2>&1

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Centro de Controle finalizado com codigo %EXIT_CODE%.
    pause
)

endlocal & exit /b %EXIT_CODE%