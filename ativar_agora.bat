@echo off
setlocal EnableExtensions

set "PROJECT_DIR=%~dp0"
if "%PROJECT_DIR:~-1%"=="\" set "PROJECT_DIR=%PROJECT_DIR:~0,-1%"

set "NO_PAUSE="
if /i "%~1"=="--no-pause" set "NO_PAUSE=1"

title Restic - Ativar Agora
echo =========================================================
echo BACKUP MANUAL IMEDIATO
echo Projeto : %PROJECT_DIR%
echo Inicio  : %DATE% %TIME%
echo =========================================================
echo.

call "%PROJECT_DIR%\backup.bat"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
    echo [OK] Backup manual finalizado sem erros.
) else (
    echo [ATENCAO] Backup manual finalizado com codigo %EXIT_CODE%.
)
echo Logs: %PROJECT_DIR%\runtime\logs

if not defined NO_PAUSE pause

endlocal & exit /b %EXIT_CODE%