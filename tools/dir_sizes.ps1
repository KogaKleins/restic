[CmdletBinding()]
param(
    [string]$DriveRoot = $env:SystemDrive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$QualifiedRoot = if ($DriveRoot.EndsWith('\')) { $DriveRoot } else { "$DriveRoot\" }
$Results = foreach ($Directory in (Get-ChildItem -Path $QualifiedRoot -Directory -Force)) {
    $Size = (Get-ChildItem -Path $Directory.FullName -Recurse -Force | Measure-Object -Property Length -Sum).Sum
    [pscustomobject]@{
        Name   = $Directory.Name
        SizeGB = [math]::Round($Size / 1GB, 2)
    }
}

$Results | Sort-Object SizeGB -Descending | Format-Table -AutoSize
