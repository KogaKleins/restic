#Requires -Version 5.1
<#
.SYNOPSIS
    Gera uma copia limpa do projeto pronta para distribuicao.
.DESCRIPTION
    Exporta apenas os arquivos distribuidos publicamente e recria runtime/
    vazio, sem logs, segredos ou binarios locais da maquina atual.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$OutputDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\restic-package'),
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$DestinationRoot = [System.IO.Path]::GetFullPath($OutputDir)

$RootFilesToCopy = @(
    'README.md'
    'install.bat'
    'backup.bat'
    'check.bat'
    'sincronizar_externo.bat'
    'ativar_agora.bat'
    'configurar.bat'
    'preparar_distribuicao.bat'
    '.gitignore'
)

$DirectoriesToCopy = @(
    'app'
    'setup'
    'tools'
)

$RuntimeDirs = @(
    (Join-Path $DestinationRoot 'runtime\bin')
    (Join-Path $DestinationRoot 'runtime\logs')
    (Join-Path $DestinationRoot 'runtime\secrets')
)

if ($SourceRoot.TrimEnd('\') -eq $DestinationRoot.TrimEnd('\')) {
    throw 'OutputDir nao pode ser a mesma pasta do projeto atual.'
}

if (Test-Path -LiteralPath $DestinationRoot) {
    $ExistingItems = @(Get-ChildItem -LiteralPath $DestinationRoot -Force)
    if ($ExistingItems.Count -gt 0) {
        if (-not $Force) {
            throw 'OutputDir ja existe e nao esta vazio. Use -Force para limpar e recriar o pacote.'
        }

        if ($PSCmdlet.ShouldProcess($DestinationRoot, 'Limpar pasta de distribuicao existente')) {
            $ExistingItems | Remove-Item -Recurse -Force
        }
    }
} elseif ($PSCmdlet.ShouldProcess($DestinationRoot, 'Criar pasta de distribuicao')) {
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
}

if ($PSCmdlet.ShouldProcess($DestinationRoot, 'Copiar arquivos publicos do projeto')) {
    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

    foreach ($RootFileName in $RootFilesToCopy) {
        $SourceFilePath = Join-Path $SourceRoot $RootFileName
        if (Test-Path -LiteralPath $SourceFilePath) {
            Copy-Item -LiteralPath $SourceFilePath -Destination (Join-Path $DestinationRoot $RootFileName) -Force
        }
    }

    foreach ($DirectoryName in $DirectoriesToCopy) {
        $SourceDirectoryPath = Join-Path $SourceRoot $DirectoryName
        if (Test-Path -LiteralPath $SourceDirectoryPath) {
            Copy-Item -LiteralPath $SourceDirectoryPath -Destination $DestinationRoot -Recurse -Force
        }
    }

    foreach ($RuntimeDir in $RuntimeDirs) {
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        Set-Content -Path (Join-Path $RuntimeDir '.gitkeep') -Value '' -Encoding ASCII
    }
}

Write-Host ''
Write-Host 'Pacote limpo preparado com sucesso.' -ForegroundColor Cyan
Write-Host "- Origem: $SourceRoot" -ForegroundColor Cyan
Write-Host "- Destino: $DestinationRoot" -ForegroundColor Cyan
Write-Host '- Runtime exportado sem logs, segredos e binarios locais.' -ForegroundColor Cyan