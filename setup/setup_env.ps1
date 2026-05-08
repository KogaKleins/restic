#Requires -Version 5.1
<#
.SYNOPSIS
    Registra a configuracao do Restic nas variaveis de ambiente do Windows.
.DESCRIPTION
    Use este script para preparar uma maquina nova sem deixar dados pessoais
    hardcoded no repositorio.

        As variaveis sao gravadas no armazenamento nativo do Windows:
            User    -> HKCU:\Environment
            Machine -> HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment

        Ou seja: este script nao gera arquivo .env. Ele grava no Registro do Windows.

        Exemplos:
            .\setup\setup_env.ps1 -ResticExe "C:\Program Files\WinGet\Links\restic.exe" -Repository "E:\restic-backup" -SecretFilePath "C:\restic\runtime\secrets\restic-password.txt" -TelegramToken "TOKEN" -TelegramChatId "123456"
            .\setup\setup_env.ps1 -Scope Machine -ResticExe "C:\Program Files\WinGet\Links\restic.exe" -Repository "D:\restic" -SecretFilePath "C:\restic\runtime\secrets\restic-password.txt"
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    "PSAvoidUsingPlainTextForPassword",
    "SecretFilePath",
    Justification = "SecretFilePath recebe apenas o caminho do arquivo de senha do restic, nao a senha em texto puro."
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    "PSAvoidUsingPlainTextForPassword",
    "PasswordFile",
    Justification = "Os parametros deste script recebem caminhos de arquivos, nao senhas em texto puro."
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    "PSAvoidUsingPlainTextForPassword",
    "ExportPasswordFile",
    Justification = "ExportPasswordFile recebe apenas o caminho do arquivo de senha do repositorio externo."
)]
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("User", "Machine")]
    [string]$Scope = "User",

    [Parameter(Mandatory)][string]$ResticExe,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$SecretFilePath,

    [string]$LogDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "runtime\logs"),
    [int]$LogKeepDays = 30,

    [string]$ExportRepository = "",
    [string]$ExportPasswordFile = "",

    [string]$TelegramToken = "",
    [string]$TelegramChatId = "",

    [int]$KeepLast = 7,
    [int]$KeepWeekly = 4,
    [int]$KeepMonthly = 3,

    [string[]]$BackupSources = @(
        (Join-Path $env:SystemDrive "Users")
    ),

    [string[]]$BackupExcludes = @(
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
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$EnvironmentMap = [ordered]@{
    RESTIC_EXE             = $ResticExe
    RESTIC_REPOSITORY      = $Repository
    RESTIC_PASSWORD_FILE   = $SecretFilePath
    RESTIC_LOG_DIR         = $LogDir
    RESTIC_LOG_KEEP_DAYS   = [string]$LogKeepDays
    RESTIC_EXPORT_REPOSITORY = $ExportRepository
    RESTIC_EXPORT_PASSWORD_FILE = $ExportPasswordFile
    RESTIC_TELEGRAM_TOKEN  = $TelegramToken
    RESTIC_TELEGRAM_CHATID = $TelegramChatId
    RESTIC_KEEP_LAST       = [string]$KeepLast
    RESTIC_KEEP_WEEKLY     = [string]$KeepWeekly
    RESTIC_KEEP_MONTHLY    = [string]$KeepMonthly
    RESTIC_BACKUP_SOURCES  = ($BackupSources -join ';')
    RESTIC_BACKUP_EXCLUDES = ($BackupExcludes -join ';')
}

foreach ($Entry in $EnvironmentMap.GetEnumerator()) {
    if ($PSCmdlet.ShouldProcess("$Scope environment", "Set $($Entry.Key)")) {
        [Environment]::SetEnvironmentVariable($Entry.Key, $Entry.Value, $Scope)
        [Environment]::SetEnvironmentVariable($Entry.Key, $Entry.Value, "Process")
        Write-Host "[OK] $($Entry.Key) definido em $Scope" -ForegroundColor Green
    } else {
        Write-Host "[WHATIF] $($Entry.Key) seria definido em $Scope" -ForegroundColor Yellow
    }
}

Write-Host "" 
Write-Host "Configuracao registrada com sucesso." -ForegroundColor Cyan
Write-Host "Escopo: $Scope" -ForegroundColor Cyan
if ($Scope -eq "User") {
    Write-Host "Local no Windows: HKCU:\Environment" -ForegroundColor Cyan
} else {
    Write-Host "Local no Windows: HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -ForegroundColor Cyan
}
Write-Host "Variaveis definidas: $($EnvironmentMap.Keys -join ', ')" -ForegroundColor Cyan