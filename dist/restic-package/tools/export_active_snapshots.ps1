#Requires -Version 5.1
<#
.SYNOPSIS
    Exporta todos os snapshots ativos para outro repositorio Restic.
.DESCRIPTION
    Carrega app/config.ps1 e usa restic copy para copiar todos os snapshots
    atualmente ativos para um repositorio de destino, tipicamente em um HD
    externo. Se o destino nao existir, o script pode inicializa-lo com os mesmos
    parametros de chunk do repositorio de origem para preservar deduplicacao.
#>

[CmdletBinding()]
param(
    [string]$DestinationRepository = '',
    [string]$DestinationPasswordFile = '',
    [switch]$RequireExistingDestination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'app\config.ps1'

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "config.ps1 nao encontrado em: $ConfigPath"
}

. $ConfigPath

if (-not (Test-Path -LiteralPath $RESTIC_EXE)) {
    throw "restic.exe nao encontrado em: $RESTIC_EXE"
}

if (-not (Test-Path -LiteralPath $PASSWORD_FILE)) {
    throw "Arquivo de senha de origem nao encontrado em: $PASSWORD_FILE"
}

$SourceRepository = $REPOSITORY.Trim()
$TargetRepository = if ([string]::IsNullOrWhiteSpace($DestinationRepository)) {
    $EXPORT_REPOSITORY.Trim()
} else {
    $DestinationRepository.Trim()
}

if ([string]::IsNullOrWhiteSpace($TargetRepository)) {
    throw 'Informe um repositorio de destino valido em -DestinationRepository ou configure RESTIC_EXPORT_REPOSITORY.'
}

if ($TargetRepository -eq $SourceRepository) {
    throw 'O repositorio de destino deve ser diferente do repositorio de origem.'
}

$TargetPasswordFile = if ([string]::IsNullOrWhiteSpace($DestinationPasswordFile)) {
    $EXPORT_PASSWORD_FILE
} else {
    $DestinationPasswordFile.Trim()
}

if (-not (Test-Path -LiteralPath $TargetPasswordFile)) {
    throw "Arquivo de senha do destino nao encontrado em: $TargetPasswordFile"
}

function Invoke-ResticCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $Output = & $RESTIC_EXE @Arguments
    $ExitCode = $LASTEXITCODE

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Output   = @($Output)
        Text     = (@($Output) -join [Environment]::NewLine).Trim()
    }
}

function Get-SnapshotsResult {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$PasswordFile
    )

    $Result = Invoke-ResticCommand -Arguments @(
        'snapshots'
        '--json'
        '--repo'
        $Repository
        '--password-file'
        $PasswordFile
        '--no-lock'
    )

    $Snapshots = @()
    if ($Result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($Result.Text)) {
        $Snapshots = @($Result.Text | ConvertFrom-Json)
    }

    return [pscustomobject]@{
        ExitCode  = $Result.ExitCode
        Output    = $Result.Output
        Text      = $Result.Text
        Snapshots = $Snapshots
    }
}

$SourceSnapshotsResult = Get-SnapshotsResult -Repository $SourceRepository -PasswordFile $PASSWORD_FILE
if ($SourceSnapshotsResult.ExitCode -ne 0) {
    throw "Falha ao listar snapshots da origem. ExitCode: $($SourceSnapshotsResult.ExitCode)"
}

$SnapshotCount = @($SourceSnapshotsResult.Snapshots).Count
if ($SnapshotCount -eq 0) {
    Write-Host '[INFO] Nenhum snapshot ativo encontrado no repositorio de origem.' -ForegroundColor Yellow
    exit 0
}

$TargetSnapshotsResult = Get-SnapshotsResult -Repository $TargetRepository -PasswordFile $TargetPasswordFile
if ($TargetSnapshotsResult.ExitCode -eq 10) {
    if ($RequireExistingDestination) {
        throw 'O repositorio de destino nao existe e a inicializacao automatica foi desabilitada.'
    }

    Write-Host "[INFO] Repositorio de destino ainda nao existe. Inicializando em: $TargetRepository" -ForegroundColor Cyan
    $InitResult = Invoke-ResticCommand -Arguments @(
        'init'
        '--repo'
        $TargetRepository
        '--password-file'
        $TargetPasswordFile
        '--from-repo'
        $SourceRepository
        '--from-password-file'
        $PASSWORD_FILE
        '--copy-chunker-params'
    )

    if ($InitResult.ExitCode -ne 0) {
        throw "Falha ao inicializar repositorio de destino. ExitCode: $($InitResult.ExitCode)"
    }
} elseif ($TargetSnapshotsResult.ExitCode -ne 0) {
    throw "Falha ao acessar repositorio de destino. ExitCode: $($TargetSnapshotsResult.ExitCode)"
}

Write-Host "[INFO] Origem: $SourceRepository" -ForegroundColor Cyan
Write-Host "[INFO] Destino: $TargetRepository" -ForegroundColor Cyan
Write-Host "[INFO] Arquivo de senha do destino: $TargetPasswordFile" -ForegroundColor Cyan
Write-Host "[INFO] Snapshots ativos na origem: $SnapshotCount" -ForegroundColor Cyan
Write-Host '[INFO] O arquivo de senha nao e copiado automaticamente para o destino.' -ForegroundColor Yellow
Write-Host '[INFO] Executando: restic copy --repo <destino> --from-repo <origem>' -ForegroundColor Cyan

& $RESTIC_EXE @(
    'copy'
    '--repo'
    $TargetRepository
    '--password-file'
    $TargetPasswordFile
    '--from-repo'
    $SourceRepository
    '--from-password-file'
    $PASSWORD_FILE
)
$CopyExitCode = $LASTEXITCODE

if ($CopyExitCode -ne 0) {
    Write-Error "Falha ao exportar snapshots ativos. ExitCode: $CopyExitCode"
    exit $CopyExitCode
}

$TargetSnapshotsAfterCopy = Get-SnapshotsResult -Repository $TargetRepository -PasswordFile $TargetPasswordFile
if ($TargetSnapshotsAfterCopy.ExitCode -eq 0) {
    Write-Host ("[OK] Exportacao concluida. Destino agora possui {0} snapshot(s)." -f (@($TargetSnapshotsAfterCopy.Snapshots).Count)) -ForegroundColor Green
    exit 0
}

Write-Host '[OK] Exportacao concluida.' -ForegroundColor Green
exit 0