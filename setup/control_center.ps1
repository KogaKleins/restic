#Requires -Version 5.1
<#
.SYNOPSIS
    Centro de controle interativo do Restic por menu.
.DESCRIPTION
    Interface guiada em terminal para gerenciar variaveis RESTIC_*,
    perfis, agendamento e operacoes rapidas sem editar scripts manualmente.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvHelperScript = Join-Path $PSScriptRoot 'env_helper.ps1'
$ShowScript = Join-Path $PSScriptRoot 'show_env.ps1'
$SetupScript = Join-Path $PSScriptRoot 'setup_env.ps1'
$RegisterTasksScript = Join-Path $PSScriptRoot 'register_tasks.ps1'
$BackupNowBat = Join-Path $ProjectRoot 'ativar_agora.bat'
$BackupTaskBat = Join-Path $ProjectRoot 'backup.bat'
$CheckTaskBat = Join-Path $ProjectRoot 'check.bat'
$ExternalSyncBat = Join-Path $ProjectRoot 'sincronizar_externo.bat'
$RetentionLayoutScript = Join-Path $ProjectRoot 'tools\show_retention_layout.ps1'
$RestoreScript = Join-Path $ProjectRoot 'tools\restore_snapshot.ps1'
$ExportSnapshotsScript = Join-Path $ProjectRoot 'tools\export_active_snapshots.ps1'
$ExternalDiskTransferScript = Join-Path $ProjectRoot 'tools\external_disk_transfer.ps1'
$ProfilesFile = Join-Path $ProjectRoot 'runtime\secrets\config-profiles.json'
$CancelKeywords = @('v', 'voltar', 'c', 'cancelar', 'sair')

foreach ($Required in @($EnvHelperScript, $ShowScript, $SetupScript, $RegisterTasksScript)) {
    if (-not (Test-Path -LiteralPath $Required)) {
        throw "Arquivo obrigatorio nao encontrado: $Required"
    }
}

function Read-MenuPause {
    Write-Host ''
    Read-Host 'Pressione Enter para voltar ao menu' | Out-Null
}

function Show-FlowHeader {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Goal,
        [string[]]$Bullets = @(),
        [switch]$ClearScreen
    )

    if ($ClearScreen) {
        Clear-Host
    }

    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host (" {0}" -f $Title) -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host $Goal -ForegroundColor DarkCyan

    if ($Bullets.Count -gt 0) {
        Write-Host ''
        foreach ($Bullet in $Bullets) {
            Write-Host ("- {0}" -f $Bullet)
        }
    }

    Write-Host ''
}

function Show-KeyValueSummary {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][hashtable]$Pairs
    )

    Write-Host $Title -ForegroundColor Cyan
    foreach ($Key in $Pairs.Keys) {
        Write-Host ("- {0}: {1}" -f $Key, $Pairs[$Key])
    }
    Write-Host ''
}

function Show-InputTips {
    param([string]$ExtraHint = '')

    Write-Host 'Dica: Enter mantem o valor atual. Digite "voltar" para cancelar.' -ForegroundColor DarkCyan
    if (-not [string]::IsNullOrWhiteSpace($ExtraHint)) {
        Write-Host $ExtraHint -ForegroundColor DarkCyan
    }
    Write-Host ''
}

function Get-ComparableText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $Decomposed = $Text.Trim().ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $Builder = New-Object System.Text.StringBuilder
    foreach ($Character in $Decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($Character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$Builder.Append($Character)
        }
    }

    return $Builder.ToString().Normalize([Text.NormalizationForm]::FormC)
}

function Test-CancelKeyword {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return $false
    }

    $Normalized = $Value.Trim().ToLowerInvariant()
    return $Normalized -in $CancelKeywords
}

function Stop-IfCancelled {
    param([AllowNull()][string]$Value)

    if (Test-CancelKeyword -Value $Value) {
        throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
    }
}

function Get-ScopedSetting {
    param([Parameter(Mandatory)][string]$Name)

    foreach ($CurrentScope in @('Process', 'User', 'Machine')) {
        $Value = [Environment]::GetEnvironmentVariable($Name, $CurrentScope)
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return [pscustomobject]@{
                Name  = $Name
                Scope = $CurrentScope
                Value = $Value.Trim()
            }
        }
    }

    return [pscustomobject]@{
        Name  = $Name
        Scope = '(nao definido)'
        Value = ''
    }
}

function Get-EffectiveValue {
    param([Parameter(Mandatory)][string]$Name)

    return (Get-ScopedSetting -Name $Name).Value
}

function Get-DefaultWritableScope {
    param([Parameter(Mandatory)][string[]]$Names)

    foreach ($Name in $Names) {
        $Setting = Get-ScopedSetting -Name $Name
        if ($Setting.Scope -in @('User', 'Machine')) {
            return $Setting.Scope
        }
    }

    return 'User'
}

function Get-MaskedToken {
    param([AllowEmptyString()][string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return '(nao configurado)'
    }

    if ($Token.Length -le 8) {

    function Get-RestoreStatusLabel {
        param([AllowNull()][string]$RawStatus)

        switch ((Get-ComparableText -Text $RawStatus)) {
            'completed' { return 'concluido com sucesso' }
            'incomplete' { return 'incompleto ou interrompido' }
            'running' { return 'em andamento ou interrompido sem fechamento' }
            default {
                if ([string]::IsNullOrWhiteSpace($RawStatus)) {
                    return 'desconhecido'
                }

                return $RawStatus.Trim()
            }
        }
    }

    function Get-RestoreStatusInfo {
        param([Parameter(Mandatory)][string]$TargetPath)

        $StatusFilePath = Join-Path $TargetPath '_restore_status.txt'
        if (-not (Test-Path -LiteralPath $StatusFilePath)) {
            return $null
        }

        $Values = @{}
        foreach ($Line in @(Get-Content -LiteralPath $StatusFilePath -Encoding UTF8 -ErrorAction Stop)) {
            if ($Line -match '^\s*([^=]+)=(.*)$') {
                $Values[$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }

        return [pscustomobject]@{
            StatusFilePath = $StatusFilePath
            Status         = $Values['status']
            Timestamp      = $Values['timestamp']
            Snapshot       = $Values['snapshot']
            Verified       = $Values['verified']
            ExitCode       = $Values['exit_code']
            Details        = $Values['details']
        }
    }
        return '********'
    }

    return '{0}...{1}' -f $Token.Substring(0, 4), $Token.Substring($Token.Length - 4)
}

function Get-CurrentConfig {
    $SourcesRaw = Get-EffectiveValue -Name 'RESTIC_BACKUP_SOURCES'
    $ExcludesRaw = Get-EffectiveValue -Name 'RESTIC_BACKUP_EXCLUDES'

    $KeepLastParsed = 7
    $KeepWeeklyParsed = 4
    $KeepMonthlyParsed = 3
    $LogKeepDaysParsed = 30

    [void][int]::TryParse((Get-EffectiveValue -Name 'RESTIC_KEEP_LAST'), [ref]$KeepLastParsed)
    [void][int]::TryParse((Get-EffectiveValue -Name 'RESTIC_KEEP_WEEKLY'), [ref]$KeepWeeklyParsed)
    [void][int]::TryParse((Get-EffectiveValue -Name 'RESTIC_KEEP_MONTHLY'), [ref]$KeepMonthlyParsed)
    [void][int]::TryParse((Get-EffectiveValue -Name 'RESTIC_LOG_KEEP_DAYS'), [ref]$LogKeepDaysParsed)

    return [ordered]@{
        ResticExe      = Get-EffectiveValue -Name 'RESTIC_EXE'
        Repository     = Get-EffectiveValue -Name 'RESTIC_REPOSITORY'
        SecretFilePath = Get-EffectiveValue -Name 'RESTIC_PASSWORD_FILE'
        LogDir         = Get-EffectiveValue -Name 'RESTIC_LOG_DIR'
        LogKeepDays    = $LogKeepDaysParsed
        ExportRepository = Get-EffectiveValue -Name 'RESTIC_EXPORT_REPOSITORY'
        ExportPasswordFile = Get-EffectiveValue -Name 'RESTIC_EXPORT_PASSWORD_FILE'
        TelegramToken  = Get-EffectiveValue -Name 'RESTIC_TELEGRAM_TOKEN'
        TelegramChatId = Get-EffectiveValue -Name 'RESTIC_TELEGRAM_CHATID'
        KeepLast       = $KeepLastParsed
        KeepWeekly     = $KeepWeeklyParsed
        KeepMonthly    = $KeepMonthlyParsed
        BackupSources  = @($SourcesRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        BackupExcludes = @($ExcludesRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
}

function Read-Text {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$AllowEmpty,
        [switch]$AllowClear
    )

    while ($true) {
        $Suffix = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
        $Raw = Read-Host ($Prompt + $Suffix)
        Stop-IfCancelled -Value $Raw

        if ($AllowClear -and $null -ne $Raw -and $Raw.Trim() -eq '-') {
            return ''
        }

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            if (-not [string]::IsNullOrWhiteSpace($Default)) {
                return $Default
            }

            if ($AllowEmpty) {
                return ''
            }

            Write-Warning 'Este campo e obrigatorio.'
            continue
        }

        return $Raw.Trim()
    }
}

function Read-Number {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$Default,
        [int]$MinValue = 0
    )

    while ($true) {
        $Raw = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
        Stop-IfCancelled -Value $Raw

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $Default
        }

        $Parsed = 0
        if ([int]::TryParse($Raw, [ref]$Parsed) -and $Parsed -ge $MinValue) {
            return $Parsed
        }

        Write-Warning "Informe um inteiro >= $MinValue."
    }
}

function Read-TimeText {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Default
    )

    while ($true) {
        $Raw = Read-Text -Prompt $Prompt -Default $Default
        try {
            foreach ($Format in @('H:mm', 'HH:mm')) {
                $Parsed = [datetime]::MinValue
                if ([datetime]::TryParseExact($Raw, $Format, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$Parsed)) {
                    return $Parsed.ToString('HH:mm')
                }
            }
        } catch {
        }

        Write-Warning 'Horario invalido. Use HH:mm.'
    }
}

function Read-ScopeChoice {
    param(
        [string]$Current = 'User',
        [string]$Reason = 'esta configuracao',
        [string]$Recommendation = 'User'
    )

    Write-Host ''
    Write-Host 'Onde salvar esta alteracao?' -ForegroundColor Cyan
    Write-Host ("- User: grava somente para o usuario atual ({0})." -f $env:USERNAME)
    Write-Host '- Machine: grava para toda a maquina e costuma ser usado quando a tarefa roda em outra conta ou em SYSTEM.'
    Write-Host ("- Isso vale para: {0}." -f $Reason) -ForegroundColor DarkCyan
    Write-Host ("- Recomendado aqui: {0}." -f $Recommendation) -ForegroundColor DarkCyan
    Write-Host ''

    while ($true) {
        $Raw = Read-Host ("Escolha o escopo final [User/Machine] [{0}]" -f $Current)
        Stop-IfCancelled -Value $Raw

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $Current
        }

        switch ($Raw.Trim().ToLowerInvariant()) {
            'user' { return 'User' }
            'machine' { return 'Machine' }
            default { Write-Warning 'Escolha User ou Machine.' }
        }
    }
}

function Read-YesNo {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$Default = $true
    )

    $DefaultLabel = if ($Default) { 'S' } else { 'N' }
    while ($true) {
        $Raw = Read-Host ("{0} [S/N] ({1})" -f $Prompt, $DefaultLabel)
        Stop-IfCancelled -Value $Raw

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $Default
        }

        switch ($Raw.Trim().ToUpperInvariant()) {
            'S' { return $true }
            'Y' { return $true }
            'N' { return $false }
            default { Write-Warning 'Digite S ou N.' }
        }
    }
}

function Read-SecretValue {
    param([Parameter(Mandatory)][string]$Prompt)

    while ($true) {
        $Secure = Read-Host $Prompt -AsSecureString
        $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try {
            $Plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
        }

        if (Test-CancelKeyword -Value $Plain) {
            throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
        }

        if (-not [string]::IsNullOrWhiteSpace($Plain)) {
            return $Secure
        }

        Write-Warning 'Senha nao pode ficar vazia.'
    }
}

function Get-ExternalDiskTransferLayout {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$ExternalFolderPath
    )

    $Normalized = $DriveLetter.Trim().TrimEnd(':', '\').ToUpperInvariant()
    if ($Normalized -notmatch '^[A-Z]$') {
        throw "Letra de unidade invalida: $DriveLetter"
    }

    $NormalizedExternalFolderPath = $ExternalFolderPath.Trim().TrimStart('\').TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($NormalizedExternalFolderPath)) {
        throw 'Informe uma pasta valida para o disco externo.'
    }
    if ($NormalizedExternalFolderPath -match '^[A-Za-z]:') {
        throw 'A pasta do disco externo deve ser relativa a unidade escolhida.'
    }

    $DriveRoot = '{0}:\' -f $Normalized
    $ExternalRoot = Join-Path $DriveRoot $NormalizedExternalFolderPath

    return [pscustomobject]@{
        DriveLetter        = $Normalized
        DriveRoot          = $DriveRoot
        ExternalFolderPath = $NormalizedExternalFolderPath
        ExternalRoot       = $ExternalRoot
        RepositoryPath     = Join-Path $ExternalRoot 'repo'
        RecoveryKitPath    = Join-Path $ExternalRoot 'kit'
        RestoreStagingPath = Join-Path $ExternalRoot 'restore-staging'
    }
}

function Get-ExternalDiskCandidates {
    if (-not (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        throw 'O cmdlet Get-Disk nao esta disponivel neste Windows.'
    }
    if (-not (Get-Command Get-Partition -ErrorAction SilentlyContinue)) {
        throw 'O cmdlet Get-Partition nao esta disponivel neste Windows.'
    }
    if (-not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        throw 'O cmdlet Get-Volume nao esta disponivel neste Windows.'
    }

    $AllowedBusTypes = @('USB', 'SD', 'MMC', 'FireWire', 'Unknown')
    $Candidates = @()

    foreach ($Disk in (Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' -and $_.BusType.ToString() -in $AllowedBusTypes })) {
        $Partitions = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
        foreach ($Partition in $Partitions) {
            $Volume = $Partition | Get-Volume -ErrorAction SilentlyContinue
            if ($null -eq $Volume) {
                continue
            }

            $Candidates += [pscustomobject]@{
                DiskNumber   = $Disk.Number
                FriendlyName = [string]$Disk.FriendlyName
                BusType      = [string]$Disk.BusType
                DriveLetter  = [string]$Partition.DriveLetter
                DriveRoot    = ('{0}:\' -f [string]$Partition.DriveLetter)
                FileSystem   = [string]$Volume.FileSystem
                VolumeLabel  = [string]$Volume.FileSystemLabel
                SizeGB       = [math]::Round(($Partition.Size / 1GB), 2)
            }
        }
    }

    return @($Candidates | Sort-Object DriveLetter)
}

function Select-ExternalDiskCandidate {
    param(
        [Parameter(Mandatory)][object[]]$Candidates,
        [Parameter(Mandatory)][ValidateSet('Initial', 'Weekly', 'RestoreAll')][string]$Mode
    )

    if ($Candidates.Count -eq 0) {
        throw 'Nenhum disco externo USB com letra de unidade foi encontrado.'
    }

    Write-Host ''
    Write-Host 'Discos externos detectados:' -ForegroundColor Cyan
    for ($Index = 0; $Index -lt $Candidates.Count; $Index++) {
        $Candidate = $Candidates[$Index]
        $LabelText = if ([string]::IsNullOrWhiteSpace($Candidate.VolumeLabel)) { '(sem rotulo)' } else { $Candidate.VolumeLabel }
        $FileSystemText = if ([string]::IsNullOrWhiteSpace($Candidate.FileSystem)) { '(sem FS)' } else { $Candidate.FileSystem }
        Write-Host ("[{0}] {1} | {2} GB | {3} | {4} | disco {5} {6}" -f ($Index + 1), $Candidate.DriveRoot, $Candidate.SizeGB, $FileSystemText, $LabelText, $Candidate.DiskNumber, $Candidate.FriendlyName)
    }
    Write-Host '[0] Voltar'

    while ($true) {
        $ActionLabel = switch ($Mode) {
            'Initial' { 'inicial' }
            'Weekly' { 'semanal' }
            'RestoreAll' { 'de restore completo' }
        }

        $Raw = Read-Host ("Escolha o disco externo para a operacao {0}" -f $ActionLabel)
        if ($Raw -eq '0') {
            throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
        }

        Stop-IfCancelled -Value $Raw

        $Selected = 0
        if ([int]::TryParse($Raw, [ref]$Selected) -and $Selected -ge 1 -and $Selected -le $Candidates.Count) {
            return $Candidates[$Selected - 1]
        }

        Write-Warning 'Selecao invalida.'
    }
}

function Get-DefaultExternalFolderPath {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [string]$CurrentRepositoryPath = ''
    )

    $DriveRoot = ('{0}:\' -f $DriveLetter.Trim().TrimEnd(':', '\').ToUpperInvariant())
    if (-not [string]::IsNullOrWhiteSpace($CurrentRepositoryPath) -and $CurrentRepositoryPath.StartsWith($DriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $RepositoryParent = Split-Path -Parent $CurrentRepositoryPath
        if (-not [string]::IsNullOrWhiteSpace($RepositoryParent) -and $RepositoryParent.StartsWith($DriveRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $RelativePath = $RepositoryParent.Substring($DriveRoot.Length).TrimStart('\')
            if (-not [string]::IsNullOrWhiteSpace($RelativePath)) {
                return $RelativePath
            }
        }
    }

    return 'restic_backup'
}

function Save-ExternalDiskAsDefault {
    param([Parameter(Mandatory)][string]$RepositoryPath)

    $Persist = Read-YesNo -Prompt 'Gravar este disco como destino padrao para futuras atualizacoes?' -Default $true
    if (-not $Persist) {
        Write-Host 'Destino externo mantido apenas para esta execucao.' -ForegroundColor DarkCyan
        return
    }

    $Current = Get-CurrentConfig
    $Current.ExportRepository = $RepositoryPath
    $Scope = Read-ScopeChoice -Current (Get-DefaultWritableScope -Names @('RESTIC_EXPORT_REPOSITORY', 'RESTIC_EXPORT_PASSWORD_FILE')) -Reason 'destino padrao do espelho externo' -Recommendation 'User, a menos que o backup rode em outra conta ou em SYSTEM'
    Update-ConfigState -Config $Current -Scope $Scope
    Write-Host '[OK] Destino externo salvo como padrao.' -ForegroundColor Green
}

function Get-DayLabel {
    param([string]$DayName)

    switch ($DayName) {
        'Sunday' { return 'domingo' }
        'Monday' { return 'segunda' }
        'Tuesday' { return 'terca' }
        'Wednesday' { return 'quarta' }
        'Thursday' { return 'quinta' }
        'Friday' { return 'sexta' }
        'Saturday' { return 'sabado' }
        default { return $DayName }
    }
}

function Resolve-DayNameInput {
    param([string]$InputText)

    $ComparableText = Get-ComparableText -Text $InputText
    if ([string]::IsNullOrWhiteSpace($ComparableText)) {
        return $null
    }

    switch ($ComparableText) {
        'domingo' { return 'Sunday' }
        'dom' { return 'Sunday' }
        'sunday' { return 'Sunday' }

        'segunda' { return 'Monday' }
        'segunda-feira' { return 'Monday' }
        'seg' { return 'Monday' }
        'monday' { return 'Monday' }

        'terca' { return 'Tuesday' }
        'terca-feira' { return 'Tuesday' }
        'ter' { return 'Tuesday' }
        'tuesday' { return 'Tuesday' }

        'quarta' { return 'Wednesday' }
        'quarta-feira' { return 'Wednesday' }
        'qua' { return 'Wednesday' }
        'wednesday' { return 'Wednesday' }

        'quinta' { return 'Thursday' }
        'quinta-feira' { return 'Thursday' }
        'qui' { return 'Thursday' }
        'thursday' { return 'Thursday' }

        'sexta' { return 'Friday' }
        'sexta-feira' { return 'Friday' }
        'sex' { return 'Friday' }
        'friday' { return 'Friday' }

        'sabado' { return 'Saturday' }
        'sab' { return 'Saturday' }
        'saturday' { return 'Saturday' }

        default { return $null }
    }
}

function Read-CheckDayValue {
    param([Parameter(Mandatory)][string]$DefaultDay)

    $PromptOptions = 'domingo/segunda/terca/quarta/quinta/sexta/sabado'
    $DefaultLabel = Get-DayLabel -DayName $DefaultDay

    while ($true) {
        $CheckDayRaw = Read-Host ("Dia da semana do check [{0}] [{1}]" -f $PromptOptions, $DefaultLabel)
        Stop-IfCancelled -Value $CheckDayRaw

        if ([string]::IsNullOrWhiteSpace($CheckDayRaw)) {
            return $DefaultDay
        }

        $ResolvedDay = Resolve-DayNameInput -InputText $CheckDayRaw
        if (-not [string]::IsNullOrWhiteSpace($ResolvedDay)) {
            return $ResolvedDay
        }

        Write-Warning 'Escolha um dia valido: domingo, segunda, terca, quarta, quinta, sexta ou sabado.'
    }
}

function Read-CheckModeValue {
    param([Parameter(Mandatory)][string]$DefaultMode)

    while ($true) {
        $CheckModeRaw = Read-Host ("Modo do check [partial/full] [{0}]" -f $DefaultMode)
        Stop-IfCancelled -Value $CheckModeRaw

        if ([string]::IsNullOrWhiteSpace($CheckModeRaw)) {
            return $DefaultMode
        }

        switch ($CheckModeRaw.Trim().ToLowerInvariant()) {
            'partial' { return 'partial' }
            'parcial' { return 'partial' }
            'full' { return 'full' }
            'completo' { return 'full' }
            default { Write-Warning 'Escolha partial/full ou parcial/completo.' }
        }
    }
}

function Get-NormalizedPath {
    param([AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $Unquoted = $Path.Trim().Trim('"')
    try {
        return [System.IO.Path]::GetFullPath($Unquoted)
    } catch {
        return $Unquoted
    }
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

function Assert-CanUpdateScheduledTasks {
    param(
        [Parameter(Mandatory)][pscustomobject]$BackupSummary,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'Password', 'System')][string]$RunAs,
        [Parameter(Mandatory)][bool]$HighestPrivileges,
        [Parameter(Mandatory)][string]$TaskPath
    )

    $Elevated = Test-IsProcessElevated
    $NeedsElevation = $false
    $Reasons = [System.Collections.Generic.List[string]]::new()

    if ($RunAs -eq 'System') {
        $NeedsElevation = $true
        [void]$Reasons.Add('tarefas em SYSTEM exigem privilegios administrativos')
    }

    if ($HighestPrivileges) {
        $NeedsElevation = $true
        [void]$Reasons.Add('a tarefa usa RunLevel Highest')
    }

    $NormalizedTaskPath = if ([string]::IsNullOrWhiteSpace($TaskPath)) { '\' } else { $TaskPath }
    if ($BackupSummary.Exists -and $NormalizedTaskPath -eq '\') {
        $NeedsElevation = $true
        [void]$Reasons.Add('a tarefa atual esta registrada na raiz do Task Scheduler')
    }

    if ($NeedsElevation -and -not $Elevated) {
        $ReasonText = ($Reasons | Select-Object -Unique) -join '; '
        throw ('A tarefa atual nao pode ser alterada nesta sessao porque {0}. Abra o Centro de Controle como administrador para editar essa tarefa, ou recrie o agendamento sem Highest para poder manter tudo sem elevacao.' -f $ReasonText)
    }
}

function Get-TaskByLauncher {
    param([Parameter(Mandatory)][string]$LauncherPath)

    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        return $null
    }

    $Expected = Get-NormalizedPath -Path $LauncherPath
    foreach ($Task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        foreach ($Action in @($Task.Actions)) {
            $Execute = ''
            try {
                $Execute = [string]$Action.Execute
            } catch {
                $Execute = ''
            }

            if ([string]::IsNullOrWhiteSpace($Execute)) {
                continue
            }

            $Current = Get-NormalizedPath -Path $Execute
            if ($Current.Equals($Expected, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Task
            }
        }
    }

    return $null
}

function Get-TaskRunAsMode {
    param($Task)

    if ($null -eq $Task -or $null -eq $Task.Principal) {
        return 'CurrentUser'
    }

    $LogonType = [string]$Task.Principal.LogonType
    $UserId = [string]$Task.Principal.UserId

    if ($UserId.Equals('SYSTEM', [System.StringComparison]::OrdinalIgnoreCase) -or $LogonType -eq 'ServiceAccount') {
        return 'System'
    }

    if ($LogonType -in @('Password', 'S4U')) {
        return 'Password'
    }

    return 'CurrentUser'
}

function Get-TaskStateLabel {
    param($Task)

    if ($null -eq $Task) {
        return 'nao encontrada'
    }

    switch ([string]$Task.State) {
        'Ready' { return 'pronta' }
        'Running' { return 'em execucao' }
        'Disabled' { return 'desabilitada' }
        'Queued' { return 'na fila' }
        default { return ([string]$Task.State).ToLowerInvariant() }
    }
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$PropertyName,
        $DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $Property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $Property) {
        return $DefaultValue
    }

    return $Property.Value
}

function Get-TriggerSummaryText {
    param($Trigger)

    if ($null -eq $Trigger) {
        return 'sem trigger configurado'
    }

    $TimeText = '(sem hora)'
    if (-not [string]::IsNullOrWhiteSpace([string]$Trigger.StartBoundary)) {
        try {
            $TimeText = ([datetime]$Trigger.StartBoundary).ToString('HH:mm')
        } catch {
            $TimeText = [string]$Trigger.StartBoundary
        }
    }

    $DaysOfWeek = @(Get-OptionalPropertyValue -InputObject $Trigger -PropertyName 'DaysOfWeek' -DefaultValue @())
    $WeeksInterval = [int](Get-OptionalPropertyValue -InputObject $Trigger -PropertyName 'WeeksInterval' -DefaultValue 1)
    $DaysInterval = [int](Get-OptionalPropertyValue -InputObject $Trigger -PropertyName 'DaysInterval' -DefaultValue 1)

    if ($DaysOfWeek.Count -gt 0) {
        $Days = @($DaysOfWeek | ForEach-Object { Get-DayLabel -DayName $_.ToString() })
        $WeekText = if ($WeeksInterval -gt 1) { "a cada $WeeksInterval semanas" } else { 'toda semana' }
        return "$TimeText | $($Days -join ', ') | $WeekText"
    }

    if ($DaysInterval -gt 0) {
        if ($DaysInterval -gt 1) {
            return "$TimeText | a cada $DaysInterval dias"
        }

        return "$TimeText | todo dia"
    }

    return $TimeText
}

function Get-ScheduledTaskSummary {
    param([ValidateSet('Backup', 'Check', 'Export')][string]$Kind)

    switch ($Kind) {
        'Backup' {
            $Launcher = $BackupTaskBat
            $DefaultTaskName = 'Restic Backup Daily'
            $DefaultTime = '02:00'
        }
        'Check' {
            $Launcher = $CheckTaskBat
            $DefaultTaskName = 'Restic Check Weekly'
            $DefaultTime = '03:30'
        }
        'Export' {
            $Launcher = $ExternalSyncBat
            $DefaultTaskName = 'Restic External Sync Weekly'
            $DefaultTime = '05:00'
        }
    }

    $Task = Get-TaskByLauncher -LauncherPath $Launcher
    $Trigger = $null

    if ($null -ne $Task) {
        $Trigger = @($Task.Triggers | Where-Object { $_.Enabled }) | Select-Object -First 1
        if ($null -eq $Trigger) {
            $Trigger = @($Task.Triggers) | Select-Object -First 1
        }
    }

    $ActionArgs = ''
    if ($null -ne $Task) {
        $ActionArgs = (@($Task.Actions | ForEach-Object { [string]$_.Arguments }) -join ' ').Trim()
    }

    $StartTime = if ($null -ne $Trigger -and -not [string]::IsNullOrWhiteSpace([string]$Trigger.StartBoundary)) {
        try {
            ([datetime]$Trigger.StartBoundary).ToString('HH:mm')
        } catch {
            $DefaultTime
        }
    } else {
        $DefaultTime
    }

    $RunAsMode = Get-TaskRunAsMode -Task $Task
    $TaskUserName = if ($null -ne $Task -and $null -ne $Task.Principal) { [string]$Task.Principal.UserId } else { '' }
    $HighestPrivileges = $false
    if ($null -ne $Task -and $null -ne $Task.Principal) {
        $HighestPrivileges = ([string]$Task.Principal.RunLevel -eq 'Highest')
    }

    $CheckMode = if ($ActionArgs -match '-FullCheck') { 'full' } else { 'partial' }
    $DaysInterval = [int](Get-OptionalPropertyValue -InputObject $Trigger -PropertyName 'DaysInterval' -DefaultValue 1)
    $WeeksInterval = [int](Get-OptionalPropertyValue -InputObject $Trigger -PropertyName 'WeeksInterval' -DefaultValue 1)

    $FirstDay = 'Sunday'
    $DayValues = @(Get-OptionalPropertyValue -InputObject $Trigger -PropertyName 'DaysOfWeek' -DefaultValue @() | ForEach-Object { $_.ToString() })
    if ($DayValues.Count -gt 0) {
        $FirstDay = $DayValues[0]
    }

    return [pscustomobject]@{
        Kind              = $Kind
        Exists            = ($null -ne $Task)
        TaskName          = if ($null -ne $Task) { $Task.TaskName } else { $DefaultTaskName }
        TaskPath          = if ($null -ne $Task) { $Task.TaskPath } else { '\\' }
        StateLabel        = Get-TaskStateLabel -Task $Task
        Summary           = Get-TriggerSummaryText -Trigger $Trigger
        Time              = $StartTime
        DaysInterval      = $DaysInterval
        WeeksInterval     = $WeeksInterval
        WeekDay           = $FirstDay
        CheckDay          = $FirstDay
        CheckMode         = $CheckMode
        RunAsMode         = $RunAsMode
        UserName          = $TaskUserName
        HighestPrivileges = $HighestPrivileges
    }
}

function Show-StringList {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Items,
        [int]$MaxItems = 8
    )

    Write-Host $Title -ForegroundColor Cyan
    if ($Items.Count -eq 0) {
        Write-Host '- nenhum item configurado' -ForegroundColor Yellow
        return
    }

    $VisibleCount = [Math]::Min($Items.Count, $MaxItems)
    for ($Index = 0; $Index -lt $VisibleCount; $Index++) {
        Write-Host ("- {0}" -f $Items[$Index])
    }

    if ($Items.Count -gt $VisibleCount) {
        Write-Host ("- ... +{0} item(ns)" -f ($Items.Count - $VisibleCount)) -ForegroundColor DarkCyan
    }
}

function Show-ConfigDashboard {
    $Config = Get-CurrentConfig
    $RepositorySetting = Get-ScopedSetting -Name 'RESTIC_REPOSITORY'
    $LogSetting = Get-ScopedSetting -Name 'RESTIC_LOG_DIR'
    $ExportRepositorySetting = Get-ScopedSetting -Name 'RESTIC_EXPORT_REPOSITORY'
    $ExportPasswordSetting = Get-ScopedSetting -Name 'RESTIC_EXPORT_PASSWORD_FILE'
    $TelegramTokenSetting = Get-ScopedSetting -Name 'RESTIC_TELEGRAM_TOKEN'
    $TelegramChatSetting = Get-ScopedSetting -Name 'RESTIC_TELEGRAM_CHATID'
    $RetentionSetting = Get-ScopedSetting -Name 'RESTIC_KEEP_LAST'
    $SourcesSetting = Get-ScopedSetting -Name 'RESTIC_BACKUP_SOURCES'
    $BackupSchedule = Get-ScheduledTaskSummary -Kind 'Backup'
    $CheckSchedule = Get-ScheduledTaskSummary -Kind 'Check'
    $ExportSchedule = Get-ScheduledTaskSummary -Kind 'Export'

    Write-Host ''
    Write-Host 'RESUMO OPERACIONAL' -ForegroundColor Cyan
    Write-Host '------------------' -ForegroundColor Cyan
    Write-Host ("- Repositorio: {0}" -f $(if ($Config.Repository) { $Config.Repository } else { '(nao configurado)' }))
    Write-Host ("  origem: {0}" -f $RepositorySetting.Scope) -ForegroundColor DarkCyan
    Write-Host ("- Restic: {0}" -f $(if ($Config.ResticExe) { $Config.ResticExe } else { '(nao configurado)' }))
    Write-Host ("- Senha: {0}" -f $(if ($Config.SecretFilePath) { $Config.SecretFilePath } else { '(nao configurado)' }))
    Write-Host ("- Logs: {0} | guarda {1} dias" -f $(if ($Config.LogDir) { $Config.LogDir } else { '(nao configurado)' }), $Config.LogKeepDays)
    Write-Host ("  origem logs: {0}" -f $LogSetting.Scope) -ForegroundColor DarkCyan
    Write-Host ''

    Write-Host 'ESPELHO EXTERNO' -ForegroundColor Cyan
    Write-Host '---------------' -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Config.ExportRepository)) {
        Write-Host '- Status: nao configurado' -ForegroundColor Yellow
    } else {
        Write-Host '- Status: configurado' -ForegroundColor Green
    }
    Write-Host ("- Destino: {0}" -f $(if ($Config.ExportRepository) { $Config.ExportRepository } else { '(nao configurado)' }))
    Write-Host ("- Senha destino: {0}" -f $(if ($Config.ExportPasswordFile) { $Config.ExportPasswordFile } else { 'usa RESTIC_PASSWORD_FILE atual' }))
    Write-Host ("  origem destino/senha: {0} / {1}" -f $ExportRepositorySetting.Scope, $(if ($ExportPasswordSetting.Scope -eq '(nao definido)') { 'herdada de RESTIC_PASSWORD_FILE' } else { $ExportPasswordSetting.Scope })) -ForegroundColor DarkCyan
    Write-Host ''

    Write-Host 'TELEGRAM' -ForegroundColor Cyan
    Write-Host '--------' -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($Config.TelegramToken) -or [string]::IsNullOrWhiteSpace($Config.TelegramChatId)) {
        Write-Host '- Status: incompleto ou desativado' -ForegroundColor Yellow
    } else {
        Write-Host '- Status: ativo' -ForegroundColor Green
    }
    Write-Host ("- Token: {0}" -f (Get-MaskedToken -Token $Config.TelegramToken))
    Write-Host ("- Chat ID: {0}" -f $(if ($Config.TelegramChatId) { $Config.TelegramChatId } else { '(nao configurado)' }))
    Write-Host ("  origem token/chat: {0} / {1}" -f $TelegramTokenSetting.Scope, $TelegramChatSetting.Scope) -ForegroundColor DarkCyan
    Write-Host ''

    Write-Host 'RETENCAO' -ForegroundColor Cyan
    Write-Host '--------' -ForegroundColor Cyan
    Write-Host ("- Janela recente: {0}" -f $Config.KeepLast)
    Write-Host ("- Semanas protegidas: {0}" -f $Config.KeepWeekly)
    Write-Host ("- Meses protegidos: {0}" -f $Config.KeepMonthly)
    Write-Host ("  origem: {0}" -f $RetentionSetting.Scope) -ForegroundColor DarkCyan
    Write-Host ''

    Show-StringList -Title ("FONTES DE BACKUP ({0})" -f $Config.BackupSources.Count) -Items $Config.BackupSources
    Write-Host ("  origem: {0}" -f $SourcesSetting.Scope) -ForegroundColor DarkCyan
    Write-Host ''

    Show-StringList -Title ("EXCLUSOES ({0})" -f $Config.BackupExcludes.Count) -Items $Config.BackupExcludes
    Write-Host ''

    Write-Host 'AGENDAMENTO' -ForegroundColor Cyan
    Write-Host '-----------' -ForegroundColor Cyan
    if ($BackupSchedule.Exists) {
        Write-Host ("- Backup: {0}" -f $BackupSchedule.Summary)
        Write-Host ("  tarefa: {0}{1} | estado: {2} | conta: {3}{4}" -f $BackupSchedule.TaskPath, $BackupSchedule.TaskName, $BackupSchedule.StateLabel, $BackupSchedule.RunAsMode, $(if ($BackupSchedule.UserName) { " ($($BackupSchedule.UserName))" } else { '' })) -ForegroundColor DarkCyan
    } else {
        Write-Host '- Backup: tarefa nao encontrada no Agendador' -ForegroundColor Yellow
    }

    if ($CheckSchedule.Exists) {
        Write-Host ("- Check: {0} | modo {1}" -f $CheckSchedule.Summary, $CheckSchedule.CheckMode)
        Write-Host ("  tarefa: {0}{1} | estado: {2}" -f $CheckSchedule.TaskPath, $CheckSchedule.TaskName, $CheckSchedule.StateLabel) -ForegroundColor DarkCyan
    } else {
        Write-Host '- Check: sem tarefa semanal registrada' -ForegroundColor Yellow
    }

    if ($ExportSchedule.Exists) {
        Write-Host ("- Espelho externo: {0}" -f $ExportSchedule.Summary)
        Write-Host ("  tarefa: {0}{1} | estado: {2}" -f $ExportSchedule.TaskPath, $ExportSchedule.TaskName, $ExportSchedule.StateLabel) -ForegroundColor DarkCyan
    } else {
        Write-Host '- Espelho externo: sem tarefa semanal registrada' -ForegroundColor Yellow
    }

    if ($RepositorySetting.Scope -eq 'Process' -or $LogSetting.Scope -eq 'Process' -or $ExportRepositorySetting.Scope -eq 'Process' -or $TelegramTokenSetting.Scope -eq 'Process') {
        Write-Host ''
        Write-Host 'Observacao: ha valores vindos apenas da sessao atual (Process).' -ForegroundColor Yellow
        Write-Host 'Se quiser persistir, use as telas de edicao e grave em User ou Machine.' -ForegroundColor Yellow
    }
}

function Update-ConfigState {
    param(
        [Parameter(Mandatory)]$Config,
        [ValidateSet('User', 'Machine')][string]$Scope = 'User'
    )

    $SetupParams = @{
        Scope          = $Scope
        ResticExe      = $Config.ResticExe
        Repository     = $Config.Repository
        SecretFilePath = $Config.SecretFilePath
        LogDir         = $Config.LogDir
        LogKeepDays    = [int]$Config.LogKeepDays
        ExportRepository = $Config.ExportRepository
        ExportPasswordFile = $Config.ExportPasswordFile
        TelegramToken  = $Config.TelegramToken
        TelegramChatId = $Config.TelegramChatId
        KeepLast       = [int]$Config.KeepLast
        KeepWeekly     = [int]$Config.KeepWeekly
        KeepMonthly    = [int]$Config.KeepMonthly
        BackupSources  = @($Config.BackupSources)
        BackupExcludes = @($Config.BackupExcludes)
    }

    & $SetupScript @SetupParams
}

function New-ProfilesStore {
    $Dir = Split-Path -Parent $ProfilesFile
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $ProfilesFile)) {
        $Initial = [ordered]@{ profiles = @{} } | ConvertTo-Json -Depth 10
        Set-Content -Path $ProfilesFile -Value $Initial -Encoding UTF8
    }
}

function Get-ProfilesStore {
    New-ProfilesStore

    $Raw = Get-Content -Path $ProfilesFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return [ordered]@{ profiles = @{} }
    }

    $Parsed = $Raw | ConvertFrom-Json -Depth 20
    if ($null -eq $Parsed.profiles) {
        $Parsed | Add-Member -NotePropertyName profiles -NotePropertyValue (@{}) -Force
    }

    return $Parsed
}

function Set-ProfilesStore {
    param([Parameter(Mandatory)]$ProfilesObject)

    $Json = $ProfilesObject | ConvertTo-Json -Depth 20
    Set-Content -Path $ProfilesFile -Value $Json -Encoding UTF8
}

function Select-ProfileName {
    param([Parameter(Mandatory)][string]$Prompt)

    $Profiles = Get-ProfilesStore
    $Names = @($Profiles.profiles.PSObject.Properties.Name)

    if ($Names.Count -eq 0) {
        Write-Warning 'Nenhum perfil salvo ainda.'
        return $null
    }

    Write-Host ''
    Write-Host 'Perfis salvos:' -ForegroundColor Cyan
    for ($Index = 0; $Index -lt $Names.Count; $Index++) {
        Write-Host ("[{0}] {1}" -f ($Index + 1), $Names[$Index])
    }
    Write-Host '[0] Voltar'

    while ($true) {
        $Raw = Read-Host $Prompt
        if ($Raw -eq '0') {
            throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
        }

        Stop-IfCancelled -Value $Raw

        $Selected = 0
        if ([int]::TryParse($Raw, [ref]$Selected) -and $Selected -ge 1 -and $Selected -le $Names.Count) {
            return $Names[$Selected - 1]
        }

        Write-Warning 'Selecao invalida.'
    }
}

function Export-CurrentProfile {
    Show-FlowHeader -Title 'SALVAR PERFIL' -Goal 'Salva uma foto da configuracao atual para reaplicar depois com poucos cliques.' -Bullets @(
        'use perfis para separar cenarios como casa, trabalho ou cliente A'
    ) -ClearScreen

    Show-InputTips

    $Current = Get-CurrentConfig
    $ProfileName = Read-Text -Prompt 'Nome do perfil (ex.: casa, trabalho)'
    $Profiles = Get-ProfilesStore
    $Profiles.profiles | Add-Member -NotePropertyName $ProfileName -NotePropertyValue $Current -Force
    Set-ProfilesStore -ProfilesObject $Profiles

    Write-Host "[OK] Perfil salvo: $ProfileName" -ForegroundColor Green
    Write-Host "Arquivo: $ProfilesFile" -ForegroundColor DarkCyan
}

function Update-ProfileFromStore {
    Show-FlowHeader -Title 'APLICAR PERFIL' -Goal 'Substitui a configuracao atual pelas configuracoes salvas em um perfil.' -Bullets @(
        'isso troca caminhos, retencao, Telegram, fontes e exclusoes conforme o perfil escolhido'
    ) -ClearScreen

    $ProfileName = Select-ProfileName -Prompt 'Escolha o numero do perfil para aplicar'
    $Profiles = Get-ProfilesStore
    $SelectedProfile = $Profiles.profiles.$ProfileName
    $Scope = Read-ScopeChoice -Current (Get-DefaultWritableScope -Names @('RESTIC_REPOSITORY', 'RESTIC_LOG_DIR')) -Reason ('aplicar o perfil salvo "{0}"' -f $ProfileName) -Recommendation 'User, a menos que o perfil precise valer para tarefas em outra conta ou em SYSTEM'
    Update-ConfigState -Config $SelectedProfile -Scope $Scope
    Write-Host "[OK] Perfil aplicado: $ProfileName" -ForegroundColor Green
}

function Remove-ProfileFromStore {
    Show-FlowHeader -Title 'REMOVER PERFIL' -Goal 'Remove um perfil salvo que nao sera mais usado.' -Bullets @(
        'isso nao altera a configuracao atual da maquina; apenas remove o perfil salvo do catalogo local'
    ) -ClearScreen

    $ProfileName = Select-ProfileName -Prompt 'Numero do perfil para remover'
    $Profiles = Get-ProfilesStore
    $Confirm = Read-YesNo -Prompt ("Confirmar remocao do perfil '{0}'?" -f $ProfileName) -Default $false
    if (-not $Confirm) {
        Write-Host 'Remocao cancelada.' -ForegroundColor DarkCyan
        return
    }

    $Profiles.profiles.PSObject.Properties.Remove($ProfileName)
    Set-ProfilesStore -ProfilesObject $Profiles
    Write-Host "[OK] Perfil removido: $ProfileName" -ForegroundColor Green
}

function Show-ProfileMenu {
    while ($true) {
        Clear-Host
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host ' PERFIS DE CONFIGURACAO' -ForegroundColor Cyan
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host 'Use perfis para guardar configuracoes completas e alternar entre cenarios rapidamente.' -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '[1] Salvar configuracao atual como perfil'
        Write-Host '    Guarda o estado atual para reaplicar depois.' -ForegroundColor DarkCyan
        Write-Host '[2] Aplicar perfil salvo'
        Write-Host '    Troca a configuracao atual pela de um perfil salvo.' -ForegroundColor DarkCyan
        Write-Host '[3] Remover perfil salvo'
        Write-Host '    Exclui um perfil que nao sera mais usado.' -ForegroundColor DarkCyan
        Write-Host '[0] Voltar ao menu principal'
        Write-Host ''

        $Choice = Read-Host 'Escolha uma opcao'
        if ($null -eq $Choice) {
            break
        }

        switch ($Choice.Trim()) {
            '1' {
                try {
                    Export-CurrentProfile
                } catch [System.OperationCanceledException] {
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                }
                Read-MenuPause
            }
            '2' {
                try {
                    Update-ProfileFromStore
                } catch [System.OperationCanceledException] {
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                }
                Read-MenuPause
            }
            '3' {
                try {
                    Remove-ProfileFromStore
                } catch [System.OperationCanceledException] {
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                }
                Read-MenuPause
            }
            '0' {
                break
            }
            default {
                Write-Warning 'Opcao invalida.'
                Read-MenuPause
            }
        }
    }
}

function Update-TelegramSettings {
    $Current = Get-CurrentConfig

    Show-FlowHeader -Title 'TELEGRAM' -Goal 'Configura para onde o sistema envia notificacoes de backup e check.' -Bullets @(
        'preencha token e chat para ativar notificacoes',
        'use - para limpar um valor e desativar o envio'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'Primeiro voce ajusta token/chat. Depois o sistema pergunta onde gravar essa configuracao.'

    Show-KeyValueSummary -Title 'Estado atual:' -Pairs ([ordered]@{
        'Status' = $(if ([string]::IsNullOrWhiteSpace($Current.TelegramToken) -or [string]::IsNullOrWhiteSpace($Current.TelegramChatId)) { 'incompleto ou desativado' } else { 'ativo' })
        'Token' = (Get-MaskedToken -Token $Current.TelegramToken)
        'Chat ID' = $(if ($Current.TelegramChatId) { $Current.TelegramChatId } else { '(nao configurado)' })
    })

    $Current.TelegramToken = Read-Text -Prompt 'Token do bot (RESTIC_TELEGRAM_TOKEN)' -Default $Current.TelegramToken -AllowClear
    $Current.TelegramChatId = Read-Text -Prompt 'Chat ID de destino (RESTIC_TELEGRAM_CHATID)' -Default $Current.TelegramChatId -AllowClear

    Show-KeyValueSummary -Title 'Resumo que sera gravado:' -Pairs ([ordered]@{
        'Token' = (Get-MaskedToken -Token $Current.TelegramToken)
        'Chat ID' = $(if ($Current.TelegramChatId) { $Current.TelegramChatId } else { '(vazio)' })
    })

    $Scope = Read-ScopeChoice -Current (Get-DefaultWritableScope -Names @('RESTIC_TELEGRAM_TOKEN', 'RESTIC_TELEGRAM_CHATID')) -Reason 'token e chat do Telegram para notificacoes' -Recommendation 'User, se o backup roda na sua conta; Machine se as tarefas rodam em outra conta ou em SYSTEM'

    Update-ConfigState -Config $Current -Scope $Scope
    Write-Host ("[OK] Telegram atualizado em {0}." -f $Scope) -ForegroundColor Green
}

function Update-RetentionSettings {
    $Current = Get-CurrentConfig

    Show-FlowHeader -Title 'RETENCAO E SNAPSHOTS' -Goal 'Aqui voce define a politica que o Restic usa para decidir quais snapshots continuam valendo e quais podem ser removidos.' -Bullets @(
        'keep-last = guarda os N snapshots mais recentes',
        'keep-weekly = tambem guarda 1 snapshot representativo por semana nas ultimas N semanas',
        'keep-monthly = tambem guarda 1 snapshot representativo por mes nos ultimos N meses',
        'essas regras sao combinadas: um snapshot e mantido se bater em qualquer regra',
        'por isso o total final pode ser maior que keep-last',
        'se voce quer somente os ultimos N snapshots, deixe keep-weekly = 0 e keep-monthly = 0',
        'essas regras entram em acao nas proximas execucoes do backup, quando o forget/prune for aplicado'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'Primeiro voce ajusta os valores. Depois o sistema pergunta onde gravar essa politica.'

    Show-KeyValueSummary -Title 'Politica atual:' -Pairs @{
        'Janela recente (keep-last)' = [string]$Current.KeepLast
        'Semanas protegidas (keep-weekly)' = [string]$Current.KeepWeekly
        'Meses protegidos (keep-monthly)' = [string]$Current.KeepMonthly
    }

    $Current.KeepLast = Read-Number -Prompt 'Quantos snapshots recentes manter (keep-last)' -Default ([int]$Current.KeepLast) -MinValue 1
    $Current.KeepWeekly = Read-Number -Prompt 'Quantas semanas manter representadas (keep-weekly)' -Default ([int]$Current.KeepWeekly) -MinValue 0
    $Current.KeepMonthly = Read-Number -Prompt 'Quantos meses manter representados (keep-monthly)' -Default ([int]$Current.KeepMonthly) -MinValue 0

    Show-KeyValueSummary -Title 'Resumo que sera gravado:' -Pairs @{
        'Janela recente (keep-last)' = [string]$Current.KeepLast
        'Semanas protegidas (keep-weekly)' = [string]$Current.KeepWeekly
        'Meses protegidos (keep-monthly)' = [string]$Current.KeepMonthly
    }

    $Scope = Read-ScopeChoice -Current (Get-DefaultWritableScope -Names @('RESTIC_KEEP_LAST', 'RESTIC_KEEP_WEEKLY', 'RESTIC_KEEP_MONTHLY')) -Reason 'politica de retencao de snapshots do backup' -Recommendation 'User, a menos que suas tarefas rodem em outra conta ou em SYSTEM'

    Update-ConfigState -Config $Current -Scope $Scope
    Write-Host ("[OK] Retencao atualizada em {0}." -f $Scope) -ForegroundColor Green
}

function Show-RetentionLayoutPreview {
    if (-not (Test-Path -LiteralPath $RetentionLayoutScript)) {
        Write-Warning "Visualizador de retencao nao encontrado: $RetentionLayoutScript"
        return
    }

    Show-FlowHeader -Title 'SNAPSHOTS MANTIDOS PELA POLITICA' -Goal 'Mostra como a politica atual preserva os snapshots se a limpeza rodasse agora.' -Bullets @(
        'a ordem exibida e: recentes, semanais extras, mensais extras',
        'isso nao altera o repositorio; o comando roda em modo dry-run'
    ) -ClearScreen

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $RetentionLayoutScript
    $PreviewExitCode = $LASTEXITCODE
    if ($PreviewExitCode -ne 0) {
        throw "Visualizacao da retencao retornou codigo $PreviewExitCode"
    }
}

function Update-PathSettings {
    $Current = Get-CurrentConfig

    Show-FlowHeader -Title 'CAMINHOS PRINCIPAIS E ESPELHO EXTERNO' -Goal 'Define os caminhos base do projeto: executavel, repositorio, senha, logs e o destino padrao opcional do HD externo.' -Bullets @(
        'o repositorio principal e obrigatorio para backup e restore',
        'o destino padrao externo so e necessario se voce quiser deixar pronto o espelho externo semanal automatico',
        'se voce pretende conectar o HD e escolher tudo manualmente no menu, pode deixar esse campo vazio',
        'use - para limpar somente os campos do espelho externo'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'Primeiro voce ajusta os caminhos. Depois o sistema pergunta onde gravar essa configuracao.'

    Show-KeyValueSummary -Title 'Configuracao atual:' -Pairs ([ordered]@{
        'Executavel do Restic' = $(if ($Current.ResticExe) { $Current.ResticExe } else { '(nao configurado)' })
        'Repositorio principal' = $(if ($Current.Repository) { $Current.Repository } else { '(nao configurado)' })
        'Arquivo de senha' = $(if ($Current.SecretFilePath) { $Current.SecretFilePath } else { '(nao configurado)' })
        'Pasta de logs' = $(if ($Current.LogDir) { $Current.LogDir } else { '(nao configurado)' })
        'Dias de log' = [string]$Current.LogKeepDays
        'Destino padrao no HD externo' = $(if ($Current.ExportRepository) { $Current.ExportRepository } else { '(nao configurado)' })
        'Senha do repo externo' = $(if ($Current.ExportPasswordFile) { $Current.ExportPasswordFile } else { 'usa RESTIC_PASSWORD_FILE atual' })
    })

    $Current.ResticExe = Read-Text -Prompt 'Executavel do Restic (RESTIC_EXE)' -Default $Current.ResticExe
    $Current.Repository = Read-Text -Prompt 'Repositorio principal (RESTIC_REPOSITORY)' -Default $Current.Repository
    $Current.SecretFilePath = Read-Text -Prompt 'Arquivo de senha (RESTIC_PASSWORD_FILE)' -Default $Current.SecretFilePath
    $Current.LogDir = Read-Text -Prompt 'Pasta de logs (RESTIC_LOG_DIR)' -Default $Current.LogDir
    $Current.LogKeepDays = Read-Number -Prompt 'Dias de retencao dos logs (RESTIC_LOG_KEEP_DAYS)' -Default ([int]$Current.LogKeepDays) -MinValue 1
    $Current.ExportRepository = Read-Text -Prompt 'Destino padrao do HD externo (RESTIC_EXPORT_REPOSITORY)' -Default $Current.ExportRepository -AllowClear
    $Current.ExportPasswordFile = Read-Text -Prompt 'Arquivo de senha do repo externo (RESTIC_EXPORT_PASSWORD_FILE)' -Default $Current.ExportPasswordFile -AllowClear

    Show-KeyValueSummary -Title 'Resumo que sera gravado:' -Pairs ([ordered]@{
        'Executavel do Restic' = $Current.ResticExe
        'Repositorio principal' = $Current.Repository
        'Arquivo de senha' = $Current.SecretFilePath
        'Pasta de logs' = $Current.LogDir
        'Dias de log' = [string]$Current.LogKeepDays
        'Destino padrao no HD externo' = $(if ($Current.ExportRepository) { $Current.ExportRepository } else { '(vazio)' })
        'Senha do repo externo' = $(if ($Current.ExportPasswordFile) { $Current.ExportPasswordFile } else { '(vazio / herdar senha principal)' })
    })

    $Scope = Read-ScopeChoice -Current (Get-DefaultWritableScope -Names @('RESTIC_EXE', 'RESTIC_REPOSITORY', 'RESTIC_PASSWORD_FILE', 'RESTIC_LOG_DIR', 'RESTIC_EXPORT_REPOSITORY', 'RESTIC_EXPORT_PASSWORD_FILE')) -Reason 'caminhos principais do backup e do espelho externo' -Recommendation 'User, a menos que as tarefas rodem em outra conta ou em SYSTEM'

    Update-ConfigState -Config $Current -Scope $Scope
    Write-Host ("[OK] Caminhos principais e espelho externo atualizados em {0}." -f $Scope) -ForegroundColor Green
}

function Update-BackupSourceSettings {
    $Current = Get-CurrentConfig

    Show-FlowHeader -Title 'FONTES E EXCLUSOES DO BACKUP' -Goal 'Define o que entra no backup e o que fica de fora.' -Bullets @(
        'separe varios caminhos com ;',
        'as exclusoes aceitam pastas e padroes como *.tmp',
        'use - para limpar a lista de exclusoes'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'Primeiro voce ajusta as listas. Depois o sistema pergunta onde gravar essa configuracao.'

    Show-StringList -Title ("Fontes atuais ({0})" -f $Current.BackupSources.Count) -Items $Current.BackupSources
    Write-Host ''
    Show-StringList -Title ("Exclusoes atuais ({0})" -f $Current.BackupExcludes.Count) -Items $Current.BackupExcludes
    Write-Host ''

    $SourcesRaw = Read-Text -Prompt 'Fontes de backup (RESTIC_BACKUP_SOURCES | ; separado)' -Default ($Current.BackupSources -join ';')
    $ExcludesRaw = Read-Text -Prompt 'Exclusoes do backup (RESTIC_BACKUP_EXCLUDES | ; separado)' -Default ($Current.BackupExcludes -join ';') -AllowClear

    $Current.BackupSources = @($SourcesRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Current.BackupExcludes = @($ExcludesRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    if ($Current.BackupSources.Count -eq 0) {
        throw 'Pelo menos uma fonte de backup e obrigatoria.'
    }

    Show-StringList -Title ("Fontes que serao gravadas ({0})" -f $Current.BackupSources.Count) -Items $Current.BackupSources
    Write-Host ''
    Show-StringList -Title ("Exclusoes que serao gravadas ({0})" -f $Current.BackupExcludes.Count) -Items $Current.BackupExcludes
    Write-Host ''

    $Scope = Read-ScopeChoice -Current (Get-DefaultWritableScope -Names @('RESTIC_BACKUP_SOURCES', 'RESTIC_BACKUP_EXCLUDES')) -Reason 'fontes e exclusoes do backup' -Recommendation 'User, a menos que o backup rode em outra conta ou em SYSTEM'

    Update-ConfigState -Config $Current -Scope $Scope
    Write-Host ("[OK] Fontes e exclusoes atualizadas em {0}." -f $Scope) -ForegroundColor Green
}

function Remove-CheckTaskIfRequested {
    param($CheckSummary)

    if (-not $CheckSummary.Exists) {
        return
    }

    $ShouldRemove = Read-YesNo -Prompt 'Deseja remover a tarefa semanal de check atual?' -Default $false
    if (-not $ShouldRemove) {
        Write-Host 'Check semanal mantido sem alteracoes.' -ForegroundColor DarkCyan
        return
    }

    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'O Windows nao disponibiliza Unregister-ScheduledTask neste ambiente.'
    }

    Unregister-ScheduledTask -TaskName $CheckSummary.TaskName -TaskPath $CheckSummary.TaskPath -Confirm:$false
    Write-Host '[OK] Tarefa semanal de check removida.' -ForegroundColor Green
}

function Remove-ExportTaskIfRequested {
    param($ExportSummary)

    if (-not $ExportSummary.Exists) {
        return
    }

    $ShouldRemove = Read-YesNo -Prompt 'Deseja remover a tarefa semanal de espelho externo atual?' -Default $false
    if (-not $ShouldRemove) {
        Write-Host 'Espelho externo semanal mantido sem alteracoes.' -ForegroundColor DarkCyan
        return
    }

    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'O Windows nao disponibiliza Unregister-ScheduledTask neste ambiente.'
    }

    Unregister-ScheduledTask -TaskName $ExportSummary.TaskName -TaskPath $ExportSummary.TaskPath -Confirm:$false
    Write-Host '[OK] Tarefa semanal de espelho externo removida.' -ForegroundColor Green
}

function Update-ScheduleSettings {
    $BackupSummary = Get-ScheduledTaskSummary -Kind 'Backup'
    $CheckSummary = Get-ScheduledTaskSummary -Kind 'Check'
    $ExportSummary = Get-ScheduledTaskSummary -Kind 'Export'
    $Config = Get-CurrentConfig

    Show-FlowHeader -Title 'AGENDAMENTO' -Goal 'Aqui voce ajusta quando as tarefas automaticas rodam no Windows.' -Bullets @(
        'backup = copia seus dados para o repositorio principal',
        'check = verifica a integridade do repositorio',
        'espelho externo = atualiza o segundo repositorio Restic que fica no HD externo',
        'isso so precisa de destino salvo quando voce quer automatizar a rotina semanal'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'No fim desta tela, o sistema mostra um resumo completo antes de aplicar o novo agendamento.'

    Write-Host 'Agendamento atual:' -ForegroundColor Cyan
    if ($BackupSummary.Exists) {
        Write-Host ("- Backup: {0}" -f $BackupSummary.Summary)
        Write-Host ("  conta: {0}{1}" -f $BackupSummary.RunAsMode, $(if ($BackupSummary.UserName) { " ($($BackupSummary.UserName))" } else { '' })) -ForegroundColor DarkCyan
    } else {
        Write-Host '- Backup: tarefa nao encontrada; sera criada se voce confirmar os dados.' -ForegroundColor Yellow
    }

    if ($CheckSummary.Exists) {
        Write-Host ("- Check: {0} | modo {1}" -f $CheckSummary.Summary, $CheckSummary.CheckMode)
    } else {
        Write-Host '- Check: nao existe tarefa semanal hoje.' -ForegroundColor Yellow
    }

    if ($ExportSummary.Exists) {
        Write-Host ("- Espelho externo: {0}" -f $ExportSummary.Summary)
    } elseif ([string]::IsNullOrWhiteSpace($Config.ExportRepository)) {
        Write-Host '- Espelho externo: sem destino padrao salvo; a tarefa automatica semanal fica desabilitada ate configurar RESTIC_EXPORT_REPOSITORY.' -ForegroundColor Yellow
        Write-Host '- Uso manual continua disponivel no menu de disco externo, escolhendo o HD na hora.' -ForegroundColor DarkCyan
    } else {
        Write-Host '- Espelho externo: nao existe tarefa semanal hoje.' -ForegroundColor Yellow
    }
    Write-Host ''

    $BackupTime = Read-TimeText -Prompt 'Horario diario do backup (HH:mm)' -Default $BackupSummary.Time
    $BackupDaysInterval = Read-Number -Prompt 'Executar backup a cada quantos dias' -Default ([int]$BackupSummary.DaysInterval) -MinValue 1
    $ConfigureCheck = Read-YesNo -Prompt 'Deseja manter ou criar o check semanal?' -Default $CheckSummary.Exists
    $ConfigureExport = Read-YesNo -Prompt 'Deseja manter ou criar o espelho externo semanal?' -Default ($ExportSummary.Exists -or (-not [string]::IsNullOrWhiteSpace($Config.ExportRepository)))

    $RegisterParams = @{
        InstallDir        = $ProjectRoot
        BackupTime        = $BackupTime
        BackupDaysInterval = $BackupDaysInterval
        RunAs             = $BackupSummary.RunAsMode
        HighestPrivileges = [bool]$BackupSummary.HighestPrivileges
        TaskPath          = $BackupSummary.TaskPath
        BackupTaskName    = $BackupSummary.TaskName
    }

    if ($BackupSummary.RunAsMode -eq 'Password') {
        Write-Host ''
        Write-Host 'A tarefa atual usa credencial armazenada.' -ForegroundColor Yellow
        Write-Host 'Para regravar o agendamento, a senha precisa ser informada novamente.' -ForegroundColor Yellow
        $UserName = Read-Text -Prompt 'Usuario da tarefa' -Default $BackupSummary.UserName
        $TaskPassword = Read-SecretValue -Prompt 'Senha da tarefa'
        $RegisterParams.UserName = $UserName
        $RegisterParams.TaskPassword = $TaskPassword
    }

    if ($ConfigureCheck) {
        Write-Host ''
        Write-Host 'CHECK SEMANAL' -ForegroundColor Cyan
        $CheckDay = Read-CheckDayValue -DefaultDay $CheckSummary.CheckDay

        $CheckTime = Read-TimeText -Prompt 'Horario do check semanal (HH:mm)' -Default $CheckSummary.Time
        $CheckMode = Read-CheckModeValue -DefaultMode $CheckSummary.CheckMode

        $CheckWeeksInterval = Read-Number -Prompt 'Intervalo do check em semanas' -Default ([int]$CheckSummary.WeeksInterval) -MinValue 1

        $RegisterParams.CreateCheckTask = $true
        $RegisterParams.CheckDay = $CheckDay
        $RegisterParams.CheckTime = $CheckTime
        $RegisterParams.CheckMode = $CheckMode
        $RegisterParams.CheckWeeksInterval = $CheckWeeksInterval
        $RegisterParams.CheckTaskName = $CheckSummary.TaskName
    }

    if ($ConfigureExport) {
        if ([string]::IsNullOrWhiteSpace($Config.ExportRepository)) {
            throw 'Salve primeiro o destino padrao do HD externo em "Caminhos principais e destino externo" antes de criar o espelho externo semanal.'
        }

        Write-Host ''
        Write-Host 'ESPELHO EXTERNO SEMANAL' -ForegroundColor Cyan
        $ExportDay = Read-CheckDayValue -DefaultDay $ExportSummary.WeekDay
        $ExportTime = Read-TimeText -Prompt 'Horario do espelho externo semanal (HH:mm)' -Default $ExportSummary.Time
        $ExportWeeksInterval = Read-Number -Prompt 'Intervalo do espelho externo em semanas' -Default ([int]$ExportSummary.WeeksInterval) -MinValue 1

        $RegisterParams.CreateExportTask = $true
        $RegisterParams.ExportDay = $ExportDay
        $RegisterParams.ExportTime = $ExportTime
        $RegisterParams.ExportWeeksInterval = $ExportWeeksInterval
        $RegisterParams.ExportTaskName = $ExportSummary.TaskName
    }

    Show-KeyValueSummary -Title 'Resumo que sera aplicado:' -Pairs ([ordered]@{
        'Backup diario' = ("{0} | a cada {1} dia(s)" -f $BackupTime, $BackupDaysInterval)
        'Check semanal' = $(if ($ConfigureCheck) { "{0} | {1} | modo {2} | a cada {3} semana(s)" -f $CheckTime, (Get-DayLabel -DayName $CheckDay), $CheckMode, $CheckWeeksInterval } else { 'nao sera criado/ajustado nesta execucao' })
        'Espelho externo semanal' = $(if ($ConfigureExport) { "{0} | {1} | a cada {2} semana(s)" -f $ExportTime, (Get-DayLabel -DayName $ExportDay), $ExportWeeksInterval } else { 'nao sera criado/ajustado nesta execucao' })
        'Conta da tarefa' = $RegisterParams.RunAs
        'RunLevel Highest' = $(if ($RegisterParams.HighestPrivileges) { 'sim' } else { 'nao' })
    })

    $ApplySchedule = Read-YesNo -Prompt 'Aplicar este agendamento agora?' -Default $true
    if (-not $ApplySchedule) {
        throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
    }

    Assert-CanUpdateScheduledTasks -BackupSummary $BackupSummary -RunAs $RegisterParams.RunAs -HighestPrivileges ([bool]$RegisterParams.HighestPrivileges) -TaskPath $RegisterParams.TaskPath

    & $RegisterTasksScript @RegisterParams

    if (-not $ConfigureCheck) {
        Remove-CheckTaskIfRequested -CheckSummary $CheckSummary
    }

    if (-not $ConfigureExport) {
        Remove-ExportTaskIfRequested -ExportSummary $ExportSummary
    }

    Write-Host '[OK] Agendamento atualizado.' -ForegroundColor Green
}

function Test-TelegramPing {
    Show-FlowHeader -Title 'TESTE DE TELEGRAM' -Goal 'Envia uma mensagem simples para validar se token e chat estao funcionando.' -Bullets @(
        'o teste usa exatamente a configuracao atual gravada no projeto'
    ) -ClearScreen

    $Token = Get-EffectiveValue -Name 'RESTIC_TELEGRAM_TOKEN'
    $ChatId = Get-EffectiveValue -Name 'RESTIC_TELEGRAM_CHATID'

    if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)) {
        Write-Warning 'Telegram nao configurado. Ajuste token/chat primeiro.'
        return
    }

    $Stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $Payload = @{ chat_id = $ChatId; text = "[TESTE] Centro de Controle em $Stamp" } | ConvertTo-Json -Compress
    $TelegramApiHost = 'api.telegram.org'

    try {
        Resolve-DnsName -Name $TelegramApiHost -ErrorAction Stop | Out-Null
        $Result = Invoke-RestMethod -Uri "https://$TelegramApiHost/bot$Token/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Payload))
        if ($Result.ok) {
            Write-Host '[OK] Ping Telegram enviado com sucesso.' -ForegroundColor Green
        } else {
            Write-Warning 'Telegram respondeu sem ok=true.'
        }
    } catch {
        $Message = $_.Exception.Message
        $WebException = $_.Exception
        if ($_.Exception.PSObject.Properties.Match('InnerException').Count -gt 0 -and $null -ne $_.Exception.InnerException) {
            $Message = $_.Exception.InnerException.Message
            $WebException = $_.Exception.InnerException
        }

        if ($WebException -is [System.Net.WebException] -and $WebException.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
            Write-Error 'Falha ao enviar ping Telegram: nao foi possivel resolver api.telegram.org. Isso indica problema de DNS/rede neste momento, nao erro na gravacao do token/chat.'
            return
        }

        if ($Message -match 'api\.telegram\.org' -and $Message -match 'resolvido|resolved|NameResolutionFailure') {
            Write-Error 'Falha ao enviar ping Telegram: api.telegram.org nao respondeu por DNS. Isso normalmente e falha transitória de rede, proxy, firewall ou DNS local.'
            return
        }

        Write-Error "Falha ao enviar ping Telegram: $Message"
    }
}

function Start-BackupNow {
    if (-not (Test-Path -LiteralPath $BackupNowBat)) {
        Write-Warning "Launcher nao encontrado: $BackupNowBat"
        return
    }

    Show-FlowHeader -Title 'BACKUP AGORA' -Goal 'Dispara imediatamente o launcher de backup manual.' -Bullets @(
        'os logs vao para runtime\\logs',
        'use esta opcao quando quiser testar ou rodar o backup fora do horario agendado'
    ) -ClearScreen

    $Continue = Read-YesNo -Prompt 'Executar o backup agora?' -Default $true
    if (-not $Continue) {
        throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
    }

    Write-Host '[INFO] Disparando backup imediato...' -ForegroundColor Cyan
    cmd /c "\"$BackupNowBat\" --no-pause"
}

function Start-RestoreFlow {
    if (-not (Test-Path -LiteralPath $RestoreScript)) {
        Write-Warning "Script de restore nao encontrado: $RestoreScript"
        return
    }

    Show-FlowHeader -Title 'RESTORE POR SNAPSHOT' -Goal 'Restaura um snapshot especifico para uma pasta escolhida por voce.' -Bullets @(
        'o ideal e usar uma pasta nova ou vazia para revisar os arquivos antes de promover para o SSD',
        'se quiser restaurar tudo, deixe Includes vazio',
        'voce pode usar latest se quiser o snapshot mais recente'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'No fim desta tela, o sistema mostra um resumo antes de iniciar o restore.'

    $SnapshotId = Read-Text -Prompt 'Snapshot ID para restore' -Default 'latest'
    $TargetPath = Read-Text -Prompt 'Pasta de destino do restore'
    $IncludeRaw = Read-Text -Prompt 'Includes opcionais (; separados)' -AllowEmpty

    $Includes = @($IncludeRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $TargetAlreadyHasFiles = (Test-Path -LiteralPath $TargetPath) -and ($null -ne (Get-ChildItem -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1))

    Show-KeyValueSummary -Title 'Resumo do restore:' -Pairs ([ordered]@{
        'Snapshot' = $SnapshotId
        'Destino' = $TargetPath
        'Includes' = $(if ($Includes.Count -gt 0) { $Includes -join '; ' } else { '(todos os arquivos do snapshot)' })
        'Destino ja contem arquivos' = $(if ($TargetAlreadyHasFiles) { 'sim, revise com cuidado' } else { 'nao' })
    })

    $Continue = Read-YesNo -Prompt 'Iniciar o restore agora?' -Default $true
    if (-not $Continue) {
        throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
    }

    $RestoreCommandArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $RestoreScript
        '-SnapshotId'
        $SnapshotId
        '-TargetPath'
        $TargetPath
    )

    foreach ($IncludeItem in $Includes) {
        $RestoreCommandArgs += '-Include'
        $RestoreCommandArgs += $IncludeItem
    }

    & powershell.exe @RestoreCommandArgs
    $RestoreExitCode = $LASTEXITCODE
    if ($RestoreExitCode -ne 0) {
        throw "Restore retornou codigo $RestoreExitCode"
    }
}

function Start-ExportActiveSnapshotsFlow {
    if (-not (Test-Path -LiteralPath $ExportSnapshotsScript)) {
        Write-Warning "Script de exportacao nao encontrado: $ExportSnapshotsScript"
        return
    }

    $CurrentConfig = Get-CurrentConfig
    $DefaultExportPasswordFile = if ([string]::IsNullOrWhiteSpace($CurrentConfig.ExportPasswordFile)) { $CurrentConfig.SecretFilePath } else { $CurrentConfig.ExportPasswordFile }

    Show-InputTips -ExtraHint 'Use uma pasta no HD externo. Se o repo nao existir, ele pode ser criado automaticamente.'

    $DestinationRepository = Read-Text -Prompt 'Repositorio de destino (ex.: F:\restic-export)' -Default $CurrentConfig.ExportRepository
    $DestinationPasswordFile = Read-Text -Prompt 'Arquivo de senha do destino' -Default $DefaultExportPasswordFile
    $InitializeIfMissing = Read-YesNo -Prompt 'Inicializar o repositorio de destino se ele nao existir?' -Default $true

    $ExportCommandArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $ExportSnapshotsScript
        '-DestinationRepository'
        $DestinationRepository
        '-DestinationPasswordFile'
        $DestinationPasswordFile
    )

    if (-not $InitializeIfMissing) {
        $ExportCommandArgs += '-RequireExistingDestination'
    }

    & powershell.exe @ExportCommandArgs
    $ExportExitCode = $LASTEXITCODE
    if ($ExportExitCode -ne 0) {
        throw "Exportacao retornou codigo $ExportExitCode"
    }
}

function Start-ExternalDiskTransferFlow {
    param([Parameter(Mandatory)][ValidateSet('Initial', 'Weekly')][string]$Mode)

    if (-not (Test-Path -LiteralPath $ExternalDiskTransferScript)) {
        Write-Warning "Script de transferencia externa nao encontrado: $ExternalDiskTransferScript"
        return
    }

    $CurrentConfig = Get-CurrentConfig
    $DefaultExportPasswordFile = if ([string]::IsNullOrWhiteSpace($CurrentConfig.ExportPasswordFile)) { $CurrentConfig.SecretFilePath } else { $CurrentConfig.ExportPasswordFile }

    Show-FlowHeader -Title $(if ($Mode -eq 'Initial') { 'TRANSFERENCIA COMPLETA (INICIAL)' } else { 'ATUALIZACAO SEMANAL' }) -Goal $(if ($Mode -eq 'Initial') { 'Prepara a estrutura no disco externo e envia todos os snapshots ativos para um segundo repositorio Restic no HD externo.' } else { 'Atualiza esse segundo repositorio Restic no HD externo apenas com os snapshots que ainda faltam.' }) -Bullets @(
        'o disco precisa estar conectado nesta hora',
        'o sistema pede a pasta base no disco e trabalha dentro dela',
        'o kit de recuperacao fica dentro da mesma pasta base'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'No fim desta tela, o sistema mostra o layout completo antes de iniciar a transferencia.'

    $Candidates = Get-ExternalDiskCandidates
    $Selected = Select-ExternalDiskCandidate -Candidates $Candidates -Mode $Mode
    $DefaultFolderPath = Get-DefaultExternalFolderPath -DriveLetter $Selected.DriveLetter -CurrentRepositoryPath $CurrentConfig.ExportRepository
    $ExternalFolderPath = Read-Text -Prompt 'Pasta base no disco externo (relativa a unidade)' -Default $DefaultFolderPath
    $Layout = Get-ExternalDiskTransferLayout -DriveLetter $Selected.DriveLetter -ExternalFolderPath $ExternalFolderPath

    if ($Mode -eq 'Weekly' -and -not (Test-Path -LiteralPath $Layout.RepositoryPath)) {
        throw 'Esse disco ainda nao recebeu a transferencia completa. Rode primeiro a opcao inicial.'
    }

    $TransferArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $ExternalDiskTransferScript
        '-Mode'
        $Mode
        '-DriveLetter'
        $Selected.DriveLetter
        '-ExternalFolderPath'
        $Layout.ExternalFolderPath
        '-DestinationPasswordFile'
        $DefaultExportPasswordFile
    )

    if ($Mode -eq 'Initial') {
        $TransferArgs += '-RefreshRecoveryKit'
    }

    Show-KeyValueSummary -Title 'Resumo da transferencia:' -Pairs ([ordered]@{
        'Modo' = $(if ($Mode -eq 'Initial') { 'transferencia completa inicial' } else { 'atualizacao semanal' })
        'Disco externo' = $Selected.DriveRoot
        'Pasta base' = $Layout.ExternalRoot
        'Repositorio externo' = $Layout.RepositoryPath
        'Kit de recuperacao' = $Layout.RecoveryKitPath
        'Restore staging' = $Layout.RestoreStagingPath
    })

    $Continue = Read-YesNo -Prompt 'Iniciar a transferencia agora?' -Default $true
    if (-not $Continue) {
        throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
    }

    & powershell.exe @TransferArgs
    $TransferExitCode = $LASTEXITCODE
    if ($TransferExitCode -ne 0) {
        throw "Transferencia para disco externo retornou codigo $TransferExitCode"
    }

    Save-ExternalDiskAsDefault -RepositoryPath $Layout.RepositoryPath
}

function Start-ExternalDiskRestoreFlow {
    if (-not (Test-Path -LiteralPath $ExternalDiskTransferScript)) {
        Write-Warning "Script de transferencia externa nao encontrado: $ExternalDiskTransferScript"
        return
    }

    $CurrentConfig = Get-CurrentConfig
    $DefaultExportPasswordFile = if ([string]::IsNullOrWhiteSpace($CurrentConfig.ExportPasswordFile)) { $CurrentConfig.SecretFilePath } else { $CurrentConfig.ExportPasswordFile }

    Show-FlowHeader -Title 'DESEMPACOTAR TUDO NO DISCO EXTERNO' -Goal 'Restaura um snapshot completo do repositorio externo para a area de staging no proprio disco externo.' -Bullets @(
        'isso e indicado para cenarios de desastre ou validacao antes de copiar de volta para o SSD',
        'o destino final fica dentro de restore-staging, na pasta base escolhida',
        'modo rapido nao revalida o conteudo ao final; modo verificado e mais lento, porem mais rigoroso',
        'se voce interromper no meio, a pasta parcial permanece em restore-staging para avaliacao ou limpeza manual'
    ) -ClearScreen

    Show-InputTips -ExtraHint 'No fim desta tela, o sistema mostra o destino completo antes de iniciar o restore.'

    $Candidates = Get-ExternalDiskCandidates
    $Selected = Select-ExternalDiskCandidate -Candidates $Candidates -Mode 'RestoreAll'
    $DefaultFolderPath = Get-DefaultExternalFolderPath -DriveLetter $Selected.DriveLetter -CurrentRepositoryPath $CurrentConfig.ExportRepository
    $ExternalFolderPath = Read-Text -Prompt 'Pasta base no disco externo (relativa a unidade)' -Default $DefaultFolderPath
    $Layout = Get-ExternalDiskTransferLayout -DriveLetter $Selected.DriveLetter -ExternalFolderPath $ExternalFolderPath

    if (-not (Test-Path -LiteralPath $Layout.RepositoryPath)) {
        throw 'Nao existe repositorio Restic nessa pasta base. Rode primeiro a transferencia completa.'
    }

    $SnapshotId = Read-Text -Prompt 'Snapshot para desempacotar' -Default 'latest'
    $RestoreTargetFolderName = Read-Text -Prompt 'Nome da pasta dentro de restore-staging' -Default ('restore_{0}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    $VerifyRestore = Read-YesNo -Prompt 'Validar todo o conteudo ao final? Isso deixa o restore mais lento' -Default $false
    $CleanRestoreTarget = $false

    while ($true) {
        $RestoreTargetPath = Join-Path $Layout.RestoreStagingPath $RestoreTargetFolderName
        $TargetHasItems = (Test-Path -LiteralPath $RestoreTargetPath) -and $null -ne (Get-ChildItem -LiteralPath $RestoreTargetPath -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not $TargetHasItems) {
            break
        }

        Write-Warning 'A pasta de restore escolhida ja contem arquivos. Isso normalmente indica um restore anterior incompleto ou um staging antigo.'
        $RestoreStatusInfo = Get-RestoreStatusInfo -TargetPath $RestoreTargetPath
        if ($null -ne $RestoreStatusInfo) {
            Write-Host 'Ultimo status registrado nessa pasta:' -ForegroundColor DarkCyan
            Write-Host ("- Estado: {0}" -f (Get-RestoreStatusLabel -RawStatus $RestoreStatusInfo.Status)) -ForegroundColor DarkCyan
            if (-not [string]::IsNullOrWhiteSpace($RestoreStatusInfo.Timestamp)) {
                Write-Host ("- Horario: {0}" -f $RestoreStatusInfo.Timestamp) -ForegroundColor DarkCyan
            }
            if (-not [string]::IsNullOrWhiteSpace($RestoreStatusInfo.Snapshot)) {
                Write-Host ("- Snapshot: {0}" -f $RestoreStatusInfo.Snapshot) -ForegroundColor DarkCyan
            }
            if (-not [string]::IsNullOrWhiteSpace($RestoreStatusInfo.Verified)) {
                $VerifiedText = if ($RestoreStatusInfo.Verified -eq 'True') { 'sim' } elseif ($RestoreStatusInfo.Verified -eq 'False') { 'nao' } else { $RestoreStatusInfo.Verified }
                Write-Host ("- Verificacao final: {0}" -f $VerifiedText) -ForegroundColor DarkCyan
            }
            if (-not [string]::IsNullOrWhiteSpace($RestoreStatusInfo.ExitCode) -and $RestoreStatusInfo.ExitCode -ne '0') {
                Write-Host ("- Exit code: {0}" -f $RestoreStatusInfo.ExitCode) -ForegroundColor DarkCyan
            }
            if (-not [string]::IsNullOrWhiteSpace($RestoreStatusInfo.Details)) {
                Write-Host ("- Detalhes: {0}" -f $RestoreStatusInfo.Details) -ForegroundColor DarkCyan
            }
            Write-Host ''
        }

        $CleanRestoreTarget = Read-YesNo -Prompt 'Limpar essa pasta antes de iniciar o novo restore?' -Default $false
        if ($CleanRestoreTarget) {
            break
        }

        $RestoreTargetFolderName = Read-Text -Prompt 'Informe outro nome para a pasta dentro de restore-staging' -Default ('restore_{0}' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    }

    Show-KeyValueSummary -Title 'Resumo do desempacotamento:' -Pairs ([ordered]@{
        'Disco externo' = $Selected.DriveRoot
        'Pasta base' = $Layout.ExternalRoot
        'Repositorio externo' = $Layout.RepositoryPath
        'Snapshot' = $SnapshotId
        'Modo' = $(if ($VerifyRestore) { 'verificado (mais lento)' } else { 'rapido (sem verificacao final)' })
        'Preparacao do destino' = $(if ($CleanRestoreTarget) { 'limpar pasta existente antes do restore' } else { 'usar pasta nova ou vazia' })
        'Destino do restore' = (Join-Path $Layout.RestoreStagingPath $RestoreTargetFolderName)
    })

    $Continue = Read-YesNo -Prompt 'Iniciar o desempacotamento agora?' -Default $true
    if (-not $Continue) {
        throw [System.OperationCanceledException]::new('Operacao cancelada. Nenhuma alteracao foi aplicada.')
    }

    $RestoreArgs = @(
        '-NoLogo'
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $ExternalDiskTransferScript
        '-Mode'
        'RestoreAll'
        '-DriveLetter'
        $Selected.DriveLetter
        '-ExternalFolderPath'
        $Layout.ExternalFolderPath
        '-DestinationPasswordFile'
        $DefaultExportPasswordFile
        '-SnapshotId'
        $SnapshotId
        '-RestoreTargetFolderName'
        $RestoreTargetFolderName
    )

    if ($VerifyRestore) {
        $RestoreArgs += '-VerifyRestore'
    }

    if ($CleanRestoreTarget) {
        $RestoreArgs += '-CleanRestoreTarget'
    }

    & powershell.exe @RestoreArgs
    $RestoreExitCode = $LASTEXITCODE
    if ($RestoreExitCode -ne 0) {
        throw "Desempacotamento retornou codigo $RestoreExitCode"
    }
}

function Show-ExternalDiskTransferMenu {
    while ($true) {
        Clear-Host
        Write-Host '=========================================================' -ForegroundColor Cyan
        Write-Host ' TRANSFERENCIA PARA DISCO EXTERNO' -ForegroundColor Cyan
        Write-Host '=========================================================' -ForegroundColor Cyan

        $CurrentConfig = Get-CurrentConfig
        Write-Host ("Destino padrao atual: {0}" -f $(if ($CurrentConfig.ExportRepository) { $CurrentConfig.ExportRepository } else { '(nao configurado)' })) -ForegroundColor DarkCyan
        Write-Host ''
        Write-Host '[1] Transferencia completa (inicial)'
        Write-Host '    Prepara a pasta base no disco e copia todos os snapshots ativos.' -ForegroundColor DarkCyan
        Write-Host '[2] Atualizacao semanal'
        Write-Host '    Reusa a mesma pasta base e sincroniza somente o que falta.' -ForegroundColor DarkCyan
        Write-Host '[3] Desempacotar tudo no disco externo'
        Write-Host '    Restaura um snapshot completo para restore-staging no proprio disco.' -ForegroundColor DarkCyan
        Write-Host '[0] Voltar ao menu principal'
        Write-Host ''

        $Choice = Read-Host 'Escolha uma opcao'
        if ($null -eq $Choice) {
            break
        }

        switch ($Choice.Trim()) {
            '1' {
                try {
                    Start-ExternalDiskTransferFlow -Mode 'Initial'
                } catch [System.OperationCanceledException] {
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                }
                Read-MenuPause
            }
            '2' {
                try {
                    Start-ExternalDiskTransferFlow -Mode 'Weekly'
                } catch [System.OperationCanceledException] {
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                }
                Read-MenuPause
            }
            '3' {
                try {
                    Start-ExternalDiskRestoreFlow
                } catch [System.OperationCanceledException] {
                    Write-Host $_.Exception.Message -ForegroundColor Yellow
                }
                Read-MenuPause
            }
            '0' {
                break
            }
            default {
                Write-Warning 'Opcao invalida.'
                Read-MenuPause
            }
        }
    }
}

while ($true) {
    Clear-Host
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host ' RESTIC - CENTRO DE CONTROLE INTERATIVO' -ForegroundColor Cyan
    Write-Host '=========================================================' -ForegroundColor Cyan
    Write-Host 'Fluxo recomendado para primeira configuracao: [6] caminhos -> [4] fontes -> [3] retencao -> [2] agendamento' -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host 'VISUALIZACAO E DIAGNOSTICO' -ForegroundColor Cyan
    Write-Host '[1] Painel resumido da configuracao'
    Write-Host '[14] Visualizar snapshots mantidos pela politica'
    Write-Host '[12] Configuracao tecnica completa'
    Write-Host '[8] Testar envio Telegram'
    Write-Host ''
    Write-Host 'CONFIGURACAO' -ForegroundColor Cyan
    Write-Host '[2] Agendamento do backup, check e espelho externo'
    Write-Host '[3] Politica de retencao de snapshots'
    Write-Host '[4] Fontes e exclusoes do backup'
    Write-Host '[5] Telegram (token e chat)'
    Write-Host '[6] Caminhos principais e destino externo'
    Write-Host '[7] Perfis salvos'
    Write-Host '[13] Assistente completo avancado'
    Write-Host ''
    Write-Host 'OPERACOES' -ForegroundColor Cyan
    Write-Host '[9] Rodar backup agora'
    Write-Host '[10] Restore de snapshot'
    Write-Host '[11] Transferencia para DISCO EXTERNO'
    Write-Host '[0] Sair'
    Write-Host ''
    Write-Host 'Dica: nas telas de edicao, digite "voltar" para cancelar sem aplicar nada.' -ForegroundColor DarkCyan
    Write-Host ''

    $Choice = Read-Host 'Escolha uma opcao'
    if ($null -eq $Choice) {
        break
    }

    $ChoiceText = $Choice.Trim()
    if ([string]::IsNullOrWhiteSpace($ChoiceText)) {
        if ([Console]::IsInputRedirected) {
            break
        }

        Write-Warning 'Opcao vazia. Informe um numero do menu.'
        Read-MenuPause
        continue
    }

    try {
        switch ($ChoiceText) {
            '1' {
                Show-ConfigDashboard
                Read-MenuPause
            }
            '2' {
                Update-ScheduleSettings
                Read-MenuPause
            }
            '3' {
                Update-RetentionSettings
                Read-MenuPause
            }
            '4' {
                Update-BackupSourceSettings
                Read-MenuPause
            }
            '5' {
                Update-TelegramSettings
                Read-MenuPause
            }
            '6' {
                Update-PathSettings
                Read-MenuPause
            }
            '7' {
                Show-ProfileMenu
            }
            '8' {
                Test-TelegramPing
                Read-MenuPause
            }
            '9' {
                Start-BackupNow
                Read-MenuPause
            }
            '10' {
                Start-RestoreFlow
                Read-MenuPause
            }
            '11' {
                Show-ExternalDiskTransferMenu
            }
            '12' {
                & $ShowScript
                Read-MenuPause
            }
            '14' {
                Show-RetentionLayoutPreview
                Read-MenuPause
            }
            '13' {
                & $EnvHelperScript -Interactive
                Read-MenuPause
            }
            '0' {
                break
            }
            default {
                Write-Warning 'Opcao invalida.'
                Read-MenuPause
            }
        }
    } catch [System.OperationCanceledException] {
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        Read-MenuPause
    } catch {
        if ($null -ne $PSItem) {
            Write-Host "[ERRO] $($PSItem.Exception.Message)" -ForegroundColor Red
        } else {
            Write-Host '[ERRO] Erro inesperado no Centro de Controle.' -ForegroundColor Red
        }
        Read-MenuPause
    }
}
