#Requires -Version 5.1
<#
.SYNOPSIS
    Restaura snapshot do Restic usando configuracao central do projeto.
.DESCRIPTION
    Carrega app/config.ps1, aplica RESTIC_REPOSITORY e RESTIC_PASSWORD_FILE
    no ambiente e executa restic restore.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SnapshotId,
    [Parameter(Mandatory)][string]$TargetPath,
    [string[]]$Include = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'app\config.ps1'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "config.ps1 nao encontrado em: $ConfigPath"
}

. $ConfigPath

$env:RESTIC_REPOSITORY = $REPOSITORY
$env:RESTIC_PASSWORD_FILE = $PASSWORD_FILE

if (-not (Test-Path -LiteralPath $RESTIC_EXE)) {
    throw "restic.exe nao encontrado em: $RESTIC_EXE"
}

if (-not (Test-Path -LiteralPath $PASSWORD_FILE)) {
    throw "Arquivo de senha nao encontrado em: $PASSWORD_FILE"
}

if (-not (Test-Path -LiteralPath $TargetPath)) {
    New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null
}

$RestoreArgs = @(
    'restore'
    $SnapshotId
    '--target'
    $TargetPath
)

foreach ($Item in $Include) {
    if (-not [string]::IsNullOrWhiteSpace($Item)) {
        $RestoreArgs += '--include'
        $RestoreArgs += $Item
    }
}

Write-Host "[INFO] Repositorio: $REPOSITORY" -ForegroundColor Cyan
Write-Host "[INFO] Password file: $PASSWORD_FILE" -ForegroundColor Cyan
Write-Host "[INFO] Executando: restic $($RestoreArgs -join ' ')" -ForegroundColor Cyan

& $RESTIC_EXE @RestoreArgs
$ExitCode = $LASTEXITCODE

if ($ExitCode -eq 0) {
    Write-Host "[OK] Restore concluido." -ForegroundColor Green
    exit 0
}

Write-Error "Falha no restore. ExitCode: $ExitCode"
exit $ExitCode
