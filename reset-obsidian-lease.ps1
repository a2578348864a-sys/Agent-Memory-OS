$ErrorActionPreference = "Stop"
$VaultDir = $PSScriptRoot
$codeDir = (Get-ChildItem -LiteralPath $VaultDir -Directory | Where-Object { $_.Name -like "05_*" })[0].FullName
$scriptPath = Join-Path $codeDir "重置写租约.ps1"
$filteredArgs = @($args | Where-Object { $_ -ne "noninteractive" })
& $scriptPath @filteredArgs
exit $LASTEXITCODE