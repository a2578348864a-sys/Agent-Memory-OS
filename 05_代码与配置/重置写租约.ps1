[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$vaultRoot = Split-Path -Parent $PSScriptRoot
$leaseScript = Join-Path $vaultRoot "lease.ps1"
$output = & $leaseScript recover -Force:$Force
Write-Host $output
return $output