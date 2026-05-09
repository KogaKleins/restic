@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "CONTROL_CENTER_BAT=%PROJECT_DIR%\centro_de_controle.bat"

if not exist "%CONTROL_CENTER_BAT%" (
    echo [ERRO] centro_de_controle.bat nao encontrado em "%CONTROL_CENTER_BAT%".
    pause
    endlocal & exit /b 2
)

call "%CONTROL_CENTER_BAT%"
set "EXIT_CODE=%ERRORLEVEL%"

endlocal & exit /b %EXIT_CODE%
