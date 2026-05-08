#Requires -Version 5.1
<#
.SYNOPSIS
    Mostra a configuracao efetiva do Restic vinda das variaveis de ambiente.
.DESCRIPTION
    Exibe o valor efetivo e o escopo de origem (Process, User ou Machine).
    Segredos sao mascarados para evitar exposicao acidental.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ScopedEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($Scope in @("Process", "User", "Machine")) {
        $Value = [Environment]::GetEnvironmentVariable($Name, $Scope)
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return [pscustomobject]@{
                Name  = $Name
                Scope = $Scope
                Value = $Value
            }
        }
    }

    return [pscustomobject]@{
        Name  = $Name
        Scope = "(nao definido)"
        Value = ""
    }
}

function Format-DisplayValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        return ""
    }

    if ($Name -eq "RESTIC_TELEGRAM_TOKEN") {
        if ($Value.Length -le 8) {
            return "********"
        }
        return "{0}...{1}" -f $Value.Substring(0, 4), $Value.Substring($Value.Length - 4)
    }

    return $Value
}

$VariableNames = @(
    "RESTIC_EXE"
    "RESTIC_REPOSITORY"
    "RESTIC_PASSWORD_FILE"
    "RESTIC_LOG_DIR"
    "RESTIC_LOG_KEEP_DAYS"
    "RESTIC_EXPORT_REPOSITORY"
    "RESTIC_EXPORT_PASSWORD_FILE"
    "RESTIC_TELEGRAM_TOKEN"
    "RESTIC_TELEGRAM_CHATID"
    "RESTIC_KEEP_LAST"
    "RESTIC_KEEP_WEEKLY"
    "RESTIC_KEEP_MONTHLY"
    "RESTIC_BACKUP_SOURCES"
    "RESTIC_BACKUP_EXCLUDES"
)

Write-Host "Restic environment configuration" -ForegroundColor Cyan
Write-Host "User registry path:    HKCU:\Environment" -ForegroundColor DarkCyan
Write-Host "Machine registry path: HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" -ForegroundColor DarkCyan
Write-Host ""

$Rows = foreach ($Name in $VariableNames) {
    $Item = Get-ScopedEnvironmentValue -Name $Name
    [pscustomobject]@{
        Name  = $Item.Name
        Scope = $Item.Scope
        Value = Format-DisplayValue -Name $Item.Name -Value $Item.Value
    }
}

$Rows | Format-Table -AutoSize | Out-String | Write-Host
