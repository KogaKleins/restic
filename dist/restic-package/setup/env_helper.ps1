#Requires -Version 5.1
<#
.SYNOPSIS
    Ajudante para visualizar e atualizar variaveis RESTIC_* sem hardcode.
.DESCRIPTION
    Le configuracao efetiva atual e grava novamente via setup_env.ps1.
    Pode rodar de forma interativa (perguntas) ou por parametros.
#>

[CmdletBinding()]
param(
    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [string]$ResticExe,
    [string]$Repository,
    [string]$SecretFilePath,
    [string]$LogDir,
    [int]$LogKeepDays = -1,

    [string]$ExportRepository,
    [string]$ExportPasswordFile,

    [string]$TelegramToken,
    [string]$TelegramChatId,

    [int]$KeepLast = -1,
    [int]$KeepWeekly = -1,
    [int]$KeepMonthly = -1,

    [string[]]$BackupSources,
    [string[]]$BackupExcludes,

    [switch]$Interactive,
    [switch]$ShowOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SetupScript = Join-Path $PSScriptRoot 'setup_env.ps1'
$ShowScript = Join-Path $PSScriptRoot 'show_env.ps1'

if (-not (Test-Path -LiteralPath $SetupScript)) {
    throw "setup_env.ps1 nao encontrado em: $SetupScript"
}

if ($ShowOnly) {
    & $ShowScript
    exit 0
}

function Get-EffectiveValue {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($CurrentScope in @('Process', 'User', 'Machine')) {
        $Value = [Environment]::GetEnvironmentVariable($Name, $CurrentScope)
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return $Value.Trim()
        }
    }

    return ''
}

function Get-IntOrDefault {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Fallback
    )

    $Raw = Get-EffectiveValue -Name $Name
    $Parsed = 0
    if ([int]::TryParse($Raw, [ref]$Parsed)) {
        return $Parsed
    }

    return $Fallback
}

function Read-Text {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Current = ''
    )

    $Suffix = if ([string]::IsNullOrWhiteSpace($Current)) { '' } else { " [$Current]" }
    $Raw = Read-Host ($Prompt + $Suffix)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $Current
    }

    return $Raw.Trim()
}

function Read-Number {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Current,
        [int]$MinValue = 0
    )

    while ($true) {
        $Raw = Read-Host ("{0} [{1}]" -f $Prompt, $Current)
        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $Current
        }

        $Parsed = 0
        if ([int]::TryParse($Raw, [ref]$Parsed) -and $Parsed -ge $MinValue) {
            return $Parsed
        }

        Write-Warning "Informe um inteiro >= $MinValue."
    }
}

function Read-List {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string[]]$Current
    )

    $CurrentJoined = if ($Current.Count -gt 0) { $Current -join ';' } else { '' }
    $Raw = Read-Host ("{0} [{1}]" -f $Prompt, $CurrentJoined)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $Current
    }

    return @(
        $Raw -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

$CurrentResticExe = if ($ResticExe) { $ResticExe } else { Get-EffectiveValue -Name 'RESTIC_EXE' }
$CurrentRepository = if ($Repository) { $Repository } else { Get-EffectiveValue -Name 'RESTIC_REPOSITORY' }
$CurrentSecretFilePath = if ($SecretFilePath) { $SecretFilePath } else { Get-EffectiveValue -Name 'RESTIC_PASSWORD_FILE' }
$CurrentLogDir = if ($LogDir) { $LogDir } else { Get-EffectiveValue -Name 'RESTIC_LOG_DIR' }
if ([string]::IsNullOrWhiteSpace($CurrentLogDir)) {
    $CurrentLogDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\logs'
}
$CurrentExportRepository = if ($PSBoundParameters.ContainsKey('ExportRepository')) { $ExportRepository } else { Get-EffectiveValue -Name 'RESTIC_EXPORT_REPOSITORY' }
$CurrentExportPasswordFile = if ($PSBoundParameters.ContainsKey('ExportPasswordFile')) { $ExportPasswordFile } else { Get-EffectiveValue -Name 'RESTIC_EXPORT_PASSWORD_FILE' }

$CurrentLogKeepDays = if ($LogKeepDays -ge 0) { $LogKeepDays } else { Get-IntOrDefault -Name 'RESTIC_LOG_KEEP_DAYS' -Fallback 30 }
$CurrentTelegramToken = if ($PSBoundParameters.ContainsKey('TelegramToken')) { $TelegramToken } else { Get-EffectiveValue -Name 'RESTIC_TELEGRAM_TOKEN' }
$CurrentTelegramChatId = if ($PSBoundParameters.ContainsKey('TelegramChatId')) { $TelegramChatId } else { Get-EffectiveValue -Name 'RESTIC_TELEGRAM_CHATID' }
$CurrentKeepLast = if ($KeepLast -ge 0) { $KeepLast } else { Get-IntOrDefault -Name 'RESTIC_KEEP_LAST' -Fallback 7 }
$CurrentKeepWeekly = if ($KeepWeekly -ge 0) { $KeepWeekly } else { Get-IntOrDefault -Name 'RESTIC_KEEP_WEEKLY' -Fallback 4 }
$CurrentKeepMonthly = if ($KeepMonthly -ge 0) { $KeepMonthly } else { Get-IntOrDefault -Name 'RESTIC_KEEP_MONTHLY' -Fallback 3 }

$CurrentBackupSources = if ($PSBoundParameters.ContainsKey('BackupSources')) {
    @($BackupSources)
} else {
    @((Get-EffectiveValue -Name 'RESTIC_BACKUP_SOURCES') -split ';' | Where-Object { $_ })
}
if ($CurrentBackupSources.Count -eq 0) {
    $CurrentBackupSources = @((Join-Path $env:SystemDrive 'Users'))
}

$CurrentBackupExcludes = if ($PSBoundParameters.ContainsKey('BackupExcludes')) {
    @($BackupExcludes)
} else {
    @((Get-EffectiveValue -Name 'RESTIC_BACKUP_EXCLUDES') -split ';' | Where-Object { $_ })
}

$HasDirectUpdateParams = $PSBoundParameters.Keys | Where-Object {
    $_ -in @(
        'ResticExe', 'Repository', 'SecretFilePath', 'LogDir', 'LogKeepDays',
        'ExportRepository', 'ExportPasswordFile',
        'TelegramToken', 'TelegramChatId', 'KeepLast', 'KeepWeekly', 'KeepMonthly',
        'BackupSources', 'BackupExcludes'
    )
}

$InteractiveMode = $Interactive -or ($HasDirectUpdateParams.Count -eq 0)

if ($InteractiveMode) {
    Write-Host ''
    Write-Host '=== Ajudante de configuracao RESTIC_* ===' -ForegroundColor Cyan
    Write-Host 'Enter para manter valor atual.' -ForegroundColor DarkCyan

    $CurrentResticExe = Read-Text -Prompt 'RESTIC_EXE (caminho do restic.exe)' -Current $CurrentResticExe
    $CurrentRepository = Read-Text -Prompt 'RESTIC_REPOSITORY (caminho do repositorio)' -Current $CurrentRepository
    $CurrentSecretFilePath = Read-Text -Prompt 'RESTIC_PASSWORD_FILE (caminho do arquivo de senha)' -Current $CurrentSecretFilePath
    $CurrentLogDir = Read-Text -Prompt 'RESTIC_LOG_DIR (pasta de logs)' -Current $CurrentLogDir
    $CurrentExportRepository = Read-Text -Prompt 'RESTIC_EXPORT_REPOSITORY (repo externo opcional)' -Current $CurrentExportRepository
    $CurrentExportPasswordFile = Read-Text -Prompt 'RESTIC_EXPORT_PASSWORD_FILE (senha do repo externo opcional)' -Current $CurrentExportPasswordFile
    $CurrentLogKeepDays = Read-Number -Prompt 'RESTIC_LOG_KEEP_DAYS' -Current $CurrentLogKeepDays -MinValue 1

    $CurrentTelegramToken = Read-Text -Prompt 'RESTIC_TELEGRAM_TOKEN (vazio desativa envio)' -Current $CurrentTelegramToken
    $CurrentTelegramChatId = Read-Text -Prompt 'RESTIC_TELEGRAM_CHATID (chat destino)' -Current $CurrentTelegramChatId

    $CurrentKeepLast = Read-Number -Prompt 'RESTIC_KEEP_LAST' -Current $CurrentKeepLast -MinValue 1
    $CurrentKeepWeekly = Read-Number -Prompt 'RESTIC_KEEP_WEEKLY' -Current $CurrentKeepWeekly -MinValue 0
    $CurrentKeepMonthly = Read-Number -Prompt 'RESTIC_KEEP_MONTHLY' -Current $CurrentKeepMonthly -MinValue 0

    $CurrentBackupSources = Read-List -Prompt 'RESTIC_BACKUP_SOURCES (separado por ;)' -Current $CurrentBackupSources
    $CurrentBackupExcludes = Read-List -Prompt 'RESTIC_BACKUP_EXCLUDES (separado por ;)' -Current $CurrentBackupExcludes
}

foreach ($Required in @(
    @{ Name = 'RESTIC_EXE'; Value = $CurrentResticExe },
    @{ Name = 'RESTIC_REPOSITORY'; Value = $CurrentRepository },
    @{ Name = 'RESTIC_PASSWORD_FILE'; Value = $CurrentSecretFilePath }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$Required.Value)) {
        throw "Valor obrigatorio ausente: $($Required.Name)"
    }
}

$SetupArgs = @{
    Scope          = $Scope
    ResticExe      = $CurrentResticExe
    Repository     = $CurrentRepository
    SecretFilePath = $CurrentSecretFilePath
    LogDir         = $CurrentLogDir
    LogKeepDays    = $CurrentLogKeepDays
    ExportRepository = $CurrentExportRepository
    ExportPasswordFile = $CurrentExportPasswordFile
    TelegramToken  = $CurrentTelegramToken
    TelegramChatId = $CurrentTelegramChatId
    KeepLast       = $CurrentKeepLast
    KeepWeekly     = $CurrentKeepWeekly
    KeepMonthly    = $CurrentKeepMonthly
    BackupSources  = $CurrentBackupSources
    BackupExcludes = $CurrentBackupExcludes
}

& $SetupScript @SetupArgs
Write-Host ''
Write-Host 'Configuracao atualizada. Estado efetivo:' -ForegroundColor Cyan
& $ShowScript
