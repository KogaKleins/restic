#Requires -Version 5.1
<#
.SYNOPSIS
    Instalador interativo do backup Restic para Windows.
.DESCRIPTION
    Copia os scripts para uma pasta de destino, instala ou baixa o Restic,
    grava as variaveis RESTIC_* no Windows, inicializa o repositorio se preciso
    e registra as tarefas no Task Scheduler.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword',
    'PasswordFilePath',
    Justification = 'PasswordFilePath recebe apenas o caminho do arquivo de senha do Restic, nao a senha em texto puro.'
)]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDir = '',
    [ValidateSet('UseExisting', 'Winget', 'DownloadOfficial')][string]$ResticInstallMethod = '',
    [string]$ResticExe = '',
    [ValidateSet('User', 'Machine')][string]$Scope = '',
    [string]$Repository = '',
    [string]$PasswordFilePath = '',
    [SecureString]$NewRepositoryPassword,
    [Nullable[bool]]$InitializeRepository = $null,
    [string]$LogDir = '',
    [int]$LogKeepDays = 30,
    [string]$TelegramToken = '',
    [string]$TelegramChatId = '',
    [string[]]$BackupSources = @(),
    [string[]]$BackupExcludes = @(),
    [int]$KeepLast = 7,
    [int]$KeepWeekly = 4,
    [int]$KeepMonthly = 3,
    [string]$BackupTime = '',
    [switch]$CreateCheckTask,
    [ValidateSet('partial', 'full')][string]$CheckMode = 'partial',
    [ValidateSet('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')][string]$CheckDay = 'Sunday',
    [string]$CheckTime = '03:30',
    [ValidateSet('CurrentUser', 'Password', 'System')][string]$RunAs = 'CurrentUser',
    [string]$TaskUserName = '',
    [SecureString]$TaskPassword,
    [switch]$HighestPrivileges,
    [switch]$RunBackupAfterInstall,
    [switch]$SkipTaskRegistration,
    [switch]$SkipResticValidation,
    [switch]$SkipRepositoryValidation,
    [switch]$SkipTelegramValidation,
    [switch]$NonInteractive,
    [ValidateSet('User', 'Machine')][string]$ResticWingetScope = 'Machine',
    [string]$ResticDownloadDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SetupScriptDir = $PSScriptRoot
$ScriptSourceDir = Split-Path -Parent $SetupScriptDir

function Get-DefaultBackupSources {
    return @(
        (Join-Path $env:SystemDrive 'Users')
    )
}

function Get-DefaultBackupExcludes {
    return @(
        'AppData\Local\Temp'
        'AppData\Local\Packages'
        'AppData\Local\Microsoft\Windows\INetCache'
        'AppData\Local\Google\Chrome\User Data\Default\Cache'
        'AppData\Local\Microsoft\Edge\User Data\Default\Cache'
        'OneDrive\Temp'
        '*.tmp'
        '.codex'
        '.cache'
        'AppData\Local\Microsoft\WindowsApps'
        'CodexSandboxOffline'
    )
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory)][SecureString]$Value)

    $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
    }
}

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

function Read-ChoiceValue {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Options,
        [int]$DefaultIndex = 0
    )

    if ($NonInteractive) {
        return $Options[$DefaultIndex]
    }

    while ($true) {
        Write-Host ''
        Write-Host $Title -ForegroundColor Cyan
        for ($Index = 0; $Index -lt $Options.Count; $Index++) {
            Write-Host ("[{0}] {1}" -f ($Index + 1), $Options[$Index])
        }

        $Prompt = "Escolha uma opcao [$($DefaultIndex + 1)]"
        $Raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $Options[$DefaultIndex]
        }

        $Selected = 0
        if ([int]::TryParse($Raw, [ref]$Selected) -and $Selected -ge 1 -and $Selected -le $Options.Count) {
            return $Options[$Selected - 1]
        }

        Write-Warning 'Opcao invalida.'
    }
}

function Read-StringValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$CurrentValue = '',
        [string]$DefaultValue = '',
        [switch]$AllowEmpty
    )

    if ($NonInteractive) {
        if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
            return $CurrentValue.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            return $DefaultValue.Trim()
        }
        if ($AllowEmpty) {
            return ''
        }

        throw "Valor obrigatorio ausente para: $Prompt"
    }

    while ($true) {
        $Suffix = ''
        if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
            $Suffix = " [$CurrentValue]"
        } elseif (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            $Suffix = " [$DefaultValue]"
        }

        $Raw = Read-Host ($Prompt + $Suffix)
        if ([string]::IsNullOrWhiteSpace($Raw)) {
            if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
                return $CurrentValue.Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
                return $DefaultValue.Trim()
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

function Read-IntValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$CurrentValue,
        [int]$DefaultValue,
        [int]$MinValue = 0
    )

    if ($NonInteractive) {
        if ($CurrentValue -ge $MinValue) {
            return $CurrentValue
        }

        return $DefaultValue
    }

    while ($true) {
        $Raw = Read-Host ("{0} [{1}]" -f $Prompt, $CurrentValue)
        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $CurrentValue
        }

        $Parsed = 0
        if ([int]::TryParse($Raw, [ref]$Parsed) -and $Parsed -ge $MinValue) {
            return $Parsed
        }

        Write-Warning "Informe um numero inteiro maior ou igual a $MinValue."
    }
}

function Read-BoolValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [bool]$DefaultValue = $false,
        [Nullable[bool]]$CurrentValue = $null
    )

    if ($CurrentValue -ne $null) {
        return [bool]$CurrentValue
    }

    if ($NonInteractive) {
        return $DefaultValue
    }

    $DefaultDisplay = if ($DefaultValue) { 'S' } else { 'N' }
    while ($true) {
        $Raw = Read-Host ("{0} [S/N] ({1})" -f $Prompt, $DefaultDisplay)
        if ([string]::IsNullOrWhiteSpace($Raw)) {
            return $DefaultValue
        }

        switch ($Raw.Trim().ToUpperInvariant()) {
            'S' { return $true }
            'Y' { return $true }
            'N' { return $false }
            default { Write-Warning 'Responda com S ou N.' }
        }
    }
}

function Read-ListValue {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string[]]$CurrentValue = @(),
        [string[]]$DefaultValue = @(),
        [switch]$AllowEmpty
    )

    if ($NonInteractive) {
        if ($CurrentValue.Count -gt 0) {
            return $CurrentValue
        }
        if ($DefaultValue.Count -gt 0) {
            return $DefaultValue
        }
        if ($AllowEmpty) {
            return @()
        }

        throw "Valor obrigatorio ausente para: $Prompt"
    }

    $EffectiveDefault = if ($CurrentValue.Count -gt 0) { $CurrentValue } else { $DefaultValue }
    $Display = if ($EffectiveDefault.Count -gt 0) { $EffectiveDefault -join ';' } else { '' }
    $DisplaySuffix = ''
    if (-not [string]::IsNullOrWhiteSpace($Display)) {
        $DisplaySuffix = " [$Display]"
    }
    $Raw = Read-Host ("{0}{1}" -f $Prompt, $DisplaySuffix)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        if ($EffectiveDefault.Count -gt 0) {
            return $EffectiveDefault
        }
        if ($AllowEmpty) {
            return @()
        }

        Write-Warning 'Este campo e obrigatorio.'
        return (Read-ListValue -Prompt $Prompt -CurrentValue $CurrentValue -DefaultValue $DefaultValue -AllowEmpty:$AllowEmpty)
    }

    return @(
        $Raw -split ';' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Read-SecureStringValue {
    param([Parameter(Mandatory)][string]$Prompt)

    if ($NonInteractive) {
        if ($NewRepositoryPassword) {
            return $NewRepositoryPassword
        }

        throw "Valor seguro obrigatorio ausente para: $Prompt"
    }

    return Read-Host $Prompt -AsSecureString
}

function Copy-DistributionFiles {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestinationDir
    )

    $SourceFull = [System.IO.Path]::GetFullPath($SourceDir)
    $DestinationFull = [System.IO.Path]::GetFullPath($DestinationDir)
    $RootFilesToCopy = @(
        'README.md'
        'install.bat'
        'backup.bat'
        'check.bat'
        'sincronizar_externo.bat'
        'ativar_agora.bat'
        'centro_de_controle.bat'
        'configurar.bat'
        '.gitignore'
    )
    $DirectoriesToCopy = @(
        'app'
        'setup'
        'tools'
    )
    $RuntimeDirs = @(
        (Join-Path $DestinationFull 'runtime\bin')
        (Join-Path $DestinationFull 'runtime\logs')
        (Join-Path $DestinationFull 'runtime\secrets')
    )

    if ($PSCmdlet.ShouldProcess($DestinationFull, 'Ensure distribution layout')) {
        New-Item -ItemType Directory -Path $DestinationFull -Force | Out-Null
        foreach ($RuntimeDir in $RuntimeDirs) {
            New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        }
    }

    if ($SourceFull.TrimEnd('\') -eq $DestinationFull.TrimEnd('\')) {
        return
    }

    if ($PSCmdlet.ShouldProcess($DestinationFull, 'Copy project files')) {
        foreach ($RootFileName in $RootFilesToCopy) {
            $SourceFilePath = Join-Path $SourceFull $RootFileName
            if (Test-Path -LiteralPath $SourceFilePath) {
                Copy-Item -LiteralPath $SourceFilePath -Destination (Join-Path $DestinationFull $RootFileName) -Force
            }
        }

        foreach ($DirectoryName in $DirectoriesToCopy) {
            $SourceDirectoryPath = Join-Path $SourceFull $DirectoryName
            if (Test-Path -LiteralPath $SourceDirectoryPath) {
                Copy-Item -LiteralPath $SourceDirectoryPath -Destination $DestinationFull -Recurse -Force
            }
        }
    }
}

function Resolve-ResticCommandPath {
    $Command = Get-Command restic -ErrorAction SilentlyContinue
    if ($Command) {
        return $Command.Source
    }

    foreach ($Candidate in @(
        (Join-Path $env:ProgramFiles 'WinGet\Links\restic.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\restic.exe')
    )) {
        if (Test-Path $Candidate) {
            return $Candidate
        }
    }

    return ''
}

function Install-ResticWithWinget {
    param([Parameter(Mandatory)][ValidateSet('User', 'Machine')][string]$Scope)

    $Winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $Winget) {
        throw 'winget nao esta disponivel nesta maquina.'
    }

    if ($PSCmdlet.ShouldProcess("restic via winget ($Scope)", 'Install package')) {
        & $Winget.Source install --exact --id restic.restic --scope $Scope --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -ne 0 -and -not (Resolve-ResticCommandPath)) {
            throw "Falha ao instalar o restic via winget. ExitCode: $LASTEXITCODE"
        }
    }

    $Resolved = Resolve-ResticCommandPath
    if ([string]::IsNullOrWhiteSpace($Resolved)) {
        throw 'Nao foi possivel localizar restic.exe apos a instalacao via winget.'
    }

    return $Resolved
}

function Install-ResticFromGitHub {
    param([Parameter(Mandatory)][string]$DestinationDir)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $DestinationDir = [System.IO.Path]::GetFullPath($DestinationDir)
    $DestinationExe = Join-Path $DestinationDir 'restic.exe'

    if ($PSCmdlet.ShouldProcess($DestinationExe, 'Download official restic binary')) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null

        $Release = Invoke-RestMethod -Uri 'https://api.github.com/repos/restic/restic/releases/latest' -Headers @{ 'User-Agent' = 'GitHub-Copilot' }
        $Asset = $Release.assets | Where-Object { $_.name -match 'windows_amd64\.zip$' } | Select-Object -First 1
        if (-not $Asset) {
            throw 'Nao foi possivel localizar o asset windows_amd64 do Restic na release mais recente.'
        }

        $TempRoot = Join-Path $env:TEMP ('restic-install-' + [guid]::NewGuid().ToString('N'))
        $ZipFile = Join-Path $TempRoot $Asset.name
        $ExpandedDir = Join-Path $TempRoot 'expanded'

        try {
            New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
            Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipFile
            Expand-Archive -Path $ZipFile -DestinationPath $ExpandedDir -Force

            $Executable = Get-ChildItem -Path $ExpandedDir -Filter '*.exe' -Recurse | Select-Object -First 1
            if (-not $Executable) {
                throw 'Nao foi encontrado um executavel do Restic dentro do zip baixado.'
            }

            Copy-Item -Path $Executable.FullName -Destination $DestinationExe -Force
            Unblock-File -Path $DestinationExe -ErrorAction SilentlyContinue
        } finally {
            if (Test-Path $TempRoot) {
                Remove-Item -Path $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $DestinationExe
}

function Test-ResticExecutable {
    param([Parameter(Mandatory)][string]$ResticExe)

    if ($SkipResticValidation) {
        Write-Warning 'Validacao do restic.exe ignorada por parametro.'
        return
    }

    if ($WhatIfPreference) {
        Write-Host '[WHATIF] restic.exe seria validado com o comando "restic version".' -ForegroundColor Yellow
        return
    }

    try {
        $VersionOutput = & $ResticExe version 2>&1
    } catch {
        throw "Falha ao executar restic.exe em: $ResticExe. $_"
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao validar restic.exe em: $ResticExe. ExitCode: $LASTEXITCODE"
    }

    $VersionLine = [string]($VersionOutput | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($VersionLine)) {
        $VersionLine = $ResticExe
    }

    Write-Host "[OK] Restic validado: $VersionLine" -ForegroundColor Green
}

function Get-RepositoryLocationInfo {
    param([Parameter(Mandatory)][string]$Path)

    $Info = [ordered]@{
        Path      = $Path
        Kind      = 'Caminho'
        Root      = ''
        Exists    = (Test-Path -LiteralPath $Path)
        DriveType = $null
    }

    if ($Path -match '^\\') {
        $Info.Kind = 'UNC'
        return [pscustomobject]$Info
    }

    if ($Path -match '^[A-Za-z]:\\') {
        $Drive = (Split-Path -Path $Path -Qualifier).TrimEnd('\')
        $Info.Root = "$Drive\"
        try {
            $DriveInfo = New-Object System.IO.DriveInfo($Info.Root)
            $Info.DriveType = [string]$DriveInfo.DriveType
            switch ($DriveInfo.DriveType) {
                ([System.IO.DriveType]::Network) {
                    $Info.Kind = 'Unidade mapeada'
                }

                ([System.IO.DriveType]::Fixed) {
                    $Info.Kind = 'Disco local'
                }

                default {
                    $Info.Kind = 'Caminho com unidade'
                }
            }
        } catch {
            $Info.Kind = 'Caminho com unidade'
        }
    }

    return [pscustomobject]$Info
}

function Show-RepositoryAccessGuidance {
    param(
        [Parameter(Mandatory)]$RepositoryInfo,
        [Parameter(Mandatory)][ValidateSet('CurrentUser', 'Password', 'System')][string]$RunAs
    )

    Write-Host "[INFO] Destino do repositorio: $($RepositoryInfo.Kind) | $($RepositoryInfo.Path)" -ForegroundColor Cyan

    switch ($RepositoryInfo.Kind) {
        'Unidade mapeada' {
            Write-Warning 'O repositorio esta em unidade mapeada. No Task Scheduler isso costuma falhar fora da sessao interativa. Prefira um caminho UNC como \\servidor\share\pasta.'
            if ($RunAs -ne 'CurrentUser') {
                Write-Warning "A conta $RunAs quase certamente nao herdara a mesma unidade mapeada da sessao atual."
            }
        }

        'UNC' {
            if ($RunAs -eq 'System') {
                Write-Warning 'Repositorio em UNC com SYSTEM exige que a conta do computador tenha permissao no compartilhamento.'
            }
        }
    }
}

function Test-PasswordFileReadability {
    param([Parameter(Mandatory)][string]$Path)

    if ($WhatIfPreference -and -not (Test-Path -LiteralPath $Path)) {
        Write-Host '[WHATIF] Arquivo de senha seria validado quanto a existencia e leitura.' -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Arquivo de senha nao encontrado em: $Path"
    }

    try {
        $null = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    } catch {
        throw "Falha ao ler o arquivo de senha em: $Path. $_"
    }

    Write-Host "[OK] Arquivo de senha acessivel: $Path" -ForegroundColor Green
}

function Test-TelegramConfiguration {
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ChatId
    )

    if ($SkipTelegramValidation) {
        Write-Warning 'Validacao do Telegram ignorada por parametro.'
        return
    }

    if ($WhatIfPreference) {
        Write-Host '[WHATIF] Token e Chat ID do Telegram seriam validados via getMe e getChat.' -ForegroundColor Yellow
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $Headers = @{ 'User-Agent' = 'GitHub-Copilot' }

    try {
        $Me = Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/getMe" -f $Token) -Headers $Headers
        $EncodedChatId = [System.Uri]::EscapeDataString($ChatId)
        $Chat = Invoke-RestMethod -Uri ("https://api.telegram.org/bot{0}/getChat?chat_id={1}" -f $Token, $EncodedChatId) -Headers $Headers
    } catch {
        throw "Falha ao validar Telegram. Confirme token, Chat ID, conectividade e se o bot ja recebeu /start. $_"
    }

    $BotLabel = if ($Me.result.username) { "@$($Me.result.username)" } else { [string]$Me.result.first_name }
    $ChatLabel = if ($Chat.result.title) {
        [string]$Chat.result.title
    } elseif ($Chat.result.username) {
        "@$($Chat.result.username)"
    } else {
        [string]$Chat.result.id
    }

    Write-Host "[OK] Telegram validado: bot $BotLabel, chat $ChatLabel" -ForegroundColor Green
}

function Test-BackupSourcePaths {
    param([Parameter(Mandatory)][string[]]$Paths)

    foreach ($SourcePath in $Paths) {
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            Write-Warning "Fonte de backup nao encontrada no momento: $SourcePath"
        }
    }
}

function Test-ResticRepositoryAccess {
    param(
        [Parameter(Mandatory)][string]$ResticExe,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$PasswordFilePath
    )

    if ($SkipRepositoryValidation) {
        Write-Warning 'Validacao de acesso ao repositorio ignorada por parametro.'
        return
    }

    if ($WhatIfPreference) {
        Write-Host '[WHATIF] Acesso ao repositorio seria validado com o comando "restic snapshots".' -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $Repository)) {
        throw "Repositorio nao encontrado ou inacessivel em: $Repository"
    }

    try {
        $RepositoryOutput = & $ResticExe snapshots --repo $Repository --password-file $PasswordFilePath --no-lock 2>&1
    } catch {
        throw "Falha ao validar acesso ao repositorio em: $Repository. $_"
    }

    if ($LASTEXITCODE -ne 0) {
        $LastMessage = [string]($RepositoryOutput | Select-Object -Last 1)
        throw "Falha ao validar acesso ao repositorio. Verifique caminho, senha e permissoes. $LastMessage"
    }

    Write-Host "[OK] Acesso ao repositorio validado: $Repository" -ForegroundColor Green
}

function Write-PasswordFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][SecureString]$Password
    )

    $Path = [System.IO.Path]::GetFullPath($Path)
    $PlainText = Convert-SecureStringToPlainText -Value $Password
    try {
        if ($PSCmdlet.ShouldProcess($Path, 'Write password file')) {
            $Directory = Split-Path -Parent $Path
            if (-not [string]::IsNullOrWhiteSpace($Directory)) {
                New-Item -ItemType Directory -Path $Directory -Force | Out-Null
            }

            $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($Path, $PlainText, $Utf8NoBom)
        }
    } finally {
        $PlainText = $null
    }
}

function Initialize-ResticRepositoryIfRequested {
    param(
        [Parameter(Mandatory)][string]$ResticExe,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$PasswordFilePath,
        [Parameter(Mandatory)][bool]$ShouldInitialize
    )

    if (-not $ShouldInitialize) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Repository, 'Initialize restic repository')) {
        if ($Repository -match '^[A-Za-z]:\\' -and -not (Test-Path $Repository)) {
            New-Item -ItemType Directory -Path $Repository -Force | Out-Null
        }

        & $ResticExe init --repo $Repository --password-file $PasswordFilePath
        if ($LASTEXITCODE -ne 0) {
            throw "Falha ao inicializar o repositorio Restic. ExitCode: $LASTEXITCODE"
        }
    }
}

Write-Host 'Instalador interativo do Restic Backup' -ForegroundColor Cyan
Write-Host 'Esse fluxo prepara os scripts, Restic, variaveis e tarefas.' -ForegroundColor Cyan

$InstallDir = Read-StringValue -Prompt 'Pasta base da instalacao' -CurrentValue $InstallDir -DefaultValue $ScriptSourceDir
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

Copy-DistributionFiles -SourceDir $ScriptSourceDir -DestinationDir $InstallDir

$SetupScriptPath = Join-Path $InstallDir 'setup\setup_env.ps1'
if (-not (Test-Path $SetupScriptPath)) {
    $SetupScriptPath = Join-Path $ScriptSourceDir 'setup\setup_env.ps1'
}

$RegisterTasksScriptPath = Join-Path $InstallDir 'setup\register_tasks.ps1'
if (-not (Test-Path $RegisterTasksScriptPath)) {
    $RegisterTasksScriptPath = Join-Path $ScriptSourceDir 'setup\register_tasks.ps1'
}

$ResticInstallMethod = if ([string]::IsNullOrWhiteSpace($ResticInstallMethod)) {
    Read-ChoiceValue -Title 'Como deseja preparar o Restic?' -Options @('UseExisting', 'Winget', 'DownloadOfficial') -DefaultIndex 0
} else {
    $ResticInstallMethod
}

switch ($ResticInstallMethod) {
    'UseExisting' {
        $DefaultRestic = if ($ResticExe) { $ResticExe } else { Resolve-ResticCommandPath }
        $ResticExe = Read-StringValue -Prompt 'Caminho completo do restic.exe' -CurrentValue $ResticExe -DefaultValue $DefaultRestic
        if (-not (Test-Path $ResticExe)) {
            throw "restic.exe nao encontrado em: $ResticExe"
        }
    }

    'Winget' {
        $ResticWingetScopeDefaultIndex = 0
        if ($ResticWingetScope -eq 'User') {
            $ResticWingetScopeDefaultIndex = 1
        }
        $ResticWingetScope = Read-ChoiceValue -Title 'Escopo do winget para instalar o Restic' -Options @('Machine', 'User') -DefaultIndex $ResticWingetScopeDefaultIndex
        $ResticExe = Install-ResticWithWinget -Scope $ResticWingetScope
    }

    'DownloadOfficial' {
        if ([string]::IsNullOrWhiteSpace($ResticDownloadDir)) {
            $ResticDownloadDir = Join-Path $InstallDir 'runtime\bin'
        }
        $ResticDownloadDir = Read-StringValue -Prompt 'Pasta onde o restic.exe sera colocado' -CurrentValue $ResticDownloadDir -DefaultValue (Join-Path $InstallDir 'runtime\bin')
        $ResticExe = Install-ResticFromGitHub -DestinationDir $ResticDownloadDir
    }
}

Test-ResticExecutable -ResticExe $ResticExe

$Repository = Read-StringValue -Prompt 'Caminho do repositorio Restic' -CurrentValue $Repository
$PasswordFilePath = Read-StringValue -Prompt 'Caminho do arquivo de senha do Restic' -CurrentValue $PasswordFilePath -DefaultValue (Join-Path $InstallDir 'runtime\secrets\restic-password.txt')
$LogDir = Read-StringValue -Prompt 'Pasta de logs' -CurrentValue $LogDir -DefaultValue (Join-Path $InstallDir 'runtime\logs')

$Scope = if ([string]::IsNullOrWhiteSpace($Scope)) {
    Read-ChoiceValue -Title 'Escopo das variaveis de ambiente' -Options @('User', 'Machine') -DefaultIndex 0
} else {
    $Scope
}

$RunAs = if ($PSBoundParameters.ContainsKey('RunAs')) {
    $RunAs
} else {
    Read-ChoiceValue -Title 'Conta que executara as tarefas' -Options @('CurrentUser', 'Password', 'System') -DefaultIndex 0
}

if ($RunAs -eq 'System' -and $Scope -ne 'Machine') {
    Write-Warning 'SYSTEM nao deve depender de variaveis no escopo User. O escopo sera ajustado para Machine.'
    $Scope = 'Machine'
}

$RepositoryLocationInfo = Get-RepositoryLocationInfo -Path $Repository
Show-RepositoryAccessGuidance -RepositoryInfo $RepositoryLocationInfo -RunAs $RunAs

if (-not (Test-Path $PasswordFilePath)) {
    $CreatePasswordFile = Read-BoolValue -Prompt 'Arquivo de senha nao existe. Deseja criar agora?' -DefaultValue $true
    if ($CreatePasswordFile) {
        $Password1 = if ($NewRepositoryPassword) { $NewRepositoryPassword } else { Read-SecureStringValue -Prompt 'Digite a senha do repositorio' }
        $Password2 = if ($NonInteractive) { $Password1 } else { Read-Host 'Confirme a senha do repositorio' -AsSecureString }
        $Plain1 = Convert-SecureStringToPlainText -Value $Password1
        $Plain2 = Convert-SecureStringToPlainText -Value $Password2
        try {
            if ($Plain1 -ne $Plain2) {
                throw 'As senhas informadas nao coincidem.'
            }
        } finally {
            $Plain1 = $null
            $Plain2 = $null
        }

        Write-PasswordFile -Path $PasswordFilePath -Password $Password1
    } elseif (-not $WhatIfPreference) {
        throw "Arquivo de senha nao encontrado em: $PasswordFilePath"
    }
}

Test-PasswordFileReadability -Path $PasswordFilePath

$InitializeRepository = Read-BoolValue -Prompt 'Deseja inicializar o repositorio Restic agora?' -DefaultValue (-not (Test-Path (Join-Path $Repository 'config'))) -CurrentValue $InitializeRepository

$EnableTelegram = Read-BoolValue -Prompt 'Deseja configurar notificacoes via Telegram?' -DefaultValue (-not [string]::IsNullOrWhiteSpace($TelegramToken))
if ($EnableTelegram) {
    $TelegramToken = Read-StringValue -Prompt 'Token do bot do Telegram' -CurrentValue $TelegramToken
    $TelegramChatId = Read-StringValue -Prompt 'Chat ID que recebera as notificacoes' -CurrentValue $TelegramChatId
    Test-TelegramConfiguration -Token $TelegramToken -ChatId $TelegramChatId
} else {
    $TelegramToken = ''
    $TelegramChatId = ''
}

if ($BackupSources.Count -eq 0) {
    $BackupSources = Get-DefaultBackupSources
}
if ($BackupExcludes.Count -eq 0) {
    $BackupExcludes = Get-DefaultBackupExcludes
}

$BackupSources = Read-ListValue -Prompt 'Fontes de backup separadas por ;' -CurrentValue $BackupSources -DefaultValue (Get-DefaultBackupSources)
$BackupExcludes = Read-ListValue -Prompt 'Exclusoes separadas por ;' -CurrentValue $BackupExcludes -DefaultValue (Get-DefaultBackupExcludes) -AllowEmpty
Test-BackupSourcePaths -Paths $BackupSources

$KeepLast = Read-IntValue -Prompt 'Quantidade de snapshots recentes (keep-last)' -CurrentValue $KeepLast -DefaultValue 7 -MinValue 1
$KeepWeekly = Read-IntValue -Prompt 'Quantidade de snapshots semanais (keep-weekly)' -CurrentValue $KeepWeekly -DefaultValue 4 -MinValue 0
$KeepMonthly = Read-IntValue -Prompt 'Quantidade de snapshots mensais (keep-monthly)' -CurrentValue $KeepMonthly -DefaultValue 3 -MinValue 0
$LogKeepDays = Read-IntValue -Prompt 'Dias para manter logs' -CurrentValue $LogKeepDays -DefaultValue 30 -MinValue 1

if (-not $SkipTaskRegistration) {
    $BackupTime = Read-StringValue -Prompt 'Horario diario do backup (HH:mm)' -CurrentValue $BackupTime -DefaultValue '02:00'
    if (-not $PSBoundParameters.ContainsKey('CreateCheckTask')) {
        $CreateCheckTask = Read-BoolValue -Prompt 'Deseja cadastrar tambem a tarefa de check?' -DefaultValue $true
    }

    if ($CreateCheckTask) {
        if (-not $PSBoundParameters.ContainsKey('CheckMode')) {
            $CheckMode = Read-ChoiceValue -Title 'Modo do check' -Options @('partial', 'full') -DefaultIndex 0
        }
        if (-not $PSBoundParameters.ContainsKey('CheckDay')) {
            $CheckDay = Read-ChoiceValue -Title 'Dia da semana para o check' -Options @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday') -DefaultIndex 0
        }
        $CheckTime = Read-StringValue -Prompt 'Horario do check semanal (HH:mm)' -CurrentValue $CheckTime -DefaultValue '03:30'
    }

    if (-not $PSBoundParameters.ContainsKey('HighestPrivileges')) {
        $SuggestedHighestPrivileges = ($RunAs -eq 'System')
        $HighestPrivileges = Read-BoolValue -Prompt 'Executar as tarefas com privilegios mais altos?' -DefaultValue $SuggestedHighestPrivileges
    }

    if ($RunAs -eq 'Password') {
        $TaskUserName = Read-StringValue -Prompt 'Usuario da tarefa (DOMINIO\\Usuario ou Maquina\\Usuario)' -CurrentValue $TaskUserName -DefaultValue (Get-CurrentWindowsIdentityName)
        if (-not $TaskPassword) {
            $TaskPassword = Read-Host 'Senha da conta que executara a tarefa' -AsSecureString
        }
    }
}

if ($PSCmdlet.ShouldProcess($LogDir, 'Ensure log directory')) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

Initialize-ResticRepositoryIfRequested -ResticExe $ResticExe -Repository $Repository -PasswordFilePath $PasswordFilePath -ShouldInitialize $InitializeRepository
Test-ResticRepositoryAccess -ResticExe $ResticExe -Repository $Repository -PasswordFilePath $PasswordFilePath

$SetupArgs = @{
    Scope          = $Scope
    ResticExe      = $ResticExe
    Repository     = $Repository
    SecretFilePath = $PasswordFilePath
    LogDir         = $LogDir
    LogKeepDays    = $LogKeepDays
    TelegramToken  = $TelegramToken
    TelegramChatId = $TelegramChatId
    KeepLast       = $KeepLast
    KeepWeekly     = $KeepWeekly
    KeepMonthly    = $KeepMonthly
    BackupSources  = $BackupSources
    BackupExcludes = $BackupExcludes
}

& $SetupScriptPath @SetupArgs -WhatIf:$WhatIfPreference

if (-not $SkipTaskRegistration) {
    $TaskArgs = @{
        InstallDir         = $InstallDir
        BackupTime         = $BackupTime
        CreateCheckTask    = $CreateCheckTask
        CheckMode          = $CheckMode
        CheckDay           = $CheckDay
        CheckTime          = $CheckTime
        RunAs              = $RunAs
        HighestPrivileges  = $HighestPrivileges
    }

    if ($RunAs -eq 'Password') {
        $PlainTaskPassword = Convert-SecureStringToPlainText -Value $TaskPassword
        try {
            $TaskArgs.UserName = $TaskUserName
            $TaskArgs.TaskPassword = $PlainTaskPassword
            & $RegisterTasksScriptPath @TaskArgs -WhatIf:$WhatIfPreference
        } finally {
            $PlainTaskPassword = $null
        }
    } else {
        & $RegisterTasksScriptPath @TaskArgs -WhatIf:$WhatIfPreference
    }
}

if (-not $PSBoundParameters.ContainsKey('RunBackupAfterInstall')) {
    $RunBackupAfterInstall = Read-BoolValue -Prompt 'Deseja rodar um backup de validacao agora?' -DefaultValue $false
}

if ($RunBackupAfterInstall) {
    $BackupScriptPath = Join-Path $InstallDir 'app\backup.ps1'
    if (-not (Test-Path $BackupScriptPath)) {
        $BackupScriptPath = Join-Path $ScriptSourceDir 'app\backup.ps1'
    }

    if ($PSCmdlet.ShouldProcess($BackupScriptPath, 'Run validation backup')) {
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $BackupScriptPath
        $BackupValidationExitCode = $LASTEXITCODE
        if ($BackupValidationExitCode -ne 0) {
            throw "O backup de validacao retornou codigo $BackupValidationExitCode"
        }
    }
}

Write-Host ''
Write-Host 'Instalacao concluida.' -ForegroundColor Cyan
Write-Host "- Pasta base: $InstallDir" -ForegroundColor Cyan
Write-Host "- Restic: $ResticExe" -ForegroundColor Cyan
Write-Host "- Repositorio: $Repository" -ForegroundColor Cyan
Write-Host "- Password file: $PasswordFilePath" -ForegroundColor Cyan
Write-Host "- Log dir: $LogDir" -ForegroundColor Cyan
Write-Host "- Scope env: $Scope" -ForegroundColor Cyan
Write-Host "- Tipo do repositorio: $($RepositoryLocationInfo.Kind)" -ForegroundColor Cyan
if (-not $SkipTaskRegistration) {
    Write-Host "- Backup diario: $BackupTime" -ForegroundColor Cyan
    if ($CreateCheckTask) {
        Write-Host "- Check semanal: $CheckDay $CheckTime ($CheckMode)" -ForegroundColor Cyan
    }
}