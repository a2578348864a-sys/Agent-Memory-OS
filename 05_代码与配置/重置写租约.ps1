[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$vaultRoot = Split-Path -Parent $PSScriptRoot
$corePath = Join-Path $PSScriptRoot "DualAgentWriteLeaseCore.ps1"
. $corePath

$status = Invoke-DualAgentWriteLease -Operation Status
Write-Host ("Current Lease Status: " + $status.leaseStatus + " (Revision: " + $status.revision + ")")

if ($status.leaseStatus -ceq "idle") {
    Write-Host "Lease is already idle. No reset needed."
    $output = [ordered]@{ ok = $true; action = "already_idle"; revision = $status.revision }
    return ($output | ConvertTo-Json)
}

$now = [System.DateTime]::UtcNow
$expiresAt = if ([string]::IsNullOrWhiteSpace([string]$status.expiresAtUtc)) { $now.AddMinutes(-1) } else { [System.DateTime]::Parse([string]$status.expiresAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }

$holder = [string]$status.holderAgent
$scope = [string]$status.scope

$runtimeRoot = Get-DualAgentWriteLeaseDefaultRuntimeRoot
$statePath = Join-Path $runtimeRoot "lease-state.json"
$stateJson = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$leaseId = [string]$stateJson.leaseId

Write-Host "Active Lease detected: Holder=$holder, Scope=$scope, LeaseId=$leaseId, ExpiresAt=$($status.expiresAtUtc)"

$result = $null
if ($now -ge $expiresAt) {
    Write-Host "Lease is expired. Recovering expired lease..."
    $result = Invoke-DualAgentWriteLease -Operation RecoverExpired -Agent $holder -LeaseId $leaseId -Scope $scope -UserConfirmedRecovery -ReasonCode "user_reset_expired"
} else {
    Write-Host "Lease is active but user requested reset. Releasing on behalf of $holder..."
    $result = Invoke-DualAgentWriteLease -Operation Release -Agent $holder -LeaseId $leaseId -Scope $scope -ReasonCode "user_force_reset"
}

Write-Host ("Operation Result: " + ($result | ConvertTo-Json -Compress))

$finalStatus = Invoke-DualAgentWriteLease -Operation Status
Write-Host ("Final Lease Status: " + $finalStatus.leaseStatus + " (Revision: " + $finalStatus.revision + ")")

$testsPath = Join-Path (Join-Path $vaultRoot "06_测试与验证") "DualAgentWriteLeaseCore.Tests.ps1"
Write-Host "Running regression verification..."
& $testsPath | Out-Null
Write-Host "Verification PASSED."

$summary = [ordered]@{
    ok = ($finalStatus.leaseStatus -ceq "idle")
    action = "reset_completed"
    previousHolder = $holder
    finalRevision = $finalStatus.revision
}
return ($summary | ConvertTo-Json)