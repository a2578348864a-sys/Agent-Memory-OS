<#
.SYNOPSIS
    Lightweight CLI wrapper for Local Multi-Agent Write Lease operations.
.DESCRIPTION
    Provides commands: init, setup, status, acquire, renew, release, recover.
    Agents and scripts interact with this CLI rather than calling internal core directly.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet("init", "setup", "status", "acquire", "renew", "release", "recover")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Agent,

    [string]$LeaseId,

    [ValidateSet("automation_full_run", "nightly_health", "interactive_write")]
    [string]$Scope = "interactive_write",

    [int]$TtlSeconds = 300,

    [string]$ReasonCode = "interactive_work",

    [switch]$Force,

    [string]$TestOnlyNowUtc = "",

    [string]$RuntimeRoot = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$vaultRoot = $PSScriptRoot
$coreScript = Join-Path (Join-Path $vaultRoot "05_代码与配置") "DualAgentWriteLeaseCore.ps1"
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    throw "DualAgentWriteLeaseCore.ps1 not found at $coreScript"
}
. $coreScript

# Ensure vault metadata exists
$metaFile = Join-Path $vaultRoot ".agent-memory-os.json"
$vaultId = Get-DualAgentWriteLeaseVaultId -VaultRoot $vaultRoot
$meta = [ordered]@{
    vaultId = $vaultId
    vaultRootPath = [IO.Path]::GetFullPath($vaultRoot)
    initializedAtUtc = [System.DateTime]::UtcNow.ToString("o")
    schemaVersion = 1
}
[System.IO.File]::WriteAllText($metaFile, ($meta | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))

if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) {
    $RuntimeRoot = Get-DualAgentWriteLeaseDefaultRuntimeRoot -VaultRoot $vaultRoot
}
if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) {
    [void][System.IO.Directory]::CreateDirectory($RuntimeRoot)
}

$isFixture = Test-DualAgentWriteLeasePathInside -ChildPath $RuntimeRoot -RootPath ([IO.Path]::GetTempPath())

function Invoke-LeaseCliInit {
    $current = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $RuntimeRoot -AllowSystemTempFixture:$isFixture
    if ($current.status -ceq "blocked") {
        return [ordered]@{
            ok = $false
            action = "blocked"
            reasonCode = $current.reasonCode
            error = $current.reasonCode
        }
    }
    if ($current.revision -eq 0) {
        $initResult = Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $RuntimeRoot -ReasonCode "initial_setup" -AllowSystemTempFixture:$isFixture
        return [ordered]@{
            ok = $true
            action = "initialized"
            vaultId = (Get-DualAgentWriteLeaseVaultId -VaultRoot $vaultRoot)
            revision = $initResult.revision
            leaseStatus = "idle"
        }
    }
    return [ordered]@{
        ok = $true
        action = "already_initialized"
        vaultId = (Get-DualAgentWriteLeaseVaultId -VaultRoot $vaultRoot)
        revision = $current.revision
        leaseStatus = $current.leaseStatus
    }
}

try {
    switch ($Command.ToLowerInvariant()) {
        "init" {
            $res = Invoke-LeaseCliInit
            return ($res | ConvertTo-Json)
        }
        "setup" {
            $res = Invoke-LeaseCliInit
            return ($res | ConvertTo-Json)
        }
        "status" {
            $st = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
            if ($st.status -ceq "blocked") {
                $res = [ordered]@{
                    ok = $false
                    command = "status"
                    error = $st.reasonCode
                }
                Write-Output ($res | ConvertTo-Json)
                exit 1
            }
            $res = [ordered]@{
                ok = $true
                vaultId = (Get-DualAgentWriteLeaseVaultId -VaultRoot $vaultRoot)
                leaseStatus = $st.leaseStatus
                holderAgent = $st.holderAgent
                scope = $st.scope
                revision = $st.revision
                acquiredAtUtc = $st.acquiredAtUtc
                expiresAtUtc = $st.expiresAtUtc
            }
            return ($res | ConvertTo-Json)
        }
        "acquire" {
            if ([string]::IsNullOrWhiteSpace($Agent)) {
                throw "agent_required: Specify -Agent (e.g. codex, claude, gemini, cursor, windsurf)"
            }
            $curr = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $RuntimeRoot -AllowSystemTempFixture:$isFixture
            if ($curr.status -cne "blocked" -and $curr.revision -eq 0) {
                [void](Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $RuntimeRoot -ReasonCode "auto_init_on_acquire" -AllowSystemTempFixture:$isFixture)
            }
            if ($TtlSeconds -lt 60) { $TtlSeconds = 60 }
            if ([string]::IsNullOrWhiteSpace($ReasonCode)) { $ReasonCode = "interactive_work" }

            $acq = Invoke-DualAgentWriteLease -Operation Acquire -Agent $Agent -Scope $Scope -TtlSeconds $TtlSeconds -ReasonCode $ReasonCode -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
            if ($acq.status -cne "ok") {
                $res = [ordered]@{
                    ok = $false
                    status = $acq.status
                    reasonCode = $acq.reasonCode
                    message = "Failed to acquire lease: $($acq.reasonCode)"
                }
                return ($res | ConvertTo-Json)
            }
            $res = [ordered]@{
                ok = $true
                leaseStatus = $acq.leaseStatus
                holderAgent = $acq.holderAgent
                leaseId = $acq.leaseId
                scope = $acq.scope
                revision = $acq.revision
                expiresAtUtc = $acq.expiresAtUtc
            }
            return ($res | ConvertTo-Json)
        }
        "renew" {
            if ([string]::IsNullOrWhiteSpace($Agent)) { throw "agent_required" }
            if ([string]::IsNullOrWhiteSpace($LeaseId)) {
                $stateFile = Join-Path $RuntimeRoot "lease-state.json"
                if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
                    $sj = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
                    $LeaseId = [string]$sj.leaseId
                }
            }
            if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw "lease_id_required" }
            if ($TtlSeconds -lt 60) { $TtlSeconds = 60 }

            $ren = Invoke-DualAgentWriteLease -Operation Renew -Agent $Agent -LeaseId $LeaseId -Scope $Scope -TtlSeconds $TtlSeconds -ReasonCode $ReasonCode -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
            if ($ren.status -cne "ok") {
                $res = [ordered]@{
                    ok = $false
                    status = $ren.status
                    reasonCode = $ren.reasonCode
                    message = "Failed to renew lease: $($ren.reasonCode)"
                }
                return ($res | ConvertTo-Json)
            }
            $res = [ordered]@{
                ok = $true
                leaseStatus = $ren.leaseStatus
                holderAgent = $ren.holderAgent
                leaseId = $ren.leaseId
                revision = $ren.revision
                expiresAtUtc = $ren.expiresAtUtc
            }
            return ($res | ConvertTo-Json)
        }
        "release" {
            if ([string]::IsNullOrWhiteSpace($Agent)) { throw "agent_required" }
            if ([string]::IsNullOrWhiteSpace($LeaseId)) {
                $stateFile = Join-Path $RuntimeRoot "lease-state.json"
                if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
                    $sj = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
                    if ($sj.holderAgent -ceq $Agent) {
                        $LeaseId = [string]$sj.leaseId
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($LeaseId)) {
                throw "lease_id_required_or_not_held_by_agent"
            }

            $rel = Invoke-DualAgentWriteLease -Operation Release -Agent $Agent -LeaseId $LeaseId -Scope $Scope -ReasonCode $ReasonCode -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
            if ($rel.status -cne "ok") {
                $res = [ordered]@{
                    ok = $false
                    status = $rel.status
                    reasonCode = $rel.reasonCode
                    message = "Failed to release lease: $($rel.reasonCode)"
                }
                return ($res | ConvertTo-Json)
            }
            $res = [ordered]@{
                ok = $true
                leaseStatus = $rel.leaseStatus
                revision = $rel.revision
                action = "released"
            }
            return ($res | ConvertTo-Json)
        }
        "recover" {
            $st = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
            if ($st.status -ceq "blocked") {
                $res = [ordered]@{
                    ok = $false
                    command = "recover"
                    error = $st.reasonCode
                }
                Write-Output ($res | ConvertTo-Json)
                exit 1
            }
            if ($st.revision -eq 0) {
                $initRes = Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $RuntimeRoot -ReasonCode "recover_init" -AllowSystemTempFixture:$isFixture
                $res = [ordered]@{
                    ok = $true
                    action = "initialized"
                    revision = $initRes.revision
                    leaseStatus = "idle"
                }
                return ($res | ConvertTo-Json)
            }
            if ($st.leaseStatus -ceq "idle") {
                $res = [ordered]@{
                    ok = $true
                    action = "already_idle"
                    revision = $st.revision
                    leaseStatus = "idle"
                }
                return ($res | ConvertTo-Json)
            }
            $now = if (-not [string]::IsNullOrWhiteSpace($TestOnlyNowUtc)) {
                ConvertTo-DualAgentWriteLeaseUtc -Value $TestOnlyNowUtc
            } else {
                [DateTimeOffset]::UtcNow
            }
            $expiresAt = if ([string]::IsNullOrWhiteSpace([string]$st.expiresAtUtc)) { $now.AddMinutes(-1) } else { ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$st.expiresAtUtc) }
            $holder = [string]$st.holderAgent
            $stateFile = Join-Path $RuntimeRoot "lease-state.json"
            $stateJson = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            $lid = [string]$stateJson.leaseId

            if ($now -ge $expiresAt) {
                $rec = Invoke-DualAgentWriteLease -Operation RecoverExpired -Agent $holder -LeaseId $lid -Scope $st.scope -UserConfirmedRecovery -ReasonCode "auto_recovered_expired" -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
                $res = [ordered]@{
                    ok = ($rec.status -ceq "ok")
                    action = "recovered_expired"
                    previousHolder = $holder
                    revision = $rec.revision
                    leaseStatus = "idle"
                }
                return ($res | ConvertTo-Json)
            } else {
                if (-not $Force) {
                    $res = [ordered]@{
                        ok = $false
                        action = "rejected_active_lease"
                        reason = "lease_active_unexpired"
                        holderAgent = $holder
                        expiresAtUtc = $st.expiresAtUtc
                        message = "Lease is active and has not expired. Pass -Force to force release."
                    }
                    Write-Output ($res | ConvertTo-Json)
                    exit 1
                }
                $fr = Invoke-DualAgentWriteLease -Operation Release -Agent $holder -LeaseId $lid -Scope $st.scope -ReasonCode "force_user_reset" -RuntimeRoot $RuntimeRoot -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$isFixture
                $res = [ordered]@{
                    ok = ($fr.status -ceq "ok")
                    action = "force_released"
                    previousHolder = $holder
                    revision = $fr.revision
                    leaseStatus = "idle"
                }
                return ($res | ConvertTo-Json)
            }
        }
    }
} catch {
    $errRes = [ordered]@{
        ok = $false
        command = $Command
        error = $_.Exception.Message
    }
    Write-Output ($errRes | ConvertTo-Json)
    exit 1
}