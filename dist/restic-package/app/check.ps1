#Requires -Version 5.1
<#
.SYNOPSIS
    Verifica a integridade do repositorio Restic.
.PARAMETER FullCheck
    Se especificado, le 100% dos dados (mais lento). Padrao: 10%.
.NOTES
    Registre a tarefa via setup\register_tasks.ps1 ou aponte o Agendador para check.bat na raiz do projeto.
#>

[CmdletBinding()]
param(
    [switch]$FullCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptStart = Get-Date
$ScriptDir   = $PSScriptRoot
$FallbackLogDir = Join-Path (Split-Path -Parent $ScriptDir) 'runtime\logs'

function Exit-StartupFailure {
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not (Test-Path -LiteralPath $FallbackLogDir)) {
        New-Item -ItemType Directory -Path $FallbackLogDir -Force | Out-Null
    }

    $FailureLogFile = Join-Path $FallbackLogDir ('check_{0}.log' -f $ScriptStart.ToString('yyyy-MM-dd_HH-mm-ss'))
    $FailureLine = '[{0}] [ERROR] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $FailureLogFile -Value $FailureLine -Encoding UTF8
    Write-Host $FailureLine -ForegroundColor Red

    $TelegramScript = Join-Path $ScriptDir 'telegram.ps1'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TelegramScript -Subject '[ERRO] Check Restic -- Falha na configuracao' -Body $Message 2>&1 | Out-Null
    } catch {
    }

    exit $ExitCode
}

$ConfigPath = Join-Path $ScriptDir "config.ps1"
if (-not (Test-Path $ConfigPath)) {
    Exit-StartupFailure -ExitCode 99 -Message "Arquivo config.ps1 nao encontrado em: $ScriptDir"
}

try {
    . $ConfigPath
} catch {
    Exit-StartupFailure -ExitCode 1 -Message ("Falha ao carregar a configuracao: {0}" -f $_.Exception.Message)
}

if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

$LogFile = Join-Path $LOG_DIR ("check_{0}.log" -f $ScriptStart.ToString("yyyy-MM-dd_HH-mm-ss"))
$NotificationLogFile = Join-Path $LOG_DIR "telegram-delivery.log"

$env:RESTIC_REPOSITORY    = $REPOSITORY
$env:RESTIC_PASSWORD_FILE = $PASSWORD_FILE

# ==============================================================
#  FUNCOES
# ==============================================================

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","OK","WARNING","ERROR")][string]$Level = "INFO")
    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $Line -Encoding UTF8
    $Color = switch ($Level) { "OK" { "Green" } "WARNING" { "Yellow" } "ERROR" { "Red" } default { "White" } }
    Write-Host $Line -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    $Sep   = "-" * 60
    $Lines = @("", $Sep, "  $Title", $Sep)
    foreach ($L in $Lines) {
        Add-Content -Path $LogFile -Value $L -Encoding UTF8
        Write-Host $L -ForegroundColor Cyan
    }
}

function Write-NotificationAudit {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARNING","ERROR")][string]$Level = "INFO"
    )

    $Line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $NotificationLogFile -Value $Line -Encoding UTF8

    $Color = switch ($Level) {
        "OK"      { "Green" }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red" }
        default    { "DarkCyan" }
    }

    Write-Host $Line -ForegroundColor $Color
}

function Invoke-Restic {
    param([string[]]$Arguments)
    Write-Log "Executando: restic $($Arguments -join ' ')"
    $local:ErrorActionPreference = "Continue"
    $OriginalConsoleEncoding = [Console]::OutputEncoding
    $Utf8Encoding = [System.Text.UTF8Encoding]::new($false)
    try {
        [Console]::OutputEncoding = $Utf8Encoding
        & $RESTIC_EXE @Arguments 2>&1 | ForEach-Object {
            $Line = "  [$(Get-Date -Format 'HH:mm:ss')]  $_"
            Add-Content -Path $LogFile -Value $Line -Encoding UTF8
            Write-Host $Line -ForegroundColor Gray
        }
    } finally {
        [Console]::OutputEncoding = $OriginalConsoleEncoding
    }
    return $LASTEXITCODE
}

function Send-Notification {
    param([string]$Subject)

    $TelegramScript = Join-Path $ScriptDir "telegram.ps1"
    $NotificationOutput = @()
    $NotificationExitCode = 0

    try {
        $NotificationOutput = @(
            & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                -File $TelegramScript `
                -Subject $Subject `
                -LogFile $LogFile 2>&1
        )
        $NotificationExitCode = $LASTEXITCODE
    } catch {
        $NotificationExitCode = -1
        $NotificationOutput = @($_.Exception.Message)
    }

    if ($NotificationExitCode -eq 0) {
        Write-NotificationAudit "Telegram enviado com sucesso. Assunto: $Subject | Log: $LogFile" -Level "OK"
        return
    }

    Write-NotificationAudit "Falha ao enviar Telegram. Assunto: $Subject | ExitCode: $NotificationExitCode | Log: $LogFile" -Level "ERROR"
    foreach ($OutputLine in ($NotificationOutput | Select-Object -First 12)) {
        $RenderedLine = [string]$OutputLine
        if (-not [string]::IsNullOrWhiteSpace($RenderedLine)) {
            Write-NotificationAudit "telegram.ps1> $RenderedLine" -Level "ERROR"
        }
    }
}

# ==============================================================
#  CABECALHO
# ==============================================================

$Sep  = "=" * 60
$Mode = if ($FullCheck) { "COMPLETA (100% dos dados)" } else { "PARCIAL (10% dos dados)" }

@("", $Sep,
  "  CHECK RESTIC -- $Mode",
  "  Inicio: $($ScriptStart.ToString('yyyy-MM-dd HH:mm:ss'))",
  "  Repositorio: $REPOSITORY",
  $Sep, "") | ForEach-Object {
    Add-Content -Path $LogFile -Value $_ -Encoding UTF8
    Write-Host $_ -ForegroundColor Cyan
}

# ==============================================================
#  VALIDACOES
# ==============================================================

Write-Section "VALIDACOES"

foreach ($Item in @(
    @{ Path = $RESTIC_EXE;    Label = "Restic executavel" }
    @{ Path = $PASSWORD_FILE; Label = "Arquivo de senha"  }
    @{ Path = $REPOSITORY;    Label = "Repositorio"       }
)) {
    if (Test-Path $Item.Path) {
        Write-Log "$($Item.Label): $($Item.Path)" -Level "OK"
    } else {
        Write-Log "$($Item.Label) NAO ENCONTRADO: $($Item.Path)" -Level "ERROR"
        Send-Notification -Subject "[ERRO] Check Restic -- Falha na validacao"
        exit 1
    }
}

# ==============================================================
#  CHECK DE INTEGRIDADE
# ==============================================================

Write-Section "VERIFICACAO DE INTEGRIDADE"

$CheckArgs = @("check")
if (-not $FullCheck) { $CheckArgs += "--read-data-subset=10%" }

$CheckExit = Invoke-Restic -Arguments $CheckArgs
$Duration  = (Get-Date) - $ScriptStart

@("", $Sep,
  "  CHECK CONCLUIDO",
  "  Fim:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
  "  Duracao: $($Duration.ToString('hh\:mm\:ss'))",
  $Sep, "") | ForEach-Object {
    Add-Content -Path $LogFile -Value $_ -Encoding UTF8
    Write-Host $_ -ForegroundColor Cyan
}

# ==============================================================
#  RESULTADO E NOTIFICACAO
# ==============================================================

if ($CheckExit -eq 0) {
    Write-Log "Repositorio integro." -Level "OK"
    Send-Notification -Subject "[OK] Check Restic -- Repositorio integro"
    exit 0
} else {
    Write-Log "Problema detectado no repositorio! Codigo: $CheckExit" -Level "ERROR"
    Send-Notification -Subject "[ERRO] Check Restic -- Problema detectado!"
    exit $CheckExit
}
