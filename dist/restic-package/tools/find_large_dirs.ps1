[CmdletBinding()]
param(
    [string[]]$Paths = @(
        (Join-Path $env:SystemDrive 'Users')
        (Join-Path $env:SystemDrive 'ProgramData')
        (Join-Path $env:windir 'Temp')
        $env:TEMP
        (Join-Path $env:SystemDrive 'tmp')
        (Join-Path $env:SystemDrive 'temp')
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$Targets = $Paths |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique

foreach ($TargetPath in $Targets) {
    if (Test-Path -LiteralPath $TargetPath) {
        $Size = (Get-ChildItem -Path $TargetPath -Recurse -Force | Measure-Object -Property Length -Sum).Sum
        $SizeGB = [math]::Round($Size / 1GB, 2)
        Write-Host "$TargetPath - $SizeGB GB"
    }
}
