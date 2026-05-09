#Requires -Version 5.1
<#
.SYNOPSIS
    Mostra como a politica atual de retencao preserva snapshots.
.DESCRIPTION
    Executa restic forget em modo dry-run com a politica configurada e
    organiza o resultado em tres camadas: recentes, semanais extras e
    mensais extras.
#>

[CmdletBinding()]
param()

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
    throw "Arquivo de senha nao encontrado em: $PASSWORD_FILE"
}

$env:RESTIC_REPOSITORY = $REPOSITORY
$env:RESTIC_PASSWORD_FILE = $PASSWORD_FILE

function Get-ColumnSegments {
    param([string]$Line)

    $Content = $Line.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    return @(
        $Content -split '\s{2,}' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-SnapshotNotesText {
    param($Entry)

    if ($null -eq $Entry -or $null -eq $Entry.Notes -or $Entry.Notes.Count -eq 0) {
        return ''
    }

    return (@($Entry.Notes | Select-Object -Unique) -join ', ')
}

function Test-SnapshotHasNote {
    param(
        $Entry,
        [Parameter(Mandatory)][string]$Pattern
    )

    if ($null -eq $Entry -or $null -eq $Entry.Notes) {
        return $false
    }

    foreach ($Note in @($Entry.Notes)) {
        if (-not [string]::IsNullOrWhiteSpace($Note) -and $Note.ToLowerInvariant() -match $Pattern) {
            return $true
        }
    }

    return $false
}

function Get-RetentionInfo {
    param([string[]]$Lines)

    $Info = [ordered]@{
        Policy      = 'N/A'
        Kept        = [System.Collections.Generic.List[object]]::new()
        Removed     = [System.Collections.Generic.List[object]]::new()
        KeepCount   = 0
        RemoveCount = 0
    }

    $Section = ''
    $CurrentKeep = $null

    foreach ($Line in $Lines) {
        if ($Line -match '^Applying Policy:\s+(.*)$') {
            $Info.Policy = $Matches[1].Trim()
            continue
        }

        if ($Line -match '^keep\s+(\d+)\s+snapshots:') {
            $Info.KeepCount = [int]$Matches[1]
            $Section = 'Keep'
            $CurrentKeep = $null
            continue
        }

        if ($Line -match '^remove\s+(\d+)\s+snapshots:') {
            $Info.RemoveCount = [int]$Matches[1]
            $Section = 'Remove'
            $CurrentKeep = $null
            continue
        }

        if (-not $Section) {
            continue
        }

        $Content = $Line.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($Content)) {
            continue
        }

        if ($Content -match '^snapshots for host ' -or $Content -match '^ID\s+Time' -or $Content -match '^-{5,}$') {
            continue
        }

        if ($Content -match '^\d+\s+snapshots$') {
            $Section = ''
            $CurrentKeep = $null
            continue
        }

        $Segments = @(Get-ColumnSegments -Line $Content)
        if ($Segments.Count -eq 0) {
            continue
        }

        if ($Segments.Count -eq 1 -and $Section -eq 'Keep' -and $null -ne $CurrentKeep) {
            [void]$CurrentKeep.Notes.Add($Segments[0])
            continue
        }

        if ($Segments[0] -notmatch '^[a-f0-9]{8}$' -or $Segments.Count -lt 5) {
            continue
        }

        $Entry = [pscustomobject]@{
            Id    = $Segments[0]
            Time  = $Segments[1]
            Host  = $Segments[2]
            Path  = $Segments[$Segments.Count - 2]
            Size  = $Segments[$Segments.Count - 1]
            Notes = [System.Collections.Generic.List[string]]::new()
        }

        if ($Segments.Count -gt 5) {
            for ($Index = 3; $Index -lt ($Segments.Count - 2); $Index++) {
                if (-not [string]::IsNullOrWhiteSpace($Segments[$Index])) {
                    [void]$Entry.Notes.Add($Segments[$Index])
                }
            }
        }

        if ($Section -eq 'Keep') {
            $Info.Kept.Add($Entry)
            $CurrentKeep = $Entry
        } else {
            $Info.Removed.Add($Entry)
        }
    }

    if ($Info.KeepCount -eq 0) {
        $Info.KeepCount = $Info.Kept.Count
    }

    if ($Info.RemoveCount -eq 0) {
        $Info.RemoveCount = $Info.Removed.Count
    }

    return [pscustomobject]$Info
}

function Get-OrderedRetentionLayout {
    param($Entries)

    $Recent = [System.Collections.Generic.List[object]]::new()
    $WeeklyExtras = [System.Collections.Generic.List[object]]::new()
    $MonthlyExtras = [System.Collections.Generic.List[object]]::new()
    $OtherKept = [System.Collections.Generic.List[object]]::new()
    $RecentIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $WeeklyIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($Entry in @($Entries)) {
        if (Test-SnapshotHasNote -Entry $Entry -Pattern 'last snapshot') {
            $Recent.Add($Entry)
            [void]$RecentIds.Add($Entry.Id)
        }
    }

    foreach ($Entry in @($Entries)) {
        if ($RecentIds.Contains($Entry.Id)) {
            continue
        }

        if (Test-SnapshotHasNote -Entry $Entry -Pattern 'weekly snapshot') {
            $WeeklyExtras.Add($Entry)
            [void]$WeeklyIds.Add($Entry.Id)
        }
    }

    foreach ($Entry in @($Entries)) {
        if ($RecentIds.Contains($Entry.Id) -or $WeeklyIds.Contains($Entry.Id)) {
            continue
        }

        if (Test-SnapshotHasNote -Entry $Entry -Pattern 'monthly snapshot') {
            $MonthlyExtras.Add($Entry)
        }
    }

    foreach ($Entry in @($Entries)) {
        if ($RecentIds.Contains($Entry.Id) -or $WeeklyIds.Contains($Entry.Id)) {
            continue
        }

        $IsMonthly = Test-SnapshotHasNote -Entry $Entry -Pattern 'monthly snapshot'
        if (-not $IsMonthly) {
            $OtherKept.Add($Entry)
        }
    }

    return [pscustomobject]@{
        Recent = $Recent
        WeeklyExtras = $WeeklyExtras
        MonthlyExtras = $MonthlyExtras
        OtherKept = $OtherKept
    }
}

function Show-SnapshotSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)]$Entries,
        [string]$EmptyText = 'nenhum snapshot nesta camada'
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('-' * $Title.Length) -ForegroundColor Cyan

    if (@($Entries).Count -eq 0) {
        Write-Host ("- {0}" -f $EmptyText) -ForegroundColor Yellow
        return
    }

    foreach ($Entry in @($Entries)) {
        Write-Host ("- {0} | {1} | {2}" -f $Entry.Id, $Entry.Time, $Entry.Size)
        Write-Host ("  caminho: {0}" -f $Entry.Path) -ForegroundColor DarkCyan
        $Notes = Get-SnapshotNotesText -Entry $Entry
        if ($Notes) {
            Write-Host ("  motivo: {0}" -f $Notes) -ForegroundColor DarkCyan
        }
    }
}

$ForgetArgs = @(
    'forget'
    '--dry-run'
    '--no-lock'
    '--keep-last'
    [string]$KEEP_LAST
    '--keep-weekly'
    [string]$KEEP_WEEKLY
    '--keep-monthly'
    [string]$KEEP_MONTHLY
)

$RawOutput = @(& $RESTIC_EXE @ForgetArgs 2>&1)
$ForgetExitCode = $LASTEXITCODE
if ($ForgetExitCode -ne 0) {
    $ErrorText = if ($RawOutput.Count -gt 0) { ($RawOutput | ForEach-Object { $_.ToString() } | Select-Object -First 8) -join [Environment]::NewLine } else { 'Sem detalhes adicionais.' }
    throw "Falha ao simular a retencao. ExitCode: $ForgetExitCode`n$ErrorText"
}

$OutputLines = @($RawOutput | ForEach-Object { $_.ToString().TrimEnd() })
$RetentionInfo = Get-RetentionInfo -Lines $OutputLines
$Layout = Get-OrderedRetentionLayout -Entries $RetentionInfo.Kept

Write-Host 'POLITICA ATUAL' -ForegroundColor Cyan
Write-Host '--------------' -ForegroundColor Cyan
Write-Host ("- Janela recente: {0}" -f $KEEP_LAST)
Write-Host ("- Semanas protegidas: {0}" -f $KEEP_WEEKLY)
Write-Host ("- Meses protegidos: {0}" -f $KEEP_MONTHLY)
if ($RetentionInfo.Policy -ne 'N/A') {
    Write-Host ("- Politica tecnica: {0}" -f $RetentionInfo.Policy) -ForegroundColor DarkCyan
}

Write-Host ''
Write-Host 'RESUMO DA SIMULACAO' -ForegroundColor Cyan
Write-Host '-------------------' -ForegroundColor Cyan
Write-Host ("- Mantidos se a limpeza rodasse agora: {0}" -f $RetentionInfo.KeepCount)
Write-Host ("- Removidos se a limpeza rodasse agora: {0}" -f $RetentionInfo.RemoveCount)
Write-Host ("- Recentes: {0}" -f $Layout.Recent.Count)
Write-Host ("- Semanais extras: {0}" -f $Layout.WeeklyExtras.Count)
Write-Host ("- Mensais extras: {0}" -f $Layout.MonthlyExtras.Count)

Show-SnapshotSection -Title 'RECENTES' -Entries $Layout.Recent -EmptyText 'nenhum snapshot na janela recente'
Show-SnapshotSection -Title 'SEMANAIS EXTRAS' -Entries $Layout.WeeklyExtras -EmptyText 'nenhum snapshot extra preservado pela regra semanal'
Show-SnapshotSection -Title 'MENSAIS EXTRAS' -Entries $Layout.MonthlyExtras -EmptyText 'nenhum snapshot extra preservado pela regra mensal'

if ($Layout.OtherKept.Count -gt 0) {
    Show-SnapshotSection -Title 'OUTROS MANTIDOS' -Entries $Layout.OtherKept -EmptyText 'nenhum item fora das tres camadas principais'
}

exit 0