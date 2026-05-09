#Requires -Version 5.1
<#
.SYNOPSIS
    Envia notificacao via Telegram Bot API com parser inteligente de logs.
.PARAMETER Subject
    Assunto/titulo da mensagem.
.PARAMETER LogFile
    Caminho para arquivo de log a ser incluido no corpo.
.PARAMETER Body
    Texto alternativo (usado se LogFile nao for fornecido).
#>
param(
    [Parameter(Mandatory)][string]$Subject,
    [string]$LogFile = "",
    [string]$Body    = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Carrega configuracao
$TELEGRAM_TOKEN = ''
$TELEGRAM_CHATID = ''
$REPOSITORY = if ($env:RESTIC_REPOSITORY) { $env:RESTIC_REPOSITORY } else { '' }
$ConfigPath = Join-Path $PSScriptRoot "config.ps1"
$ConfigLoadError = ''
if (Test-Path $ConfigPath) {
    try {
        . $ConfigPath
    } catch {
        $ConfigLoadError = $_.Exception.Message
    }
} else {
    $ConfigLoadError = "config.ps1 nao encontrado em: $PSScriptRoot"
}

if (-not [string]::IsNullOrWhiteSpace($ConfigLoadError)) {
    Write-Warning "[TELEGRAM] Configuracao parcial: $ConfigLoadError"
}

$EffectiveTelegramToken = if ($env:RESTIC_TELEGRAM_TOKEN) { $env:RESTIC_TELEGRAM_TOKEN } else { $TELEGRAM_TOKEN }
$EffectiveTelegramChatId = if ($env:RESTIC_TELEGRAM_CHATID) { $env:RESTIC_TELEGRAM_CHATID } else { $TELEGRAM_CHATID }
if ([string]::IsNullOrWhiteSpace($REPOSITORY)) {
    $REPOSITORY = '(nao configurado)'
}

$RawContent = ""
if ($LogFile -and (Test-Path $LogFile)) {
    $RawContent = Get-Content $LogFile -Raw -Encoding UTF8
} elseif ($Body) {
    $RawContent = $Body
}

function Convert-ToHtmlSafe {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    return [System.Security.SecurityElement]::Escape([string]$Text)
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

function Get-RepositoryLocationInfo {
    param([string]$Path)

    $Info = [ordered]@{
        Summary = "Detalhes do destino indisponiveis"
    }

    if ($Path -match '^[A-Za-z]:\\') {
        $Drive = (Split-Path -Path $Path -Qualifier).TrimEnd('\\')
        try {
            $Disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $Drive)
            if ($Disk) {
                $Volume = if ([string]::IsNullOrWhiteSpace($Disk.VolumeName)) { "(sem rotulo)" } else { $Disk.VolumeName }
                $FileSystem = if ([string]::IsNullOrWhiteSpace($Disk.FileSystem)) { "N/A" } else { $Disk.FileSystem }
                $FreeDisplay = Convert-BytesToDisplay -Bytes ([double]$Disk.FreeSpace)
                $SizeDisplay = Convert-BytesToDisplay -Bytes ([double]$Disk.Size)
                $Info.Summary = "$Drive | $Volume | Livre $FreeDisplay de $SizeDisplay | $FileSystem"
            } else {
                $Info.Summary = "$Drive | volume nao localizado"
            }
        } catch {
            $Info.Summary = "$Drive | falha ao consultar volume"
        }
    } elseif ($Path -match '^\\\\') {
        $Info.Summary = "Caminho de rede/UNC"
    } elseif (-not [string]::IsNullOrWhiteSpace($Path)) {
        $Info.Summary = "Caminho sem unidade local identificavel"
    }

    return [pscustomobject]$Info
}

function Get-RegexValue {
    param(
        [string]$Pattern,
        [string]$Default = "N/A",
        [switch]$LastMatch
    )

    if (-not $RawContent) {
        return $Default
    }

    $Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $MatchesFound = [regex]::Matches($RawContent, $Pattern, $Options)
    if ($MatchesFound.Count -eq 0) {
        return $Default
    }

    $Match = if ($LastMatch) { $MatchesFound[$MatchesFound.Count - 1] } else { $MatchesFound[0] }
    if ($Match.Groups.Count -gt 1) {
        return $Match.Groups[1].Value.Trim()
    }

    return $Match.Value.Trim()
}

function Add-UniqueIssue {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Text,
        [int]$MaxCount = 5
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return
    }

    $Normalized = $Text.Trim()
    if ($Normalized.Length -gt 220) {
        $Normalized = $Normalized.Substring(0, 217) + "..."
    }

    if (-not $List.Contains($Normalized) -and $List.Count -lt $MaxCount) {
        $List.Add($Normalized)
    }
}

function Format-CountDisplay {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return "0"
    }

    return ("{0:N0}" -f ([double]$Value))
}

function Get-StatusPresentation {
    param(
        [string]$Subject,
        [bool]$BackupMode,
        [bool]$CheckMode
    )

    if ($Subject -match '\[ERRO\]') {
        return [pscustomobject]@{
            Label  = "[FALHA] ACAO NECESSARIA"
            Detail = if ($BackupMode) {
                "Backup interrompido ou incompleto; revise os pontos de atencao."
            } elseif ($CheckMode) {
                "Verificacao concluida com erro ou problema detectado no repositorio."
            } else {
                "Operacao finalizada com falha."
            }
        }
    }

    if ($Subject -match '\[WARNING\]') {
        return [pscustomobject]@{
            Label  = "[ATENCAO] CONCLUIDO COM AVISOS"
            Detail = if ($BackupMode) {
                "Snapshot salvo, mas houve arquivos nao lidos ou bloqueados durante a execucao."
            } else {
                "Operacao concluida com ocorrencias que merecem revisao."
            }
        }
    }

    return [pscustomobject]@{
        Label  = "[SUCESSO] OPERACAO CONCLUIDA"
        Detail = if ($CheckMode) {
            "Repositorio verificado sem inconsistencias detectadas."
        } else {
            "Operacao finalizada sem alertas relevantes."
        }
    }
}

function Get-DocumentTitle {
    param(
        [string]$Subject,
        [bool]$BackupMode,
        [bool]$CheckMode
    )

    if ($BackupMode) {
        return "RELATORIO DE BACKUP RESTIC"
    }

    if ($CheckMode) {
        return "RELATORIO DE VERIFICACAO RESTIC"
    }

    return $Subject
}

function Get-ChangeBreakdownDisplay {
    param([string]$Label)

    $Pattern = '(?im)^\s+\[\d{2}:\d{2}:\d{2}\]\s+' + [regex]::Escape($Label) + ':\s+(\d+)\s+new,\s+(\d+)\s+changed,\s+(\d+)\s+unmodified\s*$'
    if ($RawContent -match $Pattern) {
        return ("{0} novos | {1} alterados | {2} sem mudanca" -f
            (Format-CountDisplay -Value $Matches[1]),
            (Format-CountDisplay -Value $Matches[2]),
            (Format-CountDisplay -Value $Matches[3]))
    }

    return "N/A"
}

function Get-ColumnSegments {
    param([string]$Line)

    $Content = ($Line -replace '^\s*\[\d{2}:\d{2}:\d{2}\]\s+', '').TrimEnd()
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
        return ""
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

function Get-RetentionLayout {
    param($Entries)

    $Recent = [System.Collections.Generic.List[object]]::new()
    $Extra = [System.Collections.Generic.List[object]]::new()
    $WeeklyMarkedCount = 0
    $MonthlyMarkedCount = 0

    foreach ($Entry in @($Entries)) {
        $IsRecent = Test-SnapshotHasNote -Entry $Entry -Pattern 'last snapshot'
        $IsWeekly = Test-SnapshotHasNote -Entry $Entry -Pattern 'weekly snapshot'
        $IsMonthly = Test-SnapshotHasNote -Entry $Entry -Pattern 'monthly snapshot'

        if ($IsWeekly) {
            $WeeklyMarkedCount++
        }

        if ($IsMonthly) {
            $MonthlyMarkedCount++
        }

        if ($IsRecent) {
            $Recent.Add($Entry)
        } else {
            $Extra.Add($Entry)
        }
    }

    return [pscustomobject]@{
        Recent            = $Recent
        Extra             = $Extra
        WeeklyMarkedCount = $WeeklyMarkedCount
        MonthlyMarkedCount = $MonthlyMarkedCount
    }
}

function Format-RetentionSnapshotLine {
    param($Entry)

    if ($null -eq $Entry) {
        return ''
    }

    $Line = "<code>$(Convert-ToHtmlSafe $Entry.Id)</code> | $(Convert-ToHtmlSafe $Entry.Time)"
    if ($Entry.Size) {
        $Line += " | $(Convert-ToHtmlSafe $Entry.Size)"
    }

    $Notes = Get-SnapshotNotesText -Entry $Entry
    if ($Notes) {
        $Line += " | $(Convert-ToHtmlSafe $Notes)"
    }

    return $Line
}

function Get-RetentionInfo {
    param([string[]]$Lines)

    $Info = [ordered]@{
        Policy      = "N/A"
        Kept        = [System.Collections.Generic.List[object]]::new()
        Removed     = [System.Collections.Generic.List[object]]::new()
        KeepCount   = 0
        RemoveCount = 0
    }

    $Section = ""
    $CurrentKeep = $null

    foreach ($Line in $Lines) {
        if ($Line -match 'Applying Policy:\s+(.*)$') {
            $Info.Policy = $Matches[1].Trim()
            continue
        }

        if ($Line -match '^\s+\[\d{2}:\d{2}:\d{2}\]\s+keep\s+(\d+)\s+snapshots:') {
            $Info.KeepCount = [int]$Matches[1]
            $Section = "Keep"
            $CurrentKeep = $null
            continue
        }

        if ($Line -match '^\s+\[\d{2}:\d{2}:\d{2}\]\s+remove\s+(\d+)\s+snapshots:') {
            $Info.RemoveCount = [int]$Matches[1]
            $Section = "Remove"
            $CurrentKeep = $null
            continue
        }

        if (-not $Section) {
            continue
        }

        $Content = ($Line -replace '^\s*\[\d{2}:\d{2}:\d{2}\]\s+', '').TrimEnd()
        if ([string]::IsNullOrWhiteSpace($Content)) {
            continue
        }

        if ($Content -match '^ID\s+Time' -or $Content -match '^-{5,}$') {
            continue
        }

        if ($Content -match '^\d+\s+snapshots$') {
            $Section = ""
            $CurrentKeep = $null
            continue
        }

        $Segments = @(Get-ColumnSegments -Line $Line)
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

function Get-IssueCategory {
    param([string]$Text)

    $Normalized = if ($null -eq $Text) { "" } else { $Text.ToLowerInvariant() }

    if ($Normalized -match 'acesso negado|access is denied') {
        return 'Acesso negado'
    }

    if ($Normalized -match 'used by another process|outro processo|bloqueou parte do arquivo|lock: read|lock: open|\.lock:') {
        return 'Arquivo em uso/bloqueado'
    }

    if ($Normalized -match 'could not be read|failed to save|openfile for readdirnames failed|failed to open|failed reading|at least one source file could not be read') {
        return 'Leitura parcial/falha ao salvar'
    }

    return 'Outros'
}

function Get-RegexValueFromText {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Default = 'N/A',
        [switch]$LastMatch
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Default
    }

    $Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $MatchesFound = [regex]::Matches($Text, $Pattern, $Options)
    if ($MatchesFound.Count -eq 0) {
        return $Default
    }

    $Match = if ($LastMatch) { $MatchesFound[$MatchesFound.Count - 1] } else { $MatchesFound[0] }
    if ($Match.Groups.Count -gt 1) {
        return $Match.Groups[1].Value.Trim()
    }

    return $Match.Value.Trim()
}

function Convert-SizeTextToBytes {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -eq 'N/A') {
        return $null
    }

    $Match = [regex]::Match($Text, '([0-9]+(?:\.[0-9]+)?)\s*(B|KiB|MiB|GiB|TiB)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $Match.Success) {
        return $null
    }

    $Value = [double]::Parse($Match.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $Multiplier = switch ($Match.Groups[2].Value.ToUpperInvariant()) {
        'B'   { 1 }
        'KIB' { 1024 }
        'MIB' { 1024 * 1024 }
        'GIB' { 1024 * 1024 * 1024 }
        'TIB' { 1024 * 1024 * 1024 * 1024 }
        default { 1 }
    }

    return [double]($Value * $Multiplier)
}

function Convert-DurationTextToSeconds {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text -eq 'N/A') {
        return $null
    }

    if ($Text -match '^(\d+):(\d{2}):(\d{2})$') {
        return ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3]
    }

    if ($Text -match '^(\d+):(\d{2})$') {
        return ([int]$Matches[1] * 60) + [int]$Matches[2]
    }

    return $null
}

function Convert-SecondsToDisplay {
    param([AllowNull()][double]$Seconds)

    if ($null -eq $Seconds) {
        return 'N/A'
    }

    $TimeSpan = [TimeSpan]::FromSeconds([math]::Abs([double]$Seconds))
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($TimeSpan.TotalHours), $TimeSpan.Minutes, $TimeSpan.Seconds)
}

function Convert-SignedSecondsToDisplay {
    param([AllowNull()][double]$Seconds)

    if ($null -eq $Seconds) {
        return 'N/A'
    }

    if ($Seconds -eq 0) {
        return '00:00:00'
    }

    $Prefix = if ($Seconds -gt 0) { '+' } else { '-' }
    return "$Prefix$(Convert-SecondsToDisplay -Seconds $Seconds)"
}

function Convert-SignedCountToDisplay {
    param([AllowNull()][double]$Value)

    if ($null -eq $Value) {
        return 'N/A'
    }

    if ($Value -eq 0) {
        return '0'
    }

    $Prefix = if ($Value -gt 0) { '+' } else { '-' }
    return "$Prefix$(Format-CountDisplay -Value ([math]::Abs($Value)))"
}

function Convert-SignedBytesToDisplay {
    param([AllowNull()][double]$Bytes)

    if ($null -eq $Bytes) {
        return 'N/A'
    }

    if ($Bytes -eq 0) {
        return '0 B'
    }

    $Prefix = if ($Bytes -gt 0) { '+' } else { '-' }
    return "$Prefix$(Convert-BytesToDisplay -Bytes ([math]::Abs($Bytes)))"
}

function Get-IssueApplicationLabel {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'Sistema/Outros'
    }

    $Rules = @(
        @{ Pattern = '(?i)\\BraveSoftware\\Brave-Browser\\'; Label = 'Brave Browser' }
        @{ Pattern = '(?i)\\Google\\Chrome\\'; Label = 'Google Chrome' }
        @{ Pattern = '(?i)\\Microsoft\\Edge\\'; Label = 'Microsoft Edge' }
        @{ Pattern = '(?i)\\uTorrent Web\\'; Label = 'uTorrent Web' }
        @{ Pattern = '(?i)\\BitTorrentHelper\\'; Label = 'BitTorrentHelper' }
        @{ Pattern = '(?i)\\Docker\\'; Label = 'Docker' }
        @{ Pattern = '(?i)\\Comms\\'; Label = 'Comms' }
        @{ Pattern = '(?i)\\Microsoft\\Olk\\'; Label = 'Microsoft Olk' }
        @{ Pattern = '(?i)\\WsiAccount(?:\\|:|$)'; Label = 'WsiAccount' }
    )

    foreach ($Rule in $Rules) {
        if ($Text -match $Rule.Pattern) {
            return $Rule.Label
        }
    }

    if ($Text -match '(?i)\\AppData\\(?:Local|Roaming|LocalLow)\\([^\\:]+)\\([^\\:]+)') {
        $Vendor = $Matches[1]
        $Product = $Matches[2]
        if ($Vendor -match '^(Google|Microsoft|BraveSoftware)$') {
            return ($Product -replace '[-_]+', ' ')
        }
    }

    if ($Text -match '(?i)\\AppData\\(?:Local|Roaming|LocalLow)\\([^\\:]+)') {
        return ($Matches[1] -replace '[-_]+', ' ')
    }

    if ($Text -match '(?i)C:\\Users\\([^\\:]+)(?:\\|:|$)') {
        return ("Perfil {0}" -f $Matches[1])
    }

    return 'Sistema/Outros'
}

function Get-IssueFingerprint {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $Application = Get-IssueApplicationLabel -Text $Text
    $Category = Get-IssueCategory -Text $Text
    $Operation = 'outro'

    if ($Text -match '^(openfile for readdirnames failed|failed to save|failed to open|open)\b') {
        $Operation = $Matches[1].ToLowerInvariant()
    }

    return ('{0}|{1}|{2}' -f $Application.ToLowerInvariant(), $Category.ToLowerInvariant(), $Operation)
}

function Get-IssueRecords {
    param($RegexMatches)

    $Records = [System.Collections.Generic.List[object]]::new()
    foreach ($Match in @($RegexMatches)) {
        $Text = $Match.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($Text)) {
            continue
        }

        $Records.Add([pscustomobject]@{
            Text        = $Text
            Category    = Get-IssueCategory -Text $Text
            Application = Get-IssueApplicationLabel -Text $Text
            Fingerprint = Get-IssueFingerprint -Text $Text
        })
    }

    return @($Records)
}

function Get-BackupLogSummary {
    param(
        [string]$Text,
        [string]$LogName = ''
    )

    $Lines = if ($Text) { $Text -split "`r?`n" } else { @() }
    $Retention = Get-RetentionInfo -Lines $Lines
    $ErrorMatches = if ($Text) {
        [regex]::Matches($Text, '(?im)^\s+\[\d{2}:\d{2}:\d{2}\]\s+error:\s+(.*)$')
    } else {
        @()
    }

    $DurationText = Get-RegexValueFromText -Text $Text -Pattern 'Duracao:\s+(.*)'
    $AddedText = Get-RegexValueFromText -Text $Text -Pattern 'Added to the repository:\s+(.*)'

    return [pscustomobject]@{
        LogName          = $LogName
        DurationText     = $DurationText
        DurationSeconds  = Convert-DurationTextToSeconds -Text $DurationText
        AddedText        = $AddedText
        AddedBytes       = Convert-SizeTextToBytes -Text $AddedText
        WarningCount     = @($ErrorMatches).Count
        RemovedSnapshots = $Retention.RemoveCount
        IssueRecords     = @(Get-IssueRecords -RegexMatches $ErrorMatches)
    }
}

if ([string]::IsNullOrWhiteSpace($EffectiveTelegramToken) -or [string]::IsNullOrWhiteSpace($EffectiveTelegramChatId)) {
    Write-Warning "[TELEGRAM] Token ou ChatID nao configurados."
    exit 1
}

$LogLines = if ($RawContent) { $RawContent -split "`r?`n" } else { @() }

$ExecutionIdentity = try {
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
} catch {
    if ($env:USERNAME) { "$env:USERDOMAIN\$env:USERNAME" } else { "N/A" }
}

$RepositoryInfo = Get-RepositoryLocationInfo -Path $REPOSITORY
$IsBackup = ($Subject -match "Backup")
$IsCheck = ($Subject -match "Check")
$DocumentTitle = Get-DocumentTitle -Subject $Subject -BackupMode:$IsBackup -CheckMode:$IsCheck

$StartTime = Get-RegexValue -Pattern 'Inicio:\s+(.*)'
$EndTime = Get-RegexValue -Pattern 'Fim:\s+(.*)'
$Duration = Get-RegexValue -Pattern 'Duracao:\s+(.*)'
$DurationSeconds = Convert-DurationTextToSeconds -Text $Duration
$DestinationSummary = Get-RegexValue -Pattern '^\[[^\]]+\]\s+\[INFO\]\s+Destino fisico:\s+(.*)$' -Default $RepositoryInfo.Summary -LastMatch
$FreeBefore = Get-RegexValue -Pattern '^\[[^\]]+\]\s+\[INFO\]\s+Espaco livre inicial no destino:\s+(.*)$'
$FreeAfter = Get-RegexValue -Pattern '^\[[^\]]+\]\s+\[INFO\]\s+Espaco livre final no destino:\s+(.*)$'
$FreeDelta = Get-RegexValue -Pattern '^\[[^\]]+\]\s+\[INFO\]\s+Variacao no espaco livre:\s+(.*)$'
$CheckMode = Get-RegexValue -Pattern 'CHECK RESTIC --\s+(.*)' -Default 'N/A'

$Processed = "N/A"
if ($RawContent -match 'processed\s+(\d+)\s+files,\s+(.*?)\s+in') {
    $Processed = "$(Format-CountDisplay -Value $Matches[1]) arquivos ($($Matches[2]))"
}

$Added = Get-RegexValue -Pattern 'Added to the repository:\s+(.*)'
$AddedBytes = Convert-SizeTextToBytes -Text $Added
$Pruned = Get-RegexValue -Pattern 'total prune:\s+.*?/\s+(.*)'
$PruneImmediate = Get-RegexValue -Pattern 'this removes:\s+.*?/\s+(.*)'
$ToRepack = Get-RegexValue -Pattern 'to repack:\s+(.*)'
$SnapshotSaved = Get-RegexValue -Pattern 'snapshot\s+([a-f0-9]+)\s+saved'
$ExitCode = Get-RegexValue -Pattern 'Codigo:\s+(\d+)' -Default 'N/A' -LastMatch
$FilesSummary = Get-ChangeBreakdownDisplay -Label 'Files'
$DirsSummary = Get-ChangeBreakdownDisplay -Label 'Dirs'
$SourceReadWarning = ($RawContent -match '(?im)Warning:\s+at least one source file could not be read')

$RetentionInfo = Get-RetentionInfo -Lines $LogLines
$KeptSnapshots = @($RetentionInfo.Kept)
$RemovedSnapshots = @($RetentionInfo.Removed)
$RetentionLayout = Get-RetentionLayout -Entries $KeptSnapshots
$ConfiguredKeepLast = try { [int]$KEEP_LAST } catch { 0 }
$ConfiguredKeepWeekly = try { [int]$KEEP_WEEKLY } catch { 0 }
$ConfiguredKeepMonthly = try { [int]$KEEP_MONTHLY } catch { 0 }
$LatestRecentSnapshot = if ($RetentionLayout.Recent.Count -gt 0) { $RetentionLayout.Recent[$RetentionLayout.Recent.Count - 1] } else { $null }
$OldestProtectedExtraSnapshot = if ($RetentionLayout.Extra.Count -gt 0) { $RetentionLayout.Extra[0] } else { $null }
$LatestKeptSnapshot = if ($KeptSnapshots.Count -gt 0) { $KeptSnapshots[$KeptSnapshots.Count - 1] } else { $null }
$OldestKeptSnapshot = if ($KeptSnapshots.Count -gt 0) { $KeptSnapshots[0] } else { $null }

$SnapshotWasEmpty = ($RawContent -match '(?im)snapshot is empty')
$RemovedEmptySnapshotMatches = [regex]::Matches($RawContent, '(?im)removed empty snapshot\s+([a-f0-9]+)')
$RemovedEmptySnapshotIds = @($RemovedEmptySnapshotMatches | ForEach-Object { $_.Groups[1].Value })

$Snapshots = "N/A"
if ($RawContent) {
    $SnapshotMatches = [regex]::Matches($RawContent, '(?im)(\d+)\s+snapshots')
    if ($SnapshotMatches.Count -gt 0) {
        $Snapshots = $SnapshotMatches[$SnapshotMatches.Count - 1].Groups[1].Value
    }
}
if ($RetentionInfo.KeepCount -gt 0) {
    $Snapshots = [string]$RetentionInfo.KeepCount
}

$ResticErrorMatches = @()
if ($RawContent) {
    $ResticErrorMatches = [regex]::Matches($RawContent, '(?im)^\s+\[\d{2}:\d{2}:\d{2}\]\s+error:\s+(.*)$')
}
$ResticWarningCount = @($ResticErrorMatches).Count
$IssueRecords = @(Get-IssueRecords -RegexMatches $ResticErrorMatches)

$PreviousBackupSummaries = @()
if ($IsBackup -and $LogFile -and (Test-Path $LOG_DIR) -and (Test-Path $LogFile)) {
    $CurrentLogPath = (Get-Item $LogFile).FullName
    $PreviousLogFiles = @(
        Get-ChildItem -Path $LOG_DIR -Filter 'backup_*.log' -File |
        Sort-Object -Property LastWriteTime -Descending |
        Where-Object { $_.FullName -ne $CurrentLogPath } |
        Select-Object -First 5
    )

    foreach ($PreviousLogFile in $PreviousLogFiles) {
        try {
            $PreviousContent = Get-Content $PreviousLogFile.FullName -Raw -Encoding UTF8
            $PreviousBackupSummaries += Get-BackupLogSummary -Text $PreviousContent -LogName $PreviousLogFile.Name
        } catch { }
    }
}

$PreviousBackupSummary = if ($PreviousBackupSummaries.Count -gt 0) { $PreviousBackupSummaries[0] } else { $null }
$AlertBaselineAvailable = ($PreviousBackupSummaries.Count -gt 0)
$ExpectedFingerprintThreshold = if ($PreviousBackupSummaries.Count -ge 2) {
    2
} elseif ($PreviousBackupSummaries.Count -eq 1) {
    1
} else {
    999
}

$PriorFingerprintRunCounts = @{}
foreach ($HistoricalSummary in $PreviousBackupSummaries) {
    $SeenFingerprints = @{}
    foreach ($IssueRecord in @($HistoricalSummary.IssueRecords)) {
        if ([string]::IsNullOrWhiteSpace($IssueRecord.Fingerprint)) {
            continue
        }

        $SeenFingerprints[$IssueRecord.Fingerprint] = $true
    }

    foreach ($Fingerprint in $SeenFingerprints.Keys) {
        if ($PriorFingerprintRunCounts.ContainsKey($Fingerprint)) {
            $PriorFingerprintRunCounts[$Fingerprint]++
        } else {
            $PriorFingerprintRunCounts[$Fingerprint] = 1
        }
    }
}

$IssueSignatureSummary = @(
    foreach ($SignatureGroup in ($IssueRecords | Group-Object -Property Fingerprint)) {
        $Sample = $SignatureGroup.Group[0]
        $PreviousRuns = if ($PriorFingerprintRunCounts.ContainsKey($SignatureGroup.Name)) {
            $PriorFingerprintRunCounts[$SignatureGroup.Name]
        } else {
            0
        }

        [pscustomobject]@{
            Fingerprint = $SignatureGroup.Name
            Count       = $SignatureGroup.Count
            SampleText  = $Sample.Text
            Application = $Sample.Application
            Category    = $Sample.Category
            PreviousRuns = $PreviousRuns
            IsExpected  = ($AlertBaselineAvailable -and $PreviousRuns -ge $ExpectedFingerprintThreshold)
        }
    }
) | Sort-Object -Property Count -Descending

$ExpectedAlertSummary = @($IssueSignatureSummary | Where-Object { $_.IsExpected })
$NewAlertSummary = @($IssueSignatureSummary | Where-Object { -not $_.IsExpected })
$ExpectedAlertOccurrences = 0
foreach ($ExpectedAlert in $ExpectedAlertSummary) {
    $ExpectedAlertOccurrences += [int]$ExpectedAlert.Count
}

$NewAlertOccurrences = 0
foreach ($NewAlert in $NewAlertSummary) {
    $NewAlertOccurrences += [int]$NewAlert.Count
}

$HasNewAlerts = ($NewAlertSummary.Count -gt 0)
$PrimaryAlertSamples = if ($HasNewAlerts) {
    @($NewAlertSummary | Select-Object -First 3)
} else {
    @($ExpectedAlertSummary | Select-Object -First 3)
}

$AppIssueSummary = @(@(
    foreach ($ApplicationGroup in ($IssueRecords | Group-Object -Property Application)) {
        [pscustomobject]@{
            Application = $ApplicationGroup.Name
            Count       = $ApplicationGroup.Count
        }
    }
) | Sort-Object -Property Count -Descending)

$TopAppsDisplay = if ($AppIssueSummary.Count -gt 0) {
    (@(
        foreach ($Item in ($AppIssueSummary | Select-Object -First 3)) {
            "{0} {1}" -f $Item.Application, (Format-CountDisplay -Value $Item.Count)
        }
    ) -join ' | ')
} else {
    'N/A'
}

$ComparisonDurationDelta = if ($null -ne $PreviousBackupSummary -and $null -ne $DurationSeconds -and $null -ne $PreviousBackupSummary.DurationSeconds) {
    [double]$DurationSeconds - [double]$PreviousBackupSummary.DurationSeconds
} else {
    $null
}

$ComparisonAddedDelta = if ($null -ne $PreviousBackupSummary -and $null -ne $AddedBytes -and $null -ne $PreviousBackupSummary.AddedBytes) {
    [double]$AddedBytes - [double]$PreviousBackupSummary.AddedBytes
} else {
    $null
}

$ComparisonWarningDelta = if ($null -ne $PreviousBackupSummary) {
    [double]$ResticWarningCount - [double]$PreviousBackupSummary.WarningCount
} else {
    $null
}

$ComparisonRemovedDelta = if ($null -ne $PreviousBackupSummary) {
    [double]$RetentionInfo.RemoveCount - [double]$PreviousBackupSummary.RemovedSnapshots
} else {
    $null
}

$StatusInfo = Get-StatusPresentation -Subject $Subject -BackupMode:$IsBackup -CheckMode:$IsCheck
if ($Subject -match '\[WARNING\]' -and $IsBackup) {
    if ($HasNewAlerts) {
        $StatusInfo = [pscustomobject]@{
            Label  = '[ATENCAO] NOVOS ALERTAS DETECTADOS'
            Detail = 'Snapshot salvo, mas surgiram alertas fora do padrao recente.'
        }
    } elseif ($AlertBaselineAvailable -and $ResticWarningCount -gt 0) {
        $StatusInfo = [pscustomobject]@{
            Label  = '[ATENCAO] AVISOS RECORRENTES'
            Detail = 'Snapshot salvo; os avisos observados ja aparecem no historico recente.'
        }
    }
}

$IssueCategoryCounts = @{}
foreach ($IssueRecord in $IssueRecords) {
    $Category = $IssueRecord.Category
    if ($IssueCategoryCounts.ContainsKey($Category)) {
        $IssueCategoryCounts[$Category]++
    } else {
        $IssueCategoryCounts[$Category] = 1
    }
}

$IssueCategorySummary = @(@(
    foreach ($Key in $IssueCategoryCounts.Keys) {
        [pscustomobject]@{
            Category = $Key
            Count    = $IssueCategoryCounts[$Key]
        }
    }
) | Sort-Object -Property Count -Descending)

$IssueLines = [System.Collections.Generic.List[string]]::new()
if ($RawContent) {
    $ScriptIssueMatches = [regex]::Matches($RawContent, '(?im)^\[[^\]]+\]\s+\[(ERROR|WARNING)\]\s+(.*)$')
    foreach ($Match in $ScriptIssueMatches) {
        $Candidate = $Match.Groups[2].Value.Trim()
        if ($Candidate -match 'Backup concluido com avisos|Retencao aplicada e espaco liberado com sucesso|Listagem de snapshots concluida|Repositorio integro') {
            continue
        }

        Add-UniqueIssue -List $IssueLines -Text $Candidate -MaxCount 3
    }

    if ($IssueLines.Count -lt 3) {
        foreach ($Match in $ResticErrorMatches) {
            Add-UniqueIssue -List $IssueLines -Text $Match.Groups[1].Value -MaxCount 3
            if ($IssueLines.Count -ge 3) {
                break
            }
        }
    }
}

$Parts = [System.Collections.Generic.List[string]]::new()
$Parts.Add("<b>$(Convert-ToHtmlSafe $DocumentTitle)</b>`n")
$Parts.Add("<b>$(Convert-ToHtmlSafe $StatusInfo.Label)</b>`n")
$Parts.Add("$(Convert-ToHtmlSafe $StatusInfo.Detail)`n")

$Parts.Add("`n<b>STATUS GERAL</b>`n")
if ($IsBackup) {
    if ($SnapshotSaved -ne 'N/A') {
        $Parts.Add("- <b>Snapshot:</b> <code>$(Convert-ToHtmlSafe $SnapshotSaved)</code> salvo`n")
    } elseif ($SnapshotWasEmpty) {
        $Parts.Add("- <b>Snapshot:</b> <b>vazio</b> (nenhum dado novo elegivel)`n")
    } else {
        $Parts.Add("- <b>Snapshot:</b> nao confirmado no log`n")
    }

    if ($Snapshots -ne 'N/A') {
        $Parts.Add("- <b>Mantidos apos a limpeza:</b> $(Convert-ToHtmlSafe $Snapshots)`n")
    }

    if ($ConfiguredKeepLast -gt 0 -or $ConfiguredKeepWeekly -gt 0 -or $ConfiguredKeepMonthly -gt 0) {
        $Parts.Add("- <b>Camadas configuradas:</b> recentes $(Format-CountDisplay -Value $ConfiguredKeepLast) | semanas $(Format-CountDisplay -Value $ConfiguredKeepWeekly) | meses $(Format-CountDisplay -Value $ConfiguredKeepMonthly)`n")
    }

    if ($RetentionInfo.RemoveCount -gt 0) {
        $Parts.Add("- <b>Retencao:</b> $(Format-CountDisplay -Value $RetentionInfo.RemoveCount) snapshot(s) removido(s)`n")
    } elseif ($RetentionInfo.Policy -ne 'N/A' -or $Pruned -ne 'N/A') {
        $Parts.Add("- <b>Retencao:</b> nenhum snapshot removido`n")
    }

    if ($Pruned -ne 'N/A') {
        $Parts.Add("- <b>Prune total:</b> $(Convert-ToHtmlSafe $Pruned)`n")
    }

    if ($ResticWarningCount -gt 0) {
        $Parts.Add("- <b>Ocorrencias Restic:</b> $(Format-CountDisplay -Value $ResticWarningCount)`n")
    }

    if ($ResticWarningCount -gt 0) {
        if ($AlertBaselineAvailable) {
            $Parts.Add("- <b>Novos vs historico:</b> $(Format-CountDisplay -Value $NewAlertOccurrences) nova(s) | $(Format-CountDisplay -Value $ExpectedAlertOccurrences) recorrente(s)`n")
        } else {
            $Parts.Add("- <b>Baseline de alertas:</b> ainda sem execucao anterior para comparar`n")
        }
    }

    if ($RemovedEmptySnapshotIds.Count -gt 0) {
        $Parts.Add("- <b>Snapshots vazios removidos:</b> $(Format-CountDisplay -Value $RemovedEmptySnapshotIds.Count)`n")
    } else {
        $Parts.Add("- <b>Snapshot vazio:</b> nao detectado`n")
    }

    if ($ExitCode -ne 'N/A' -and $Subject -match '\[WARNING\]|\[ERRO\]') {
        $Parts.Add("- <b>Codigo Restic:</b> $(Convert-ToHtmlSafe $ExitCode)`n")
    }
} elseif ($IsCheck) {
    if ($CheckMode -ne 'N/A') {
        $Parts.Add("- <b>Modo:</b> $(Convert-ToHtmlSafe $CheckMode)`n")
    }
    if ($Duration -ne 'N/A') {
        $Parts.Add("- <b>Duracao:</b> $(Convert-ToHtmlSafe $Duration)`n")
    }
    if ($ResticWarningCount -gt 0) {
        $Parts.Add("- <b>Ocorrencias Restic:</b> $(Format-CountDisplay -Value $ResticWarningCount)`n")
    }
    if ($ExitCode -ne 'N/A' -and $Subject -match '\[ERRO\]|\[WARNING\]') {
        $Parts.Add("- <b>Codigo:</b> $(Convert-ToHtmlSafe $ExitCode)`n")
    }
}

$Parts.Add("`n<b>EXECUCAO</b>`n")
$Parts.Add("- <b>Host:</b> <code>$(Convert-ToHtmlSafe $env:COMPUTERNAME)</code>`n")
$Parts.Add("- <b>Conta:</b> <code>$(Convert-ToHtmlSafe $ExecutionIdentity)</code>`n")
if ($StartTime -ne 'N/A') {
    $Parts.Add("- <b>Inicio:</b> $(Convert-ToHtmlSafe $StartTime)`n")
}
if ($EndTime -ne 'N/A') {
    $Parts.Add("- <b>Fim:</b> $(Convert-ToHtmlSafe $EndTime)`n")
}
if ($Duration -ne 'N/A') {
    $Parts.Add("- <b>Duracao:</b> $(Convert-ToHtmlSafe $Duration)`n")
}

$Parts.Add("`n<b>DESTINO</b>`n")
$Parts.Add("- <b>Repositorio:</b> <code>$(Convert-ToHtmlSafe $REPOSITORY)</code>`n")
$Parts.Add("- <b>Disco:</b> $(Convert-ToHtmlSafe $DestinationSummary)`n")
if ($FreeBefore -ne 'N/A') {
    $Parts.Add("- <b>Espaco livre inicial:</b> $(Convert-ToHtmlSafe $FreeBefore)`n")
}
if ($FreeAfter -ne 'N/A') {
    $Parts.Add("- <b>Espaco livre final:</b> $(Convert-ToHtmlSafe $FreeAfter)`n")
}
if ($FreeDelta -ne 'N/A') {
    $Parts.Add("- <b>Variacao:</b> $(Convert-ToHtmlSafe $FreeDelta)`n")
}
if ($IsBackup) {
    $Parts.Add("- <b>Fontes:</b> <code>$(Convert-ToHtmlSafe ($BACKUP_SOURCES -join '; '))</code>`n")
}
if ($LogFile) {
    $Parts.Add("- <b>Log:</b> <code>$(Convert-ToHtmlSafe $LogFile)</code>`n")
}

if ($IsBackup) {
    $Parts.Add("`n<b>BACKUP</b>`n")
    if ($Processed -ne 'N/A') {
        $Parts.Add("- <b>Processado:</b> $(Convert-ToHtmlSafe $Processed)`n")
    }
    if ($FilesSummary -ne 'N/A') {
        $Parts.Add("- <b>Arquivos:</b> $(Convert-ToHtmlSafe $FilesSummary)`n")
    }
    if ($DirsSummary -ne 'N/A') {
        $Parts.Add("- <b>Diretorios:</b> $(Convert-ToHtmlSafe $DirsSummary)`n")
    }
    if ($Added -ne 'N/A') {
        $Parts.Add("- <b>Enviado ao repositorio:</b> $(Convert-ToHtmlSafe $Added)`n")
    }
    if ($SourceReadWarning) {
        $Parts.Add("- <b>Leitura parcial detectada:</b> sim`n")
    }

    if ($null -ne $PreviousBackupSummary) {
        $Parts.Add("`n<b>COMPARATIVO</b>`n")
        $Parts.Add("- <b>Base:</b> <code>$(Convert-ToHtmlSafe $PreviousBackupSummary.LogName)</code>`n")
        if ($Duration -ne 'N/A' -and $PreviousBackupSummary.DurationText -ne 'N/A') {
            $Parts.Add("- <b>Duracao:</b> $(Convert-ToHtmlSafe $Duration) | delta $(Convert-ToHtmlSafe (Convert-SignedSecondsToDisplay -Seconds $ComparisonDurationDelta))`n")
        }
        if ($Added -ne 'N/A' -and $PreviousBackupSummary.AddedText -ne 'N/A') {
            $Parts.Add("- <b>Enviado:</b> $(Convert-ToHtmlSafe $Added) | delta $(Convert-ToHtmlSafe (Convert-SignedBytesToDisplay -Bytes $ComparisonAddedDelta))`n")
        }
        $Parts.Add("- <b>Snapshots removidos:</b> $(Format-CountDisplay -Value $RetentionInfo.RemoveCount) | delta $(Convert-ToHtmlSafe (Convert-SignedCountToDisplay -Value $ComparisonRemovedDelta))`n")
        $Parts.Add("- <b>Ocorrencias Restic:</b> $(Format-CountDisplay -Value $ResticWarningCount) | delta $(Convert-ToHtmlSafe (Convert-SignedCountToDisplay -Value $ComparisonWarningDelta))`n")
    }

    if ($RetentionInfo.Policy -ne 'N/A' -or $RetentionInfo.KeepCount -gt 0 -or $RetentionInfo.RemoveCount -gt 0 -or $Pruned -ne 'N/A') {
        $Parts.Add("`n<b>RETENCAO</b>`n")
        if ($ConfiguredKeepLast -gt 0 -or $ConfiguredKeepWeekly -gt 0 -or $ConfiguredKeepMonthly -gt 0) {
            $Parts.Add("- <b>Configurado:</b> ultimos $(Format-CountDisplay -Value $ConfiguredKeepLast) snapshot(s) | semanas $(Format-CountDisplay -Value $ConfiguredKeepWeekly) | meses $(Format-CountDisplay -Value $ConfiguredKeepMonthly)`n")
        }
        if ($RetentionInfo.Policy -ne 'N/A') {
            $Parts.Add("- <b>Politica tecnica:</b> $(Convert-ToHtmlSafe $RetentionInfo.Policy)`n")
        }
        if ($Snapshots -ne 'N/A') {
            $Parts.Add("- <b>Mantidos apos a limpeza:</b> $(Convert-ToHtmlSafe $Snapshots)`n")
        }
        if ($RetentionLayout.Recent.Count -gt 0) {
            $Parts.Add("- <b>Dentro da janela recente:</b> $(Format-CountDisplay -Value $RetentionLayout.Recent.Count)`n")
        }
        if ($RetentionLayout.WeeklyMarkedCount -gt 0 -or $ConfiguredKeepWeekly -gt 0) {
            $Parts.Add("- <b>Marcados pela regra semanal:</b> $(Format-CountDisplay -Value $RetentionLayout.WeeklyMarkedCount)`n")
        }
        if ($RetentionLayout.MonthlyMarkedCount -gt 0 -or $ConfiguredKeepMonthly -gt 0) {
            $Parts.Add("- <b>Marcados pela regra mensal:</b> $(Format-CountDisplay -Value $RetentionLayout.MonthlyMarkedCount)`n")
        }
        if ($RetentionLayout.Extra.Count -gt 0) {
            $Parts.Add("- <b>Extras preservados por semana/mes:</b> $(Format-CountDisplay -Value $RetentionLayout.Extra.Count)`n")
        } elseif ($ConfiguredKeepWeekly -gt 0 -or $ConfiguredKeepMonthly -gt 0) {
            $Parts.Add("- <b>Extras preservados por semana/mes:</b> nenhum nesta execucao; a janela recente ja cobriu essas camadas`n")
        }
        if ($null -ne $LatestRecentSnapshot) {
            $Parts.Add("- <b>Mais novo na janela recente:</b> $(Format-RetentionSnapshotLine -Entry $LatestRecentSnapshot)`n")
        } elseif ($null -ne $LatestKeptSnapshot) {
            $Parts.Add("- <b>Mais novo mantido:</b> $(Format-RetentionSnapshotLine -Entry $LatestKeptSnapshot)`n")
        }
        if ($null -ne $OldestProtectedExtraSnapshot) {
            $Parts.Add("- <b>Mais antigo ainda protegido fora da janela recente:</b> $(Format-RetentionSnapshotLine -Entry $OldestProtectedExtraSnapshot)`n")
        }
        if ($null -ne $OldestKeptSnapshot -and $null -ne $LatestKeptSnapshot -and $OldestKeptSnapshot.Id -ne $LatestKeptSnapshot.Id -and $null -eq $OldestProtectedExtraSnapshot) {
            $Parts.Add("- <b>Mais antigo mantido:</b> $(Format-RetentionSnapshotLine -Entry $OldestKeptSnapshot)`n")
        }
        if ($RetentionInfo.RemoveCount -gt 0) {
            $Parts.Add("- <b>Removidos:</b> $(Format-CountDisplay -Value $RetentionInfo.RemoveCount)`n")
            foreach ($RemovedSnapshot in ($RemovedSnapshots | Select-Object -First 3)) {
                $RemovedLine = "<code>$(Convert-ToHtmlSafe $RemovedSnapshot.Id)</code> | $(Convert-ToHtmlSafe $RemovedSnapshot.Time)"
                if ($RemovedSnapshot.Size) {
                    $RemovedLine += " | $(Convert-ToHtmlSafe $RemovedSnapshot.Size)"
                }
                if ($RemovedSnapshot.Path) {
                    $RemovedLine += " | $(Convert-ToHtmlSafe $RemovedSnapshot.Path)"
                }
                $Parts.Add("- $RemovedLine`n")
            }
            if ($RemovedSnapshots.Count -gt 3) {
                $Parts.Add("- Outros removidos: $(Format-CountDisplay -Value ($RemovedSnapshots.Count - 3))`n")
            }
        } else {
            $Parts.Add("- <b>Removidos:</b> nenhum snapshot`n")
        }
        if ($PruneImmediate -ne 'N/A') {
            $Parts.Add("- <b>Espaco liberado no prune:</b> $(Convert-ToHtmlSafe $PruneImmediate)`n")
        }
        if ($Pruned -ne 'N/A') {
            $Parts.Add("- <b>Prune total:</b> $(Convert-ToHtmlSafe $Pruned)`n")
        }
        if ($ToRepack -ne 'N/A') {
            $Parts.Add("- <b>Repack:</b> $(Convert-ToHtmlSafe $ToRepack)`n")
        }
        if ($RemovedEmptySnapshotIds.Count -gt 0) {
            $Parts.Add("- <b>Snapshots vazios removidos:</b> <code>$(Convert-ToHtmlSafe (($RemovedEmptySnapshotIds | Select-Object -First 3) -join ', '))</code>`n")
        } elseif ($SnapshotWasEmpty) {
            $Parts.Add("- <b>Snapshot vazio:</b> detectado nesta execucao`n")
        } else {
            $Parts.Add("- <b>Snapshot vazio:</b> nao detectado`n")
        }
    }
} elseif ($IsCheck) {
    $Parts.Add("`n<b>VERIFICACAO</b>`n")
    if ($CheckMode -ne 'N/A') {
        $Parts.Add("- <b>Modo:</b> $(Convert-ToHtmlSafe $CheckMode)`n")
    }
    if ($Snapshots -ne 'N/A') {
        $Parts.Add("- <b>Snapshots observados:</b> $(Convert-ToHtmlSafe $Snapshots)`n")
    }
}

if ($Subject -match '\[ERRO\]|\[WARNING\]' -or $ResticWarningCount -gt 0 -or $IssueLines.Count -gt 0) {
    $Parts.Add("`n<b>PONTOS DE ATENCAO</b>`n")
    if ($ResticWarningCount -gt 0) {
        if ($AlertBaselineAvailable) {
            $Parts.Add("- <b>Historico recente:</b> $(Format-CountDisplay -Value $PreviousBackupSummaries.Count) execucao(oes) usada(s) como referencia`n")
            $Parts.Add("- <b>Assinaturas de alerta:</b> $(Format-CountDisplay -Value $NewAlertSummary.Count) nova(s) | $(Format-CountDisplay -Value $ExpectedAlertSummary.Count) conhecida(s)`n")
        } else {
            $Parts.Add("- <b>Historico recente:</b> indisponivel; esta e a primeira comparacao automatica`n")
        }
    }

    if ($AppIssueSummary.Count -gt 0) {
        $Parts.Add("- <b>Apps mais afetados:</b> $(Convert-ToHtmlSafe $TopAppsDisplay)`n")
    }

    if ($IssueCategorySummary.Count -gt 0) {
        $CategoryLine = @(
            foreach ($Item in ($IssueCategorySummary | Select-Object -First 3)) {
                "$(Format-CountDisplay -Value $Item.Count) $($Item.Category)"
            }
        ) -join ' | '
        $Parts.Add("- <b>Categorias:</b> $(Convert-ToHtmlSafe $CategoryLine)`n")
    }

    if ($PrimaryAlertSamples.Count -gt 0) {
        $AlertPrefix = if ($HasNewAlerts) { 'Novo' } else { 'Recorrente' }
        foreach ($AlertSample in $PrimaryAlertSamples) {
            $Parts.Add("- <b>${AlertPrefix}:</b> $(Convert-ToHtmlSafe $AlertSample.SampleText)`n")
        }
    } elseif ($IssueLines.Count -gt 0) {
        foreach ($Issue in $IssueLines) {
            $Parts.Add("- $(Convert-ToHtmlSafe $Issue)`n")
        }
    } elseif ($ResticWarningCount -gt 0) {
        $Parts.Add("- Houve ocorrencias reportadas pelo Restic, mas sem amostras resumidas no parser.`n")
    } else {
        $Parts.Add("- Verifique o log completo para detalhes adicionais.`n")
    }
} else {
    $Parts.Add("`n<b>SAUDE</b>`n")
    $Parts.Add("- Sem alertas relevantes nesta execucao.`n")
}

$HtmlMessage = $Parts.ToArray() -join ''
$WasTrimmed = $false
while ($HtmlMessage.Length -gt 3900 -and $Parts.Count -gt 0) {
    $Parts.RemoveAt($Parts.Count - 1)
    $WasTrimmed = $true
    $HtmlMessage = $Parts.ToArray() -join ''
}

if ($WasTrimmed) {
    $Parts.Add("`n<i>Resumo encurtado para caber no Telegram.</i>")
    $HtmlMessage = $Parts.ToArray() -join ''
    while ($HtmlMessage.Length -gt 4000 -and $Parts.Count -gt 0) {
        $Parts.RemoveAt($Parts.Count - 1)
        $HtmlMessage = $Parts.ToArray() -join ''
    }
}

$Uri = "https://api.telegram.org/bot$EffectiveTelegramToken/sendMessage"
$Payload = @{
    chat_id    = $EffectiveTelegramChatId
    text       = $HtmlMessage
    parse_mode = "HTML"
} | ConvertTo-Json -Compress

try {
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    Invoke-RestMethod -Uri $Uri -Method Post `
        -ContentType "application/json; charset=utf-8" `
        -Body $Bytes | Out-Null
    Write-Host "[TELEGRAM] Notificacao formatada enviada com sucesso."
} catch {
    Write-Warning "[TELEGRAM] Falha ao enviar: $($_.Exception.Message)"
    try {
        $FallbackPayload = @{
            chat_id = $EffectiveTelegramChatId
            text    = "Falha no HTML. Resumo minimo enviado. `n`n$Subject`nRepositorio: $REPOSITORY`nDisco: $($RepositoryInfo.Summary)"
        } | ConvertTo-Json -Compress
        $FallbackBytes = [System.Text.Encoding]::UTF8.GetBytes($FallbackPayload)
        Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json; charset=utf-8" -Body $FallbackBytes | Out-Null
    } catch { }
    exit 1
}