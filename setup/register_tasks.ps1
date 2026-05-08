#Requires -Version 5.1
<#
.SYNOPSIS
    Cadastra automaticamente as tarefas de backup, check e sincronizacao externa no Task Scheduler.
.DESCRIPTION
    Registra tarefas apontando para os launchers publicos backup.bat, check.bat e sincronizar_externo.bat na raiz do projeto.
    Pode rodar com usuario atual, usuario/senha ou SYSTEM.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDir = (Split-Path -Parent $PSScriptRoot),
    [Parameter(Mandatory)][ValidatePattern('^\d{1,2}:\d{2}$')][string]$BackupTime,
    [uint32]$BackupDaysInterval = 1,

    [switch]$CreateCheckTask,
    [ValidateSet('partial', 'full')][string]$CheckMode = 'partial',
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')][string]$CheckDay = 'Sunday',
    [ValidatePattern('^\d{1,2}:\d{2}$')][string]$CheckTime = '03:30',
    [uint32]$CheckWeeksInterval = 1,

    [switch]$CreateExportTask,
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')][string]$ExportDay = 'Sunday',
    [ValidatePattern('^\d{1,2}:\d{2}$')][string]$ExportTime = '05:00',
    [uint32]$ExportWeeksInterval = 1,

    [ValidateSet('CurrentUser', 'Password', 'System')][string]$RunAs = 'CurrentUser',
    [string]$UserName = '',
    [securestring]$TaskPassword,
    [switch]$HighestPrivileges,

    [string]$TaskPath = '\ResticBackup\',
    [string]$BackupTaskName = 'Restic Backup Daily',
    [string]$CheckTaskName = 'Restic Check Weekly',
    [string]$ExportTaskName = 'Restic External Sync Weekly'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CurrentWindowsIdentityName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    } catch {
        if ($env:USERNAME) {
            if ($env:USERDOMAIN) {
                return "$env:USERDOMAIN\$env:USERNAME"
            }

            return $env:USERNAME
        }

        throw 'Nao foi possivel identificar o usuario atual.'
    }
}

function Get-NormalizedTaskPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return '\'
    }

    $Normalized = $Path.Replace('/', '\')
    if (-not $Normalized.StartsWith('\')) {
        $Normalized = "\$Normalized"
    }
    if (-not $Normalized.EndsWith('\')) {
        $Normalized = "$Normalized\"
    }

    return $Normalized
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory)][securestring]$SecureValue)

    $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
    }
}

function Convert-TimeStringToDateTime {
    param([Parameter(Mandatory)][string]$Time)

    foreach ($Format in @('H:mm', 'HH:mm')) {
        try {
            $Parsed = [datetime]::ParseExact($Time, $Format, [System.Globalization.CultureInfo]::InvariantCulture)
            return (Get-Date).Date.AddHours($Parsed.Hour).AddMinutes($Parsed.Minute)
        } catch {
        }
    }

    throw "Horario invalido: $Time. Use HH:mm."
}

function Test-IsProcessElevated {
    try {
        $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = [System.Security.Principal.WindowsPrincipal]::new($Identity)
        return $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Assert-CanRegisterTasks {
    param(
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'Password', 'System')][string]$RunAs,
        [Parameter(Mandatory)][bool]$HighestPrivileges
    )

    if (($RunAs -eq 'System' -or $HighestPrivileges) -and -not (Test-IsProcessElevated)) {
        throw 'Este agendamento exige uma sessao elevada porque foi solicitado SYSTEM ou RunLevel Highest. Abra o PowerShell como administrador, ou grave a tarefa sem Highest para manter a administracao sem elevacao.'
    }
}

function Register-TaskInternal {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Trigger,
        [Parameter(Mandatory)]$Settings,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'Password', 'System')][string]$RunAs,
        [string]$UserName,
        [securestring]$TaskPassword,
        [Parameter(Mandatory)][ValidateSet('Highest', 'Limited')][string]$RunLevel
    )

    switch ($RunAs) {
        'CurrentUser' {
            $Principal = New-ScheduledTaskPrincipal -UserId (Get-CurrentWindowsIdentityName) -LogonType Interactive -RunLevel $RunLevel
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Settings $Settings -Description $Description -Principal $Principal -Force | Out-Null
        }

        'System' {
            $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel 'Highest'
            Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Settings $Settings -Description $Description -Principal $Principal -Force | Out-Null
        }

        'Password' {
            if ([string]::IsNullOrWhiteSpace($UserName)) {
                throw 'UserName e obrigatorio quando RunAs=Password.'
            }

            if ($null -eq $TaskPassword) {
                throw 'TaskPassword e obrigatorio quando RunAs=Password.'
            }

            $PlainTaskPassword = Convert-SecureStringToPlainText -SecureValue $TaskPassword
            if ([string]::IsNullOrWhiteSpace($PlainTaskPassword)) {
                throw 'TaskPassword e obrigatorio quando RunAs=Password.'
            }

            try {
                Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action -Trigger $Trigger -Settings $Settings -Description $Description -User $UserName -Password $PlainTaskPassword -RunLevel $RunLevel -Force | Out-Null
            } finally {
                $PlainTaskPassword = $null
            }
        }
    }
}

if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
    throw 'O modulo ScheduledTasks nao esta disponivel neste Windows.'
}

$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)
$BackupLauncher = Join-Path $InstallDir 'backup.bat'
$CheckLauncher = Join-Path $InstallDir 'check.bat'
$ExportLauncher = Join-Path $InstallDir 'sincronizar_externo.bat'
$EffectiveTaskPath = Get-NormalizedTaskPath -Path $TaskPath
$RunLevel = if ($HighestPrivileges) { 'Highest' } else { 'Limited' }

Assert-CanRegisterTasks -RunAs $RunAs -HighestPrivileges ($RunLevel -eq 'Highest')

if (-not (Test-Path $BackupLauncher)) {
    throw "backup.bat nao encontrado em: $BackupLauncher"
}

if ($CreateCheckTask -and -not (Test-Path $CheckLauncher)) {
    throw "check.bat nao encontrado em: $CheckLauncher"
}

if ($CreateExportTask -and -not (Test-Path $ExportLauncher)) {
    throw "sincronizar_externo.bat nao encontrado em: $ExportLauncher"
}

if ($RunAs -eq 'System') {
    Write-Warning 'Tarefas em SYSTEM exigem que repositorio, senha e variaveis estejam acessiveis para SYSTEM. Prefira Scope Machine e caminhos nao mapeados por usuario.'
}

$SettingsArgs = @{
    AllowStartIfOnBatteries    = $true
    DontStopIfGoingOnBatteries = $true
    StartWhenAvailable         = $true
    MultipleInstances          = 'IgnoreNew'
}
$Settings = New-ScheduledTaskSettingsSet @SettingsArgs

$BackupAction = New-ScheduledTaskAction -Execute $BackupLauncher
$BackupTrigger = New-ScheduledTaskTrigger -Daily -At (Convert-TimeStringToDateTime -Time $BackupTime) -DaysInterval $BackupDaysInterval

if ($PSCmdlet.ShouldProcess("$EffectiveTaskPath$BackupTaskName", 'Register backup task')) {
    $BackupRegisterArgs = @{
        TaskName     = $BackupTaskName
        TaskPath     = $EffectiveTaskPath
        Action       = $BackupAction
        Trigger      = $BackupTrigger
        Settings     = $Settings
        Description  = 'Backup diario do Restic automatizado.'
        RunAs        = $RunAs
        UserName     = $UserName
        TaskPassword = $TaskPassword
        RunLevel     = $RunLevel
    }
    Register-TaskInternal @BackupRegisterArgs

    Write-Host "[OK] Tarefa registrada: $EffectiveTaskPath$BackupTaskName" -ForegroundColor Green
}

if ($CreateCheckTask) {
    $CheckActionArgs = if ($CheckMode -eq 'full') { '-FullCheck' } else { '' }
    $CheckAction = if ([string]::IsNullOrWhiteSpace($CheckActionArgs)) {
        New-ScheduledTaskAction -Execute $CheckLauncher
    } else {
        New-ScheduledTaskAction -Execute $CheckLauncher -Argument $CheckActionArgs
    }

    $CheckTrigger = New-ScheduledTaskTrigger -Weekly -At (Convert-TimeStringToDateTime -Time $CheckTime) -DaysOfWeek $CheckDay -WeeksInterval $CheckWeeksInterval

    if ($PSCmdlet.ShouldProcess("$EffectiveTaskPath$CheckTaskName", 'Register check task')) {
        $CheckRegisterArgs = @{
            TaskName     = $CheckTaskName
            TaskPath     = $EffectiveTaskPath
            Action       = $CheckAction
            Trigger      = $CheckTrigger
            Settings     = $Settings
            Description  = "Check $CheckMode do repositorio Restic."
            RunAs        = $RunAs
            UserName     = $UserName
            TaskPassword = $TaskPassword
            RunLevel     = $RunLevel
        }
        Register-TaskInternal @CheckRegisterArgs

        Write-Host "[OK] Tarefa registrada: $EffectiveTaskPath$CheckTaskName" -ForegroundColor Green
    }
}

if ($CreateExportTask) {
    $ExportAction = New-ScheduledTaskAction -Execute $ExportLauncher
    $ExportTrigger = New-ScheduledTaskTrigger -Weekly -At (Convert-TimeStringToDateTime -Time $ExportTime) -DaysOfWeek $ExportDay -WeeksInterval $ExportWeeksInterval

    if ($PSCmdlet.ShouldProcess("$EffectiveTaskPath$ExportTaskName", 'Register external sync task')) {
        $ExportRegisterArgs = @{
            TaskName     = $ExportTaskName
            TaskPath     = $EffectiveTaskPath
            Action       = $ExportAction
            Trigger      = $ExportTrigger
            Settings     = $Settings
            Description  = 'Sincronizacao semanal de snapshots ativos para repositorio externo.'
            RunAs        = $RunAs
            UserName     = $UserName
            TaskPassword = $TaskPassword
            RunLevel     = $RunLevel
        }
        Register-TaskInternal @ExportRegisterArgs

        Write-Host "[OK] Tarefa registrada: $EffectiveTaskPath$ExportTaskName" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Resumo das tarefas:' -ForegroundColor Cyan
Write-Host "- Pasta: $EffectiveTaskPath" -ForegroundColor Cyan
Write-Host "- Backup: $BackupTaskName as $BackupTime" -ForegroundColor Cyan
if ($CreateCheckTask) {
    Write-Host "- Check: $CheckTaskName as $CheckTime ($CheckDay, modo $CheckMode)" -ForegroundColor Cyan
} else {
    Write-Host '- Check: nao solicitado' -ForegroundColor Cyan
}
if ($CreateExportTask) {
    Write-Host "- Espelho externo: $ExportTaskName as $ExportTime ($ExportDay)" -ForegroundColor Cyan
} else {
    Write-Host '- Espelho externo: nao solicitado' -ForegroundColor Cyan
}
Write-Host "- Conta: $RunAs" -ForegroundColor Cyan