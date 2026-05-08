#Requires -Version 5.1
<#
.SYNOPSIS
    Backup automatizado com Restic.
.DESCRIPTION
    Executa backup incremental, aplica retencao (forget + prune),
    lista snapshots e envia notificacao via Telegram.
    Toda a configuracao fica em config.ps1.
.NOTES
    Registre a tarefa via setup\register_tasks.ps1 ou aponte o Agendador para backup.bat na raiz do projeto.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================
#  INICIALIZACAO
# ==============================================================

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

    $FailureLogFile = Join-Path $FallbackLogDir ('backup_{0}.log' -f $ScriptStart.ToString('yyyy-MM-dd_HH-mm-ss'))
    $FailureLine = '[{0}] [ERROR] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $FailureLogFile -Value $FailureLine -Encoding UTF8
    Write-Host $FailureLine -ForegroundColor Red

    $TelegramScript = Join-Path $ScriptDir 'telegram.ps1'
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TelegramScript -Subject '[ERRO] Backup Restic -- Falha na configuracao' -Body $Message 2>&1 | Out-Null
    } catch {
    }

    exit $ExitCode
}

# Carrega configuracao central
$ConfigPath = Join-Path $ScriptDir "config.ps1"
if (-not (Test-Path $ConfigPath)) {
    Exit-StartupFailure -ExitCode 99 -Message "Arquivo config.ps1 nao encontrado em: $ScriptDir"
}

try {
    . $ConfigPath
} catch {
    Exit-StartupFailure -ExitCode 1 -Message ("Falha ao carregar a configuracao: {0}" -f $_.Exception.Message)
}

# Garante que o diretorio de logs existe
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

$LogFile     = Join-Path $LOG_DIR ("backup_{0}.log" -f $ScriptStart.ToString("yyyy-MM-dd_HH-mm-ss"))
$NotificationLogFile = Join-Path $LOG_DIR "telegram-delivery.log"
$GlobalError = $false
$MailSubject = ""

# Configura variaveis de ambiente nativas do Restic
$env:RESTIC_REPOSITORY    = $REPOSITORY
$env:RESTIC_PASSWORD_FILE = $PASSWORD_FILE

$ExecutionIdentity = try {
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
} catch {
    if ($env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { "N/A" }
}

# Abre StreamWriter com FileShare.ReadWrite para evitar conflito de lock
# com o restic enquanto ele escaneia o disco
$Script:LogStream = [System.IO.StreamWriter]::new(
    $LogFile,
    $true,   # append
    [System.Text.Encoding]::UTF8
)
$Script:LogStream.AutoFlush = $true

# ==============================================================
#  FUNCOES
# ==============================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","OK","WARNING","ERROR")][string]$Level = "INFO"
    )
    $Ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "[$Ts] [$Level] $Message"
    $Script:LogStream.WriteLine($Line)
    $Color = switch ($Level) {
        "OK"      { "Green"  }
        "WARNING" { "Yellow" }
        "ERROR"   { "Red"    }
        default   { "White"  }
    }
    Write-Host $Line -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    $Sep   = "-" * 60
    $Lines = @("", $Sep, "  $Title", $Sep)
    foreach ($L in $Lines) {
        $Script:LogStream.WriteLine($L)
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

function Convert-BytesToDisplay {
    param([double]$Bytes)

    $Units = @("B", "KiB", "MiB", "GiB", "TiB")
    $Size = [double]$Bytes
    $Index = 0

    while ($Size -ge 1024 -and $Index -lt ($Units.Count - 1)) {
        $Size = $Size / 1024
        $Index++
    }

    if ($Index -eq 0) {
        return ("{0:N0} {1}" -f $Size, $Units[$Index])
    }

    return ("{0:N2} {1}" -f $Size, $Units[$Index])
}

function Convert-ByteDeltaToDisplay {
    param([double]$Bytes)

    if ($Bytes -eq 0) {
        return "0 B"
    }

    $Prefix = if ($Bytes -gt 0) { "+" } else { "-" }
    return "$Prefix$(Convert-BytesToDisplay -Bytes ([math]::Abs($Bytes)))"
}

function Get-RepositoryLocationInfo {
    param([string]$Path)

    $Info = [ordered]@{
        Repository  = $Path
        Kind        = "Desconhecido"
        Root        = ""
        Volume      = "N/A"
        FileSystem  = "N/A"
        FreeBytes   = $null
        SizeBytes   = $null
        FreeDisplay = "N/A"
        SizeDisplay = "N/A"
        Summary     = "Detalhes do destino indisponiveis"
    }

    if ($Path -match '^[A-Za-z]:\\') {
        $Drive = (Split-Path -Path $Path -Qualifier).TrimEnd('\\')
        $Info.Kind = "Disco local"
        $Info.Root = "$Drive\\"

        try {
            $Disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Drive)
            if ($Disk) {
                $Info.Volume = if ([string]::IsNullOrWhiteSpace($Disk.VolumeName)) { "(sem rotulo)" } else { $Disk.VolumeName }
                $Info.FileSystem = if ([string]::IsNullOrWhiteSpace($Disk.FileSystem)) { "N/A" } else { $Disk.FileSystem }
                $Info.FreeBytes = [double]$Disk.FreeSpace
                $Info.SizeBytes = [double]$Disk.Size
                $Info.FreeDisplay = Convert-BytesToDisplay -Bytes $Info.FreeBytes
                $Info.SizeDisplay = Convert-BytesToDisplay -Bytes $Info.SizeBytes
                $Info.Summary = "$Drive | $($Info.Volume) | Livre $($Info.FreeDisplay) de $($Info.SizeDisplay) | $($Info.FileSystem)"
            } else {
                $Info.Summary = "$Drive | volume nao localizado"
            }
        } catch {
            $Info.Summary = "$Drive | falha ao consultar volume"
        }
    } elseif ($Path -match '^\\\\') {
        $Info.Kind = "Rede"
        $Info.Summary = "Caminho de rede/UNC"
    } elseif (-not [string]::IsNullOrWhiteSpace($Path)) {
        $Info.Kind = "Caminho"
        $Info.Summary = "Caminho sem unidade local identificavel"
    }

    return [pscustomobject]$Info
}

function Invoke-Restic {
    param([string[]]$Arguments)
    Write-Log "Executando: restic $($Arguments -join ' ')"
    # ErrorActionPreference local = Continue para nao lancar excecao
    # no stderr de processo externo (LASTEXITCODE ainda e capturado)
    $local:ErrorActionPreference = "Continue"
    $OriginalConsoleEncoding = [Console]::OutputEncoding
    $Utf8Encoding = [System.Text.UTF8Encoding]::new($false)
    try {
        [Console]::OutputEncoding = $Utf8Encoding
        & $RESTIC_EXE @Arguments 2>&1 | ForEach-Object {
            $Line = "  [$(Get-Date -Format 'HH:mm:ss')]  $_"
            $Script:LogStream.WriteLine($Line)
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

function Close-Log {
    if ($Script:LogStream -and $Script:LogStream.BaseStream) {
        $Script:LogStream.Flush()
        $Script:LogStream.Close()
    }
}

function Remove-OldLogs {
    try {
        $Cutoff  = (Get-Date).AddDays(-$LOG_KEEP_DAYS)
        $OldLogs = @(Get-ChildItem -Path $LOG_DIR -Filter "*.log" |
                     Where-Object { $_.LastWriteTime -lt $Cutoff })
        if ($OldLogs.Count -gt 0) {
            Write-Log "Removendo $($OldLogs.Count) log(s) com mais de $LOG_KEEP_DAYS dias..."
            $OldLogs | Remove-Item -Force
            Write-Log "Logs antigos removidos." -Level "OK"
        }
    } catch {
        Write-Log "Falha ao remover logs antigos: $($_.Exception.Message)" -Level "WARNING"
    }
}

# ==============================================================
#  CABECALHO DO LOG
# ==============================================================

$RepositoryInfoAtStart = Get-RepositoryLocationInfo -Path $REPOSITORY
$Sep = "=" * 60
@("", $Sep,
  "  BACKUP RESTIC",
  "  Inicio: $($ScriptStart.ToString('yyyy-MM-dd HH:mm:ss'))",
    "  Host: $env:COMPUTERNAME",
    "  Conta: $ExecutionIdentity",
  "  Repositorio: $REPOSITORY",
    "  Destino fisico: $($RepositoryInfoAtStart.Summary)",
    "  Arquivo de log: $LogFile",
  $Sep, "") | ForEach-Object {
    $Script:LogStream.WriteLine($_)
    Write-Host $_ -ForegroundColor Cyan
}

# ==============================================================
#  FASE 0 - VALIDACOES
# ==============================================================

Write-Section "FASE 0 -- VALIDACOES"

Write-Log "Host de execucao: $env:COMPUTERNAME"
Write-Log "Conta de execucao: $ExecutionIdentity"
Write-Log "Arquivo de log atual: $LogFile"
Write-Log "Destino fisico: $($RepositoryInfoAtStart.Summary)"
if ($null -ne $RepositoryInfoAtStart.FreeBytes -and $null -ne $RepositoryInfoAtStart.SizeBytes) {
    Write-Log "Espaco livre inicial no destino: $($RepositoryInfoAtStart.FreeDisplay) de $($RepositoryInfoAtStart.SizeDisplay)"
}
$ValidationResults = foreach ($ValidationItem in @(
    @{ Path = $RESTIC_EXE;    Label = "Restic executavel" }
    @{ Path = $PASSWORD_FILE; Label = "Arquivo de senha"  }
    @{ Path = $REPOSITORY;    Label = "Repositorio"       }
) ) {
    if (Test-Path $ValidationItem.Path) {
        Write-Log "$($ValidationItem.Label): $($ValidationItem.Path)" -Level "OK"
        $true
    } else {
        Write-Log "$($ValidationItem.Label) NAO ENCONTRADO: $($ValidationItem.Path)" -Level "ERROR"
        $false
    }
}

if ($ValidationResults -contains $false) {
    Write-Log "Validacao falhou. Abortando backup." -Level "ERROR"
    Close-Log
    Send-Notification -Subject "[ERRO] Backup Restic -- Falha na validacao"
    exit 1
}

# ==============================================================
#  FASE 1 - BACKUP
# ==============================================================

Write-Section "FASE 1 -- BACKUP"
Write-Log "Fontes: $($BACKUP_SOURCES -join ', ')"
Write-Log "Exclusoes: $($BACKUP_EXCLUDES.Count) padroes configurados"

$BackupArgs = @("backup") + $BACKUP_SOURCES
foreach ($Excl in $BACKUP_EXCLUDES) {
    $BackupArgs += "--exclude"
    $BackupArgs += $Excl
}

$BackupExit = Invoke-Restic -Arguments $BackupArgs

switch ($BackupExit) {
    0 {
        Write-Log "Backup concluido sem avisos." -Level "OK"
        $MailSubject = "[OK] Backup Restic"
    }
    3 {
        # 3 = alguns arquivos nao puderam ser lidos (ex: em uso), mas o snapshot foi salvo
        Write-Log "Backup concluido com avisos (alguns arquivos ignorados/em uso). Codigo: $BackupExit" -Level "WARNING"
        $MailSubject = "[WARNING] Backup Restic"
    }
    default {
        Write-Log "Falha critica durante o backup. Codigo: $BackupExit" -Level "ERROR"
        $GlobalError = $true
    }
}

if ($GlobalError) {
    Close-Log
    Send-Notification -Subject "[ERRO] Backup Restic -- Falha no backup"
    exit $BackupExit
}

# ==============================================================
#  FASE 2 - RETENCAO (forget + prune)
# ==============================================================

Write-Section "FASE 2 -- RETENCAO E PRUNE"
Write-Log "Politica: keep-last=$KEEP_LAST, keep-weekly=$KEEP_WEEKLY, keep-monthly=$KEEP_MONTHLY"

$ForgetExit = Invoke-Restic -Arguments @(
    "forget", "--prune",
    "--keep-last",    "$KEEP_LAST",
    "--keep-weekly",  "$KEEP_WEEKLY",
    "--keep-monthly", "$KEEP_MONTHLY"
)

if ($ForgetExit -gt 1) {
    Write-Log "Falha durante forget/prune. Codigo: $ForgetExit" -Level "ERROR"
    $GlobalError = $true
} elseif ($ForgetExit -eq 1) {
    Write-Log "Forget/prune concluido com avisos." -Level "WARNING"
} else {
    Write-Log "Retencao aplicada e espaco liberado com sucesso." -Level "OK"
}

if ($GlobalError) {
    Close-Log
    Send-Notification -Subject "[ERRO] Backup Restic -- Falha na retencao"
    exit $ForgetExit
}

# ==============================================================
#  FASE 3 - SNAPSHOTS
# ==============================================================

Write-Section "FASE 3 -- SNAPSHOTS ATIVOS"

$SnapExit = Invoke-Restic -Arguments @("snapshots")

if ($SnapExit -gt 1) {
    Write-Log "Falha ao listar snapshots. Codigo: $SnapExit" -Level "WARNING"
} else {
    Write-Log "Listagem de snapshots concluida." -Level "OK"
}

# ==============================================================
#  RODAPE DO LOG
# ==============================================================

$RepositoryInfoAtEnd = Get-RepositoryLocationInfo -Path $REPOSITORY
$FreeSpaceDeltaDisplay = "N/A"
if ($null -ne $RepositoryInfoAtStart.FreeBytes -and $null -ne $RepositoryInfoAtEnd.FreeBytes) {
    $FreeSpaceDeltaDisplay = Convert-ByteDeltaToDisplay -Bytes ($RepositoryInfoAtEnd.FreeBytes - $RepositoryInfoAtStart.FreeBytes)
}

Write-Section "RESUMO FINAL"
Write-Log "Arquivo de log atual: $LogFile"
Write-Log "Destino fisico: $($RepositoryInfoAtEnd.Summary)"
if ($null -ne $RepositoryInfoAtEnd.FreeBytes -and $null -ne $RepositoryInfoAtEnd.SizeBytes) {
    Write-Log "Espaco livre final no destino: $($RepositoryInfoAtEnd.FreeDisplay) de $($RepositoryInfoAtEnd.SizeDisplay)"
    Write-Log "Variacao no espaco livre: $FreeSpaceDeltaDisplay"
}

$Duration = (Get-Date) - $ScriptStart

@("", $Sep,
  "  BACKUP CONCLUIDO",
  "  Fim:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
  "  Duracao: $($Duration.ToString('hh\:mm\:ss'))",
  $Sep, "") | ForEach-Object {
    $Script:LogStream.WriteLine($_)
    Write-Host $_ -ForegroundColor Cyan
}

# ==============================================================
#  NOTIFICACAO + LIMPEZA DE LOGS
# ==============================================================

Remove-OldLogs

Close-Log

Send-Notification -Subject $MailSubject

exit 0
