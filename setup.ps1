[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$vaultRoot = $PSScriptRoot
$leaseScript = Join-Path $vaultRoot "lease.ps1"
$initOutRaw = & $leaseScript init
$initOut = $initOutRaw | ConvertFrom-Json

$lintScript = Join-Path (Join-Path $vaultRoot "05_代码与配置") "知识库lint检查器.ps1"
$lintOutRaw = & $lintScript
$lintOut = $lintOutRaw | ConvertFrom-Json

$summary = [ordered]@{
    ok = ($initOut.ok -and $lintOut.ok)
    vaultId = $initOut.vaultId
    leaseRevision = $initOut.revision
    cardsChecked = $lintOut.cards_checked
    lintIssues = $lintOut.summary.issues
    message = "Agent-Memory-OS setup completed successfully."
}

return ($summary | ConvertTo-Json)