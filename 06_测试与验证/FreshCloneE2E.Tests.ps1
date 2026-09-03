<#
.SYNOPSIS
    End-to-End Fresh Clone User Journey Verification Suite for Agent-Memory-OS.
.DESCRIPTION
    Comprehensive 7-phase E2E suite covering:
    1. Fresh Clone Setup & Init
    2. Concurrency & Lock Acquisition (Codex vs Claude)
    3. Safe Reset Protection (Unforced rejected, Force released)
    3B. Formal Vault Test-Clock Protection (Strictly blocked, zero state/ledger mutation)
    4. Real RecoverExpired via Test Clock on TEMP Fixture (asserts 'expired_recovered' event on disk)
    5. Promote Dual Lease Gates & Fault-Injected Rollback:
       - 5a. Idle blocked (draft/index/formal zero change hash assertion)
       - 5b. Wrong agent blocked (draft/index/formal zero change hash assertion)
       - 5c. Wrong leaseId blocked (draft/index/formal zero change hash assertion)
       - 5d. Gate 5 Pre-Publish lease verification failure (draft/index/formal zero change hash assertion)
       - 5e. Mid-transaction injected failure after target write:
             * staging TEMP does not exist
             * .bak/.tmp zero residue
             * draft hash identical
             * index hash identical
             * formal card does not exist
             * vault lint clean
       - 5f. Valid promote with active lease -> verified card created, lint clean
    6. Backup Archive Creation & SHA256 Verification
    7. Multi-Vault Concurrency & Mutex Isolation
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:PassedTests = 0
$script:FailedTests = 0

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:PassedTests++
        Write-Host "  [PASS] $Message" -ForegroundColor Green
    } else {
        $script:FailedTests++
        Write-Host "  [FAIL] $Message" -ForegroundColor Red
        throw "Assertion failed: $Message"
    }
}

function Get-FileSha256OrEmpty {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "NONE" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
    } finally {
        $sha.Dispose()
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("AgentMemoryOS-E2E-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
$vault1 = Join-Path $tempBase "Vault-1"
$vault2 = Join-Path $tempBase "Vault-2"
$vaultClock = Join-Path $tempBase "Vault-Clock"

Write-Host "=========================================================="
Write-Host "Starting Agent-Memory-OS Fresh-Clone E2E Test Suite"
Write-Host "Test Environment: $tempBase"
Write-Host "=========================================================="

try {
    [void][System.IO.Directory]::CreateDirectory($vault1)
    [void][System.IO.Directory]::CreateDirectory($vault2)
    [void][System.IO.Directory]::CreateDirectory($vaultClock)

    # Simulate fresh clone by copying tracked files only
    Copy-Item (Join-Path $repoRoot "*") -Destination $vault1 -Recurse -Force
    Copy-Item (Join-Path $repoRoot "*") -Destination $vault2 -Recurse -Force
    Copy-Item (Join-Path $repoRoot "*") -Destination $vaultClock -Recurse -Force

    foreach ($v in @($vault1, $vault2, $vaultClock)) {
        $meta = Join-Path $v ".agent-memory-os.json"
        if (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force }
        $bk = Join-Path $v "_backups"
        if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse -Force }
    }

    # ----------------------------------------------------
    Write-Host "`n--- STEP 1: Fresh Clone Setup & Init (Vault 1) ---"
    # ----------------------------------------------------
    $setupOutRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "setup.ps1")
    $setupOut = $setupOutRaw | ConvertFrom-Json
    Assert-Test ($setupOut.ok -eq $true) "Setup script executed successfully"
    Assert-Test (-not [string]::IsNullOrWhiteSpace($setupOut.vaultId)) "Vault 1 assigned unique vaultId: $($setupOut.vaultId)"
    Assert-Test ($setupOut.leaseRevision -eq 1) "Initial lease revision is 1 (idle baseline)"
    Assert-Test ($setupOut.cardsChecked -ge 3) "Initial sample cards checked ($($setupOut.cardsChecked) cards)"
    Assert-Test ($setupOut.lintIssues -eq 0) "Zero initial lint issues in fresh clone"

    # ----------------------------------------------------
    Write-Host "`n--- STEP 2: Concurrency & Lock Acquisition (Codex vs Claude) ---"
    # ----------------------------------------------------
    $acqCodexRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") acquire codex
    $acqCodex = $acqCodexRaw | ConvertFrom-Json
    Assert-Test ($acqCodex.ok -eq $true) "Codex acquired write lease successfully"
    Assert-Test ($acqCodex.leaseStatus -eq "active") "Lease status is active"
    Assert-Test ($acqCodex.holderAgent -eq "codex") "Lease holder is codex"
    Assert-Test (-not [string]::IsNullOrWhiteSpace($acqCodex.leaseId)) "Generated valid leaseId: $($acqCodex.leaseId)"

    # Claude concurrent attempt (MUST BE REJECTED)
    $acqClaudeRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") acquire claude
    $acqClaude = $acqClaudeRaw | ConvertFrom-Json
    Assert-Test ($acqClaude.ok -eq $false) "Claude concurrent acquire was rejected"
    Assert-Test ($acqClaude.status -eq "blocked") "Rejection status is 'blocked'"
    Assert-Test ($acqClaude.reasonCode -eq "lease_busy") "Rejection reasonCode is 'lease_busy'"

    # ----------------------------------------------------
    Write-Host "`n--- STEP 3: Safe Reset & Force Release Protection ---"
    # ----------------------------------------------------
    # Reset without -Force while active unexpired (MUST BE REJECTED)
    $resetSafeRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") recover
    $resetSafe = $resetSafeRaw | ConvertFrom-Json
    Assert-Test ($resetSafe.ok -eq $false) "Unforced recover refused on active lease"
    Assert-Test ($resetSafe.action -eq "rejected_active_lease") "Action reported: rejected_active_lease"

    # Reset with -Force (MUST SUCCEED)
    $resetForceRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") recover -Force
    $resetForce = $resetForceRaw | ConvertFrom-Json
    Assert-Test ($resetForce.ok -eq $true) "Forced recover succeeded"
    Assert-Test ($resetForce.action -eq "force_released") "Action reported: force_released"
    Assert-Test ($resetForce.leaseStatus -eq "idle") "Lease restored to idle"

    # ----------------------------------------------------
    Write-Host "`n--- STEP 3B: Formal Vault Test-Clock Protection ---"
    # ----------------------------------------------------
    # Formal non-TEMP vault runtime root is in $env:LOCALAPPDATA
    $v1RuntimeRoot = Join-Path (Join-Path $env:LOCALAPPDATA "AgentMemoryOS") (Join-Path $setupOut.vaultId "write-lease")
    $stateFileV1 = Join-Path $v1RuntimeRoot "lease-state.json"
    $ledgerFileV1 = Join-Path $v1RuntimeRoot "lease-events.jsonl"
    $stateHashBeforeClock = Get-FileSha256OrEmpty $stateFileV1
    $ledgerHashBeforeClock = Get-FileSha256OrEmpty $ledgerFileV1

    # Attempting to use TestOnlyNowUtc on formal non-TEMP vault (MUST BE BLOCKED)
    $clockAttemptRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") status -TestOnlyNowUtc "2026-09-04T01:00:00.0000000Z"
    $clockAttempt = $clockAttemptRaw | ConvertFrom-Json
    Assert-Test ($clockAttempt.ok -eq $false) "TestOnlyNowUtc on formal non-TEMP vault was strictly blocked"
    Assert-Test ($clockAttempt.error -eq "lease_test_time_rejected") "Error reported: lease_test_time_rejected"

    $stateHashAfterClock = Get-FileSha256OrEmpty $stateFileV1
    $ledgerHashAfterClock = Get-FileSha256OrEmpty $ledgerFileV1
    Assert-Test ($stateHashBeforeClock -eq $stateHashAfterClock) "Formal lease state hash is byte-for-byte identical after blocked clock attempt"
    Assert-Test ($ledgerHashBeforeClock -eq $ledgerHashAfterClock) "Formal lease ledger hash is byte-for-byte identical after blocked clock attempt"

    # ----------------------------------------------------
    Write-Host "`n--- STEP 4: Real RecoverExpired via Test Clock on TEMP Fixture ---"
    # ----------------------------------------------------
    $clockRuntimeRoot = Join-Path $vaultClock "runtime-lease"
    [void][System.IO.Directory]::CreateDirectory($clockRuntimeRoot)

    [void](powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vaultClock "lease.ps1") init -RuntimeRoot $clockRuntimeRoot)
    $clockAcqRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vaultClock "lease.ps1") acquire claude -TtlSeconds 60 -RuntimeRoot $clockRuntimeRoot
    $clockAcq = $clockAcqRaw | ConvertFrom-Json
    Assert-Test ($clockAcq.ok -eq $true -and $clockAcq.holderAgent -eq "claude") "Claude acquired short 60s lease in clock fixture"

    # Advance clock 5 minutes into the future
    $futureTime = [DateTime]::UtcNow.AddMinutes(5).ToString("yyyy-MM-ddTHH:mm:ss.0000000Z")
    $statusExpiredRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vaultClock "lease.ps1") status -TestOnlyNowUtc $futureTime -RuntimeRoot $clockRuntimeRoot
    $statusExpired = $statusExpiredRaw | ConvertFrom-Json
    Assert-Test ($statusExpired.leaseStatus -eq "expired") "Status under advanced clock detected as 'expired'"

    # Execute recover WITHOUT -Force
    $recoverExpiredRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vaultClock "lease.ps1") recover -TestOnlyNowUtc $futureTime -RuntimeRoot $clockRuntimeRoot
    $recoverExpired = $recoverExpiredRaw | ConvertFrom-Json
    Assert-Test ($recoverExpired.ok -eq $true) "Recover without -Force succeeded on expired lease"
    Assert-Test ($recoverExpired.action -eq "recovered_expired") "Action reported: 'recovered_expired'"
    Assert-Test ($recoverExpired.leaseStatus -eq "idle") "Lease restored to idle after real expired recovery"

    # Directly check lease-events.jsonl on disk
    $eventsLines = @(Get-Content -LiteralPath (Join-Path $clockRuntimeRoot "lease-events.jsonl") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $lastEvent = $eventsLines[-1] | ConvertFrom-Json
    Assert-Test ($lastEvent.eventType -eq "expired_recovered") "Last ledger event in lease-events.jsonl on disk is 'expired_recovered'"

    # ----------------------------------------------------
    Write-Host "`n--- STEP 5: Promote Dual Lease Gates & Fault-Injected Rollback ---"
    # ----------------------------------------------------
    $draftFile = Join-Path (Join-Path (Join-Path $vault1 "02_知识卡片") "_drafts") "e2e-demo-card.md"
    $formalFile = Join-Path (Join-Path $vault1 "02_知识卡片") "e2e-demo-card.md"
    $indexFile = Join-Path (Join-Path $vault1 "08_复盘与沉淀") "自动复用索引.md"

    $goodDraft = @"
---
status: draft
scope: cross-project
verified_at: 1970-01-01
source: raw/e2e-test-source.md
evidence_level: needs-more-evidence
---
# E2E Verified Draft Card
## 结论
E2E verified card conclusion.
## 适用场景
Applies to E2E testing scenarios.
## 最小做法
Execute setup and verify.
## 验证
Verified via test suite.
## 不适用
Not applicable outside testing.
## 风险
Zero residual risk.
## 来源
- sourceId: raw
- relativePath: e2e-test-source.md
"@
    [System.IO.File]::WriteAllText($draftFile, $goodDraft, [System.Text.UTF8Encoding]::new($false))
    $initialDraftHash = Get-FileSha256OrEmpty $draftFile
    $initialIndexHash = Get-FileSha256OrEmpty $indexFile

    # 5a. Promote when lease is IDLE (MUST BE BLOCKED with zero hash change)
    $idleBlocked = $false
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "promote-draft.ps1") -DraftName "e2e-demo-card" -Agent "codex"
    } catch {
        $idleBlocked = $true
    }
    if ($LASTEXITCODE -ne 0) { $idleBlocked = $true }
    Assert-Test ($idleBlocked -eq $true) "Promote blocked when lease is idle"
    Assert-Test ((Get-FileSha256OrEmpty $draftFile) -eq $initialDraftHash) "Idle blocked: draft hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $indexFile) -eq $initialIndexHash) "Idle blocked: index hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $formalFile) -eq "NONE") "Idle blocked: formal card was not created"

    # 5b. Codex acquires active lease
    $codexLeaseRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") acquire codex
    $codexLease = $codexLeaseRaw | ConvertFrom-Json
    Assert-Test ($codexLease.ok -eq $true) "Codex acquired lease for draft promotion"

    # 5c. Wrong Agent (Claude) attempts promote (MUST BE BLOCKED with zero hash change)
    $wrongAgentBlocked = $false
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "promote-draft.ps1") -DraftName "e2e-demo-card" -Agent "claude"
    } catch {
        $wrongAgentBlocked = $true
    }
    if ($LASTEXITCODE -ne 0) { $wrongAgentBlocked = $true }
    Assert-Test ($wrongAgentBlocked -eq $true) "Promote blocked when called with wrong agent identity"
    Assert-Test ((Get-FileSha256OrEmpty $draftFile) -eq $initialDraftHash) "Wrong agent blocked: draft hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $indexFile) -eq $initialIndexHash) "Wrong agent blocked: index hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $formalFile) -eq "NONE") "Wrong agent blocked: formal card was not created"

    # 5d. Wrong LeaseId attempts promote (MUST BE BLOCKED with zero hash change)
    $wrongIdBlocked = $false
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "promote-draft.ps1") -DraftName "e2e-demo-card" -Agent "codex" -LeaseId "00000000000000000000000000000000"
    } catch {
        $wrongIdBlocked = $true
    }
    if ($LASTEXITCODE -ne 0) { $wrongIdBlocked = $true }
    Assert-Test ($wrongIdBlocked -eq $true) "Promote blocked when called with mismatched leaseId"
    Assert-Test ((Get-FileSha256OrEmpty $draftFile) -eq $initialDraftHash) "Wrong leaseId blocked: draft hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $indexFile) -eq $initialIndexHash) "Wrong leaseId blocked: index hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $formalFile) -eq "NONE") "Wrong leaseId blocked: formal card was not created"

    # 5d2. Gate 5 Pre-Publish Lease Verification Failure (MUST BE BLOCKED with zero hash change)
    $prePublishBlocked = $false
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "promote-draft.ps1") -DraftName "e2e-demo-card" -Agent "codex" -TestFailPrePublishLeaseCheck
    } catch {
        $prePublishBlocked = $true
    }
    if ($LASTEXITCODE -ne 0) { $prePublishBlocked = $true }
    Assert-Test ($prePublishBlocked -eq $true) "Promote blocked upon Gate 5 pre-publish lease check failure"
    Assert-Test ((Get-FileSha256OrEmpty $draftFile) -eq $initialDraftHash) "Pre-publish blocked: draft hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $indexFile) -eq $initialIndexHash) "Pre-publish blocked: index hash 100% unchanged"
    Assert-Test ((Get-FileSha256OrEmpty $formalFile) -eq "NONE") "Pre-publish blocked: formal card was not created"

    # 5e. Injected Failure After Target Write (MUST TRIGGER FULL ROLLBACK)
    $failInjected = $false
    try {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "promote-draft.ps1") -DraftName "e2e-demo-card" -Agent "codex" -TestInjectFailureAfterTargetWrite
    } catch {
        $failInjected = $true
    }
    if ($LASTEXITCODE -ne 0) { $failInjected = $true }
    Assert-Test ($failInjected -eq $true) "Promote aborted cleanly upon injected mid-transaction failure"
    Assert-Test (Test-Path -LiteralPath $draftFile -PathType Leaf) "Rollback successfully restored draft card in _drafts/"
    Assert-Test ((Get-FileSha256OrEmpty $draftFile) -eq $initialDraftHash) "Rollback: draft hash identical to initial draft hash"
    Assert-Test ((Get-FileSha256OrEmpty $indexFile) -eq $initialIndexHash) "Rollback: index hash identical to initial index hash"
    Assert-Test ((Get-FileSha256OrEmpty $formalFile) -eq "NONE") "Rollback: formal card does not exist"

    # Direct assertion on staging TEMP and residue .bak/.tmp
    $residualFiles = @(Get-ChildItem -LiteralPath $vault1 -Recurse -File | Where-Object { $_.Extension -in @(".bak", ".tmp") })
    Assert-Test ($residualFiles.Count -eq 0) ".bak/.tmp zero residue across vault"
    $stageDirs = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter "promote-stage-*")
    Assert-Test ($stageDirs.Count -eq 0) "staging TEMP directory does not exist (fully cleaned)"

    $lintPreRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $vault1 "05_代码与配置") "知识库lint检查器.ps1") -VaultPath $vault1
    $lintPre = $lintPreRaw | ConvertFrom-Json
    Assert-Test ($lintPre.ok -eq $true -and $lintPre.summary.issues -eq 0) "Vault remains 100% lint-clean after transaction rollback"

    # 5f. Valid Promote with Active Lease
    $promoteRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "promote-draft.ps1") -DraftName "e2e-demo-card" -Agent "codex"
    $promote = $promoteRaw | ConvertFrom-Json
    Assert-Test ($promote.ok -eq $true) "Draft card promoted successfully under valid lease"
    Assert-Test ($promote.action -eq "promoted") "Action reported: promoted"

    Assert-Test (Test-Path -LiteralPath $formalFile -PathType Leaf) "Promoted formal card exists in 02_知识卡片/"
    Assert-Test (-not (Test-Path -LiteralPath $draftFile -PathType Leaf)) "Draft file was removed from _drafts/"

    $formalText = [System.IO.File]::ReadAllText($formalFile, [System.Text.Encoding]::UTF8)
    Assert-Test ($formalText -match "status:\s*verified") "Promoted card status updated to verified"
    Assert-Test ($formalText -match "evidence_level:\s*verified-single-project") "Promoted card evidence level upgraded"

    $postLintRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Join-Path $vault1 "05_代码与配置") "知识库lint检查器.ps1") -VaultPath $vault1
    $postLint = $postLintRaw | ConvertFrom-Json
    Assert-Test ($postLint.ok -eq $true -and $postLint.summary.issues -eq 0) "Vault remains 100% lint-clean after successful promotion"

    # Release lease
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") release codex | Out-Null

    # ----------------------------------------------------
    Write-Host "`n--- STEP 6: Backup Snapshot Creation & SHA256 Verification ---"
    # ----------------------------------------------------
    $backupRaw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "backup-obsidian-vault.ps1")
    $backup = $backupRaw | ConvertFrom-Json
    Assert-Test ($backup.ok -eq $true) "Snapshot backup succeeded"
    Assert-Test (Test-Path -LiteralPath $backup.zipPath -PathType Leaf) "Snapshot ZIP exists at $($backup.zipPath)"
    Assert-Test (-not [string]::IsNullOrWhiteSpace($backup.zipSha256)) "Calculated SHA256: $($backup.zipSha256)"
    Assert-Test ($backup.verifiedArchiveEntries -gt 0) "Verified archive contains $($backup.verifiedArchiveEntries) entries"

    # ----------------------------------------------------
    Write-Host "`n--- STEP 7: Multi-Vault Concurrency & Isolation (Vault 1 vs Vault 2) ---"
    # ----------------------------------------------------
    $setup2Raw = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault2 "setup.ps1")
    $setup2 = $setup2Raw | ConvertFrom-Json
    Assert-Test ($setup2.ok -eq $true) "Vault 2 setup succeeded"
    Assert-Test ($setup2.vaultId -ne $setupOut.vaultId) "Vault 1 ID ($($setupOut.vaultId)) differs from Vault 2 ID ($($setup2.vaultId))"

    # Acquire in Vault 1 (codex)
    $v1Acq = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") acquire codex | ConvertFrom-Json
    Assert-Test ($v1Acq.ok -eq $true -and $v1Acq.holderAgent -eq "codex") "Vault 1 locked by codex"

    # Vault 2 status must still be idle
    $v2St = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault2 "lease.ps1") status | ConvertFrom-Json
    Assert-Test ($v2St.leaseStatus -eq "idle") "Vault 2 remains idle while Vault 1 is locked"

    # Vault 2 acquire concurrently (MUST SUCCEED)
    $v2Acq = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault2 "lease.ps1") acquire claude | ConvertFrom-Json
    Assert-Test ($v2Acq.ok -eq $true -and $v2Acq.holderAgent -eq "claude") "Vault 2 acquired concurrently by claude without collision!"

    # Release both
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault1 "lease.ps1") release codex | Out-Null
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vault2 "lease.ps1") release claude | Out-Null

    Write-Host "`n=========================================================="
    Write-Host "ALL $script:PassedTests FRESH-CLONE E2E TESTS PASSED SUCCESSFULLY!"
    Write-Host "=========================================================="

    return [ordered]@{
        ok = $true
        passedTests = $script:PassedTests
        failedTests = $script:FailedTests
    }
} finally {
    Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue
}