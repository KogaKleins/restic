#Requires -Version 5.1
<#
.SYNOPSIS
    Prepara e sincroniza um repositório Restic em disco externo.
.DESCRIPTION
    Cria a estrutura padrao em X:\restic_backup, ou em uma pasta relativa
    escolhida pelo operador, atualiza o kit de recuperacao, executa a
    exportacao dos snapshots ativos para o repositório externo e pode
    restaurar todo o snapshot mais recente para a area de staging.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Initial', 'Weekly', 'RestoreAll')][string]$Mode,
    [Parameter(Mandatory)][string]$DriveLetter,
    [string]$ExternalFolderPath = 'restic_backup',
    [string]$DestinationPasswordFile = '',
    [switch]$RefreshRecoveryKit,
    [string]$SnapshotId = 'latest',
    [string]$RestoreTargetFolderName = '',
    [switch]$VerifyRestore,
    [switch]$CleanRestoreTarget
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $ProjectRoot 'app\config.ps1'
$PrepareDistributionScript = Join-Path $ProjectRoot 'setup\prepare_distribution.ps1'
$ExportSnapshotsScript = Join-Path $ProjectRoot 'tools\export_active_snapshots.ps1'

foreach ($Required in @($ConfigPath, $PrepareDistributionScript, $ExportSnapshotsScript)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Arquivo obrigatorio nao encontrado: $Required"
    }
}

. $ConfigPath

if (-not (Test-Path -LiteralPath $RESTIC_EXE)) {
    throw "restic.exe nao encontrado em: $RESTIC_EXE"
}

function Get-NormalizedDriveLetter {
    param([Parameter(Mandatory)][string]$InputDriveLetter)

    $Normalized = $InputDriveLetter.Trim().TrimEnd(':', '\').ToUpperInvariant()
    if ($Normalized -notmatch '^[A-Z]$') {
        throw "Letra de unidade invalida: $InputDriveLetter"
    }

    return $Normalized
}

function Get-NormalizedExternalFolderPath {
    param([Parameter(Mandatory)][string]$InputPath)

    $Normalized = $InputPath.Trim().TrimStart('\').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($Normalized)) {
        throw 'Informe um nome de pasta valido para o disco externo.'
    }
    if ($Normalized -match '^[A-Za-z]:') {
        throw 'A pasta do disco externo deve ser relativa a unidade escolhida, sem letra de drive.'
    }

    return $Normalized
}

function Invoke-ExternalCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    & powershell.exe @Arguments
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "Comando externo retornou codigo $ExitCode"
    }
}

function Test-DirectoryHasItems {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    return $null -ne (Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop | Select-Object -First 1)
}

function Write-RestoreStatusFile {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][bool]$Verified,
        [string]$RepositoryPath = '',
        [int]$ExitCode = 0,
        [string]$Details = ''
    )

    $Lines = @(
        ('status={0}' -f $Status)
        ('timestamp={0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('snapshot={0}' -f $SnapshotId)
        ('verified={0}' -f $Verified)
        ('repository={0}' -f $RepositoryPath)
        ('target={0}' -f $TargetPath)
        ('exit_code={0}' -f $ExitCode)
    )

    if (-not [string]::IsNullOrWhiteSpace($Details)) {
        $Lines += ('details={0}' -f $Details)
    }

    Set-Content -LiteralPath (Join-Path $TargetPath '_restore_status.txt') -Value $Lines -Encoding UTF8
}

$NormalizedDriveLetter = Get-NormalizedDriveLetter -InputDriveLetter $DriveLetter
$NormalizedExternalFolderPath = Get-NormalizedExternalFolderPath -InputPath $ExternalFolderPath
$DriveRoot = '{0}:\' -f $NormalizedDriveLetter
$Volume = Get-Volume -DriveLetter $NormalizedDriveLetter -ErrorAction SilentlyContinue
if ($null -eq $Volume) {
    throw "Unidade nao encontrada ou sem volume montado: $DriveRoot"
}

$ExternalRoot = Join-Path $DriveRoot $NormalizedExternalFolderPath
$RepositoryPath = Join-Path $ExternalRoot 'repo'
$RecoveryKitPath = Join-Path $ExternalRoot 'kit'
$RestoreStagingPath = Join-Path $ExternalRoot 'restore-staging'
$EffectiveDestinationPasswordFile = if ([string]::IsNullOrWhiteSpace($DestinationPasswordFile)) {
    if (-not [string]::IsNullOrWhiteSpace($EXPORT_PASSWORD_FILE)) {
        $EXPORT_PASSWORD_FILE
    } else {
        $PASSWORD_FILE
    }
} else {
    $DestinationPasswordFile.Trim()
}

if (-not (Test-Path -LiteralPath $EffectiveDestinationPasswordFile)) {
    throw "Arquivo de senha do destino nao encontrado em: $EffectiveDestinationPasswordFile"
}

Write-Host "[INFO] Modo: $Mode" -ForegroundColor Cyan
Write-Host "[INFO] Unidade: $DriveRoot" -ForegroundColor Cyan
Write-Host "[INFO] Estrutura alvo: $ExternalRoot" -ForegroundColor Cyan
Write-Host "[INFO] Repositorio externo: $RepositoryPath" -ForegroundColor Cyan
Write-Host "[INFO] Kit de recuperacao: $RecoveryKitPath" -ForegroundColor Cyan
Write-Host "[INFO] Restore staging: $RestoreStagingPath" -ForegroundColor Cyan

if (($Mode -eq 'Weekly' -or $Mode -eq 'RestoreAll') -and -not (Test-Path -LiteralPath $RepositoryPath)) {
    throw 'Esse disco ainda nao recebeu a transferencia inicial. Rode primeiro a opcao de transferencia completa.'
}

foreach ($PathToCreate in @($ExternalRoot, $RestoreStagingPath)) {
    if (-not (Test-Path -LiteralPath $PathToCreate) -and $PSCmdlet.ShouldProcess($PathToCreate, 'Criar pasta no disco externo')) {
        New-Item -ItemType Directory -Path $PathToCreate -Force | Out-Null
    }
}

$ShouldRefreshRecoveryKit = $RefreshRecoveryKit -or $Mode -eq 'Initial'
if ($ShouldRefreshRecoveryKit -and $PSCmdlet.ShouldProcess($RecoveryKitPath, 'Atualizar kit de recuperacao no disco externo')) {
    $PrepareArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $PrepareDistributionScript
        '-OutputDir'
        $RecoveryKitPath
        '-Force'
    )

    if ($WhatIfPreference) {
        $PrepareArgs += '-WhatIf'
    }

    Invoke-ExternalCommand -Arguments $PrepareArgs
}

if ($Mode -in @('Initial', 'Weekly')) {
    $ExportArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $ExportSnapshotsScript
        '-DestinationRepository'
        $RepositoryPath
        '-DestinationPasswordFile'
        $EffectiveDestinationPasswordFile
    )

    if ($Mode -eq 'Weekly') {
        $ExportArgs += '-RequireExistingDestination'
    }

    if ($PSCmdlet.ShouldProcess($RepositoryPath, 'Sincronizar snapshots ativos para o disco externo')) {
        Invoke-ExternalCommand -Arguments $ExportArgs
    }
}

if ($Mode -eq 'RestoreAll') {
    if ([string]::IsNullOrWhiteSpace($RestoreTargetFolderName)) {
        $RestoreTargetFolderName = 'restore_{0}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')
    }

    $RestoreTargetPath = Join-Path $RestoreStagingPath $RestoreTargetFolderName
    if (-not (Test-Path -LiteralPath $RestoreTargetPath) -and $PSCmdlet.ShouldProcess($RestoreTargetPath, 'Criar pasta de restore no disco externo')) {
        New-Item -ItemType Directory -Path $RestoreTargetPath -Force | Out-Null
    }

    if (Test-DirectoryHasItems -Path $RestoreTargetPath) {
        if ($CleanRestoreTarget) {
            if ($PSCmdlet.ShouldProcess($RestoreTargetPath, 'Limpar conteudo anterior do restore')) {
                Get-ChildItem -LiteralPath $RestoreTargetPath -Force -ErrorAction Stop | Remove-Item -Recurse -Force
            }
        } else {
            throw 'A pasta de restore ja contem arquivos. Use outro nome de pasta ou habilite a limpeza da pasta existente antes de restaurar novamente.'
        }
    }

    $RestoreArgs = @(
        'restore'
        $SnapshotId
        '--repo'
        $RepositoryPath
        '--password-file'
        $EffectiveDestinationPasswordFile
        '--target'
        $RestoreTargetPath
    )

    if ($VerifyRestore) {
        $RestoreArgs += '--verify'
    }

    if ($PSCmdlet.ShouldProcess($RestoreTargetPath, 'Desempacotar snapshot completo no disco externo')) {
        Write-RestoreStatusFile -TargetPath $RestoreTargetPath -Status 'running' -SnapshotId $SnapshotId -Verified:$VerifyRestore -RepositoryPath $RepositoryPath -Details 'Restore em andamento.'
        & $RESTIC_EXE @RestoreArgs
        $RestoreExitCode = $LASTEXITCODE
        if ($RestoreExitCode -ne 0) {
            Write-RestoreStatusFile -TargetPath $RestoreTargetPath -Status 'incomplete' -SnapshotId $SnapshotId -Verified:$VerifyRestore -RepositoryPath $RepositoryPath -ExitCode $RestoreExitCode -Details 'Restore interrompido ou finalizado com erro. O conteudo parcial foi preservado para avaliacao manual.'
            throw "Falha ao restaurar snapshot completo. ExitCode: $RestoreExitCode"
        }

        Write-RestoreStatusFile -TargetPath $RestoreTargetPath -Status 'completed' -SnapshotId $SnapshotId -Verified:$VerifyRestore -RepositoryPath $RepositoryPath -Details 'Restore concluido com sucesso.'
    }
}

Write-Host '[OK] Fluxo de disco externo concluido.' -ForegroundColor Green
exit 0