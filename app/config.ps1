# =============================================================
#  RESTIC BACKUP — CONFIGURACAO VIA VARIAVEIS DE AMBIENTE
#
#  Este arquivo NAO deve conter dados pessoais ou caminhos fixos
#  do ambiente do usuario. Toda configuracao sensivel/instalacao
#  deve vir das variaveis de ambiente do Windows.
#
#  Variaveis esperadas:
#    RESTIC_EXE
#    RESTIC_REPOSITORY
#    RESTIC_PASSWORD_FILE
#    RESTIC_LOG_DIR
#    RESTIC_LOG_KEEP_DAYS
#    RESTIC_EXPORT_REPOSITORY
#    RESTIC_EXPORT_PASSWORD_FILE
#    RESTIC_TELEGRAM_TOKEN
#    RESTIC_TELEGRAM_CHATID
#    RESTIC_KEEP_LAST
#    RESTIC_KEEP_WEEKLY
#    RESTIC_KEEP_MONTHLY
#    RESTIC_BACKUP_SOURCES          (separadas por ;)
#    RESTIC_BACKUP_EXCLUDES         (separadas por ;)
#
#  Resolucao: Process -> User -> Machine.
# =============================================================

$ConfigScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ConfigScriptDir

function Get-ConfigValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Default = "",
        [switch]$Required
    )

    foreach ($Scope in @("Process", "User", "Machine")) {
        $Value = [Environment]::GetEnvironmentVariable($Name, $Scope)
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return $Value.Trim()
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Default)) {
        return $Default
    }

    if ($Required) {
        throw "Variavel de ambiente obrigatoria nao definida: $Name"
    }

    return ""
}

function Get-ConfigIntValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Default,
        [switch]$Required
    )

    $RawValue = Get-ConfigValue -Name $Name -Default ([string]$Default) -Required:$Required
    $ParsedValue = 0
    if (-not [int]::TryParse($RawValue, [ref]$ParsedValue)) {
        throw "Valor invalido para ${Name}: $RawValue"
    }

    return $ParsedValue
}

function Get-ConfigListValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Default = @(),
        [switch]$Required
    )

    $RawValue = Get-ConfigValue -Name $Name -Required:$Required
    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return $Default
    }

    return @(
        $RawValue -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

# --- Executavel ---
$RESTIC_EXE = Get-ConfigValue -Name "RESTIC_EXE" -Required

# --- Repositorio ---
$REPOSITORY    = Get-ConfigValue -Name "RESTIC_REPOSITORY" -Required
$PASSWORD_FILE = Get-ConfigValue -Name "RESTIC_PASSWORD_FILE" -Required

# --- Logs ---
$LOG_DIR       = Get-ConfigValue -Name "RESTIC_LOG_DIR" -Default (Join-Path $ProjectRoot "runtime\logs")
$LOG_KEEP_DAYS = Get-ConfigIntValue -Name "RESTIC_LOG_KEEP_DAYS" -Default 30

# --- Espelho externo / exportacao ---
$EXPORT_REPOSITORY = Get-ConfigValue -Name "RESTIC_EXPORT_REPOSITORY"
$EXPORT_PASSWORD_FILE = Get-ConfigValue -Name "RESTIC_EXPORT_PASSWORD_FILE" -Default $PASSWORD_FILE

# --- Telegram ---
$TELEGRAM_TOKEN  = Get-ConfigValue -Name "RESTIC_TELEGRAM_TOKEN"
$TELEGRAM_CHATID = Get-ConfigValue -Name "RESTIC_TELEGRAM_CHATID"

# --- Politica de retencao de snapshots ---
$KEEP_LAST    = Get-ConfigIntValue -Name "RESTIC_KEEP_LAST" -Default 7
$KEEP_WEEKLY  = Get-ConfigIntValue -Name "RESTIC_KEEP_WEEKLY" -Default 4
$KEEP_MONTHLY = Get-ConfigIntValue -Name "RESTIC_KEEP_MONTHLY" -Default 3

# --- Fontes de backup ---
$BACKUP_SOURCES = Get-ConfigListValue -Name "RESTIC_BACKUP_SOURCES" -Default @(
    (Join-Path $env:SystemDrive "Users")
)

# --- Exclusoes ---
$BACKUP_EXCLUDES = Get-ConfigListValue -Name "RESTIC_BACKUP_EXCLUDES" -Default @(
    "AppData\Local\Temp"
    "AppData\Local\Packages"
    "AppData\Local\Microsoft\Windows\INetCache"
    "AppData\Local\Google\Chrome\User Data\Default\Cache"
    "AppData\Local\Microsoft\Edge\User Data\Default\Cache"
    "OneDrive\Temp"
    "*.tmp"
    ".codex"
    ".cache"
    "AppData\Local\Microsoft\WindowsApps"
    "CodexSandboxOffline"
)
