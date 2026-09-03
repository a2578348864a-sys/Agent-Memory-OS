Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:LeaseAssertionCount = 0

function Assert-LeaseTrue {
    param([bool]$Condition, [string]$Message)
    $script:LeaseAssertionCount++
    if (-not $Condition) { throw $Message }
}

function Get-LeaseProtectedManifestHash {
    param([string[]]$Roots)
    $rows = New-Object System.Collections.ArrayList
    foreach ($root in @($Roots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)) {
            [void]$rows.Add(([IO.Path]::GetFullPath($file.FullName) + "|" + $file.Length + "|" + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash))
        }
    }
    $payload = [string]::Join("`n", @($rows))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($payload))).Replace("-", "")) }
    finally { $sha.Dispose() }
}

$projectRoot = Split-Path $PSScriptRoot -Parent
$codeRoots = @(Get-ChildItem -LiteralPath $projectRoot -Directory | Where-Object Name -Like "05_*")
if ($codeRoots.Count -ne 1) { throw "The project code directory was not found uniquely." }
$corePath = Join-Path $codeRoots[0].FullName "DualAgentWriteLeaseCore.ps1"
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "The deterministic Dual-Agent Write Lease core is missing."
}
. $corePath

$contractRoots = @(Get-ChildItem -LiteralPath $PSScriptRoot -Directory | Where-Object Name -Like "*" | ForEach-Object {
    Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Where-Object Name -CEQ "DualAgentWriteLease"
})
if ($contractRoots.Count -ne 1) { throw "The write lease contract directory was not found uniquely." }
$stateSchema = Get-Content -LiteralPath (Join-Path $contractRoots[0].FullName "lease-state.schema.json") -Raw | ConvertFrom-Json
$eventSchema = Get-Content -LiteralPath (Join-Path $contractRoots[0].FullName "lease-event.schema.json") -Raw | ConvertFrom-Json
Assert-LeaseTrue ($stateSchema.title -ceq "Dual Agent Write Lease State v1" -and $eventSchema.title -ceq "Dual Agent Write Lease Event v1" -and
    @($stateSchema.required).Count -eq 11 -and @($eventSchema.required).Count -eq 14) "The machine-readable write lease schemas are missing or malformed."

$protectedRoots = @(Get-ChildItem -LiteralPath $projectRoot -Directory | Where-Object { $_.Name -like "02_*" -or $_.Name -like "03_*" -or $_.Name -like "04_*" -or $_.Name -like "08_*" } | ForEach-Object FullName)
$legacyHandoffRoot = Join-Path $env:LOCALAPPDATA "AgentMemoryOS\agent-memory-os"
if (Test-Path -LiteralPath $legacyHandoffRoot -PathType Container) { $protectedRoots += $legacyHandoffRoot }
$formalHashBefore = Get-LeaseProtectedManifestHash -Roots $protectedRoots

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("DualAgentWriteLease-Test-" + [guid]::NewGuid().ToString("N"))
[void][IO.Directory]::CreateDirectory($testRoot)

$systemTempNormalized = Get-DualAgentWriteLeaseFullPath -Path ([IO.Path]::GetTempPath())
$nonTempBase = [IO.Path]::GetPathRoot($systemTempNormalized)
$syntheticNonTempRoot = Join-Path $nonTempBase ("AgentMemoryOS-NonTemp-Probe-" + [guid]::NewGuid().ToString("N"))
if (Test-DualAgentWriteLeasePathInside -ChildPath $syntheticNonTempRoot -RootPath $systemTempNormalized) {
    throw "Synthetic probe was unexpectedly inside system TEMP: $syntheticNonTempRoot"
}
$syntheticNonTempFormalTarget = Join-Path $syntheticNonTempRoot "formal-target.json"

try {
    $empty = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T00:00:00.0000000Z"
    Assert-LeaseTrue ($empty.status -ceq "ok" -and $empty.leaseStatus -ceq "idle" -and $empty.revision -eq 0 -and
        $null -eq $empty.holderAgent -and $null -eq $empty.PSObject.Properties["leaseId"]) "Status leaked leaseId or was not an idle revision-zero snapshot."

    $initialized = Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -ReasonCode phase3_initial_idle -TestOnlyNowUtc "2026-08-11T00:00:00.0000000Z"
    Assert-LeaseTrue ($initialized.status -ceq "ok" -and $initialized.transactionComplete -and
        $initialized.leaseStatus -ceq "idle" -and $initialized.revision -eq 1) ("The lease root did not initialize to an idle baseline: " + ($initialized | ConvertTo-Json -Compress))

    $acquired = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -Scope automation_full_run -TtlSeconds 1800 -ReasonCode automation_start `
        -TestOnlyNowUtc "2026-08-11T00:01:00.0000000Z"
    Assert-LeaseTrue ($acquired.status -ceq "ok" -and $acquired.transactionComplete -and -not $acquired.replayed -and
        $acquired.leaseStatus -ceq "active" -and $acquired.holderAgent -ceq "codex" -and
        [string]$acquired.leaseId -cmatch "^[0-9a-f]{32}$" -and $acquired.scope -ceq "automation_full_run" -and
        $acquired.revision -eq 2) ("Codex could not acquire an idle automatic write lease: " + ($acquired | ConvertTo-Json -Compress))

    $leaseContext = New-DualAgentWriteLeaseContext -ExecutingAgent codex -LeaseId ([string]$acquired.leaseId) `
        -LeaseScope automation_full_run -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -TargetDomain fixture -FixtureRoot $testRoot `
        -TestOnlyNowUtc "2026-08-11T00:02:00.0000000Z"
    Assert-LeaseTrue ($leaseContext -is [System.Collections.ObjectModel.ReadOnlyDictionary[string,string]] -and
        [string]$leaseContext["leaseId"] -ceq [string]$acquired.leaseId -and
        [string]$leaseContext["targetDomain"] -ceq "fixture" -and
        [string]$leaseContext["fixtureRoot"] -ceq [IO.Path]::GetFullPath($testRoot).TrimEnd("\")) `
        "LeaseContext is not the immutable shared target-domain contract."
    $contextMutationRejected = $false
    try { $leaseContext["scope"] = "interactive_write" }
    catch { $contextMutationRejected = $true }
    Assert-LeaseTrue $contextMutationRejected "LeaseContext allowed mutation after creation."
    [void](Assert-DualAgentWriteLeaseContext -LeaseContext $leaseContext -AllowedScopes @("automation_full_run"))
    $fixtureTarget = Join-Path $testRoot "fixture-target.json"
    [void](Assert-DualAgentWriteLeaseTargetDomain -LeaseContext $leaseContext -TargetDomain fixture `
        -TargetPaths @($fixtureTarget) -AllowedScopes @("automation_full_run"))
    $fixtureToFormalRejected = $false
    try {
        [void](Assert-DualAgentWriteLeaseTargetDomain -LeaseContext $leaseContext -TargetDomain formal `
            -TargetPaths @($syntheticNonTempFormalTarget) -AllowedScopes @("automation_full_run"))
    }
    catch { $fixtureToFormalRejected = ([string]$_.Exception.Message -ceq "lease_target_domain_mismatch") }
    Assert-LeaseTrue $fixtureToFormalRejected "A fixture LeaseContext was accepted for a formal target."

    $outsideFixtureTarget = Join-Path ([IO.Path]::GetTempPath()) ("outside-fixture-" + [guid]::NewGuid().ToString("N") + ".json")
    $fixtureEscapeRejected = $false
    try {
        [void](Assert-DualAgentWriteLeaseTargetDomain -LeaseContext $leaseContext -TargetDomain fixture `
            -TargetPaths @($outsideFixtureTarget) -AllowedScopes @("automation_full_run"))
    }
    catch { $fixtureEscapeRejected = ([string]$_.Exception.Message -ceq "lease_fixture_target_outside_root") }
    Assert-LeaseTrue $fixtureEscapeRejected "A fixture LeaseContext escaped its bound fixture root."

    $formalWithFixtureParametersRejected = $false
    try {
        [void](New-DualAgentWriteLeaseContext -ExecutingAgent codex -LeaseId ([string]$acquired.leaseId) `
            -LeaseScope automation_full_run -TargetDomain formal -RuntimeRoot $testRoot `
            -AllowSystemTempFixture -FixtureRoot $testRoot)
    }
    catch { $formalWithFixtureParametersRejected = ([string]$_.Exception.Message -ceq "formal_lease_fixture_parameter_rejected") }
    Assert-LeaseTrue $formalWithFixtureParametersRejected "A formal LeaseContext accepted fixture-only parameters."

    $wrongContext = New-DualAgentWriteLeaseContext -ExecutingAgent codex -LeaseId ("f" * 32) `
        -LeaseScope automation_full_run -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -TargetDomain fixture -FixtureRoot $testRoot `
        -TestOnlyNowUtc "2026-08-11T00:02:00.0000000Z"
    $wrongContextRejected = $false
    try { [void](Assert-DualAgentWriteLeaseContext -LeaseContext $wrongContext) }
    catch { $wrongContextRejected = ([string]$_.Exception.Message -ceq "lease_id_mismatch") }
    Assert-LeaseTrue $wrongContextRejected "A mismatched immutable LeaseContext was accepted."
    $activeStatus = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T00:02:00.0000000Z"
    Assert-LeaseTrue ($null -eq $activeStatus.PSObject.Properties["leaseId"]) "Active Status leaked the current leaseId."

    $codexAllowed = Invoke-DualAgentWriteLease -Operation CanWrite -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$acquired.leaseId) -Scope automation_full_run `
        -TestOnlyNowUtc "2026-08-11T00:02:00.0000000Z"
    $claudeDenied = Invoke-DualAgentWriteLease -Operation CanWrite -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -LeaseId ([string]$acquired.leaseId) -Scope automation_full_run `
        -TestOnlyNowUtc "2026-08-11T00:02:00.0000000Z"
    Assert-LeaseTrue ($codexAllowed.status -ceq "ok" -and $codexAllowed.writeAllowed -and
        $claudeDenied.status -ceq "ok" -and -not $claudeDenied.writeAllowed -and
        $claudeDenied.reasonCode -ceq "lease_holder_mismatch") "The acquired lease did not enforce its Agent identity."

    $renewed = Invoke-DualAgentWriteLease -Operation Renew -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$acquired.leaseId) -Scope automation_full_run -TtlSeconds 1800 `
        -ReasonCode automation_renew -TestOnlyNowUtc "2026-08-11T00:10:00.0000000Z"
    Assert-LeaseTrue ($renewed.status -ceq "ok" -and $renewed.transactionComplete -and
        $renewed.leaseId -ceq $acquired.leaseId -and $renewed.revision -eq 3 -and
        $renewed.expiresAtUtc -ceq "2026-08-11T00:40:00.0000000Z") "The active holder could not renew its lease deterministically."
    $allowedAfterOriginalExpiry = Invoke-DualAgentWriteLease -Operation CanWrite -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$acquired.leaseId) -Scope automation_full_run `
        -TestOnlyNowUtc "2026-08-11T00:32:00.0000000Z"
    Assert-LeaseTrue $allowedAfterOriginalExpiry.writeAllowed "A renewed lease expired at its original deadline."

    $released = Invoke-DualAgentWriteLease -Operation Release -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$acquired.leaseId) -Scope automation_full_run -ReasonCode automation_complete `
        -TestOnlyNowUtc "2026-08-11T00:33:00.0000000Z"
    Assert-LeaseTrue ($released.status -ceq "ok" -and $released.transactionComplete -and -not $released.replayed -and
        $released.leaseStatus -ceq "idle" -and $released.revision -eq 4) "The holder could not release its lease."
    $statePath = Join-Path $testRoot "lease-state.json"
    $ledgerPath = Join-Path $testRoot "lease-events.jsonl"
    $stateHashBeforeReplay = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    $ledgerHashBeforeReplay = (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash
    $releaseReplay = Invoke-DualAgentWriteLease -Operation Release -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$acquired.leaseId) -Scope automation_full_run -ReasonCode automation_complete `
        -TestOnlyNowUtc "2026-08-11T00:34:00.0000000Z"
    Assert-LeaseTrue ($releaseReplay.status -ceq "ok" -and $releaseReplay.replayed -and $releaseReplay.revision -eq 4 -and
        (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash -ceq $stateHashBeforeReplay -and
        (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash -ceq $ledgerHashBeforeReplay) "Release replay was not a zero-write result."

    $claudeAcquired = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -Scope nightly_health -TtlSeconds 1800 -ReasonCode nightly_start `
        -TestOnlyNowUtc "2026-08-11T00:35:00.0000000Z"
    Assert-LeaseTrue ($claudeAcquired.status -ceq "ok" -and $claudeAcquired.holderAgent -ceq "claude" -and
        $claudeAcquired.scope -ceq "nightly_health" -and $claudeAcquired.revision -eq 5 -and
        $claudeAcquired.leaseId -cne $acquired.leaseId) "Claude could not acquire the lease after Codex released it."

    $activeStateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash
    $activeLedgerHash = (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash
    $codexBusy = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -Scope automation_full_run -TtlSeconds 1800 -ReasonCode competing_start `
        -TestOnlyNowUtc "2026-08-11T00:36:00.0000000Z"
    $claudeSecondTaskBusy = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -Scope nightly_health -TtlSeconds 1800 -ReasonCode competing_start `
        -TestOnlyNowUtc "2026-08-11T00:36:00.0000000Z"
    Assert-LeaseTrue ($codexBusy.status -ceq "blocked" -and $codexBusy.reasonCode -ceq "lease_busy" -and
        $claudeSecondTaskBusy.status -ceq "blocked" -and $claudeSecondTaskBusy.reasonCode -ceq "lease_busy" -and
        (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash -ceq $activeStateHash -and
        (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash -ceq $activeLedgerHash) "An active lease was shared, replaced, or changed by a competing task."

    $wrongId = Invoke-DualAgentWriteLease -Operation CanWrite -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -LeaseId ("f" * 32) -Scope nightly_health -TestOnlyNowUtc "2026-08-11T00:37:00.0000000Z"
    $wrongScope = Invoke-DualAgentWriteLease -Operation CanWrite -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -LeaseId ([string]$claudeAcquired.leaseId) -Scope interactive_write -TestOnlyNowUtc "2026-08-11T00:37:00.0000000Z"
    Assert-LeaseTrue (-not $wrongId.writeAllowed -and $wrongId.reasonCode -ceq "lease_id_mismatch" -and
        -not $wrongScope.writeAllowed -and $wrongScope.reasonCode -ceq "lease_scope_mismatch") "A wrong lease ID or scope obtained write authority."

    $expiredStatus = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T01:06:00.0000000Z"
    $expiredCanWrite = Invoke-DualAgentWriteLease -Operation CanWrite -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -LeaseId ([string]$claudeAcquired.leaseId) -Scope nightly_health `
        -TestOnlyNowUtc "2026-08-11T01:06:00.0000000Z"
    $expiredTakeover = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -Scope automation_full_run -TtlSeconds 1800 -ReasonCode post_expiry_start `
        -TestOnlyNowUtc "2026-08-11T01:06:00.0000000Z"
    $expiredRelease = Invoke-DualAgentWriteLease -Operation Release -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent claude -LeaseId ([string]$claudeAcquired.leaseId) -Scope nightly_health -ReasonCode late_release `
        -TestOnlyNowUtc "2026-08-11T01:06:00.0000000Z"
    Assert-LeaseTrue ($expiredStatus.leaseStatus -ceq "expired" -and -not $expiredCanWrite.writeAllowed -and
        $expiredCanWrite.reasonCode -ceq "lease_expired" -and $expiredTakeover.reasonCode -ceq "lease_expired_recovery_required" -and
        $expiredRelease.reasonCode -ceq "lease_expired_recovery_required") "An expired lease remained writable or was silently replaced/released."

    $recoveryWithoutApproval = Invoke-DualAgentWriteLease -Operation RecoverExpired -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$claudeAcquired.leaseId) -Scope nightly_health -ReasonCode approved_expired_recovery `
        -TestOnlyNowUtc "2026-08-11T01:07:00.0000000Z"
    Assert-LeaseTrue ($recoveryWithoutApproval.status -ceq "blocked" -and
        $recoveryWithoutApproval.reasonCode -ceq "lease_recovery_authorization_required") "Expired recovery did not require an explicit authorization switch."
    $recovered = Invoke-DualAgentWriteLease -Operation RecoverExpired -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -LeaseId ([string]$claudeAcquired.leaseId) -Scope nightly_health -ReasonCode approved_expired_recovery `
        -UserConfirmedRecovery -TestOnlyNowUtc "2026-08-11T01:07:00.0000000Z"
    Assert-LeaseTrue ($recovered.status -ceq "ok" -and $recovered.transactionComplete -and
        $recovered.leaseStatus -ceq "idle" -and $recovered.revision -eq 6) "An explicitly authorized expired lease did not recover to idle."

    $codexAfterRecovery = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $testRoot -AllowSystemTempFixture `
        -Agent codex -Scope interactive_write -TtlSeconds 600 -ReasonCode interactive_start `
        -TestOnlyNowUtc "2026-08-11T01:08:00.0000000Z"
    Assert-LeaseTrue ($codexAfterRecovery.status -ceq "ok" -and $codexAfterRecovery.holderAgent -ceq "codex" -and
        $codexAfterRecovery.scope -ceq "interactive_write" -and $codexAfterRecovery.revision -eq 7) "The lease was not reusable after controlled expired recovery."

    foreach ($failurePoint in @(1, 2)) {
        $initialFailureRoot = Join-Path $testRoot ("initial-failure-" + $failurePoint)
        [void][IO.Directory]::CreateDirectory($initialFailureRoot)
        $failedInitialization = Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $initialFailureRoot -AllowSystemTempFixture `
            -ReasonCode phase3_initial_idle -TestOnlyNowUtc "2026-08-11T02:00:00.0000000Z" `
            -TestOnlyFailureAfterPublish $failurePoint
        $afterInitialFailure = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $initialFailureRoot -AllowSystemTempFixture `
            -TestOnlyNowUtc "2026-08-11T02:00:01.0000000Z"
        Assert-LeaseTrue ($failedInitialization.status -ceq "blocked" -and
            $failedInitialization.reasonCode -ceq "lease_transaction_injected_failure" -and
            $afterInitialFailure.status -ceq "ok" -and $afterInitialFailure.leaseStatus -ceq "idle" -and
            $afterInitialFailure.revision -eq 0 -and @(Get-ChildItem -LiteralPath $initialFailureRoot -Force).Count -eq 0) `
            ("Initial lease failure point " + $failurePoint + " did not roll back completely.")
    }

    $existingFailureRoot = Join-Path $testRoot "existing-failure"
    [void][IO.Directory]::CreateDirectory($existingFailureRoot)
    [void](Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $existingFailureRoot -AllowSystemTempFixture `
        -ReasonCode phase3_initial_idle -TestOnlyNowUtc "2026-08-11T02:10:00.0000000Z")
    $existingStatePath = Join-Path $existingFailureRoot "lease-state.json"
    $existingLedgerPath = Join-Path $existingFailureRoot "lease-events.jsonl"
    $idleStateHash = (Get-FileHash -LiteralPath $existingStatePath -Algorithm SHA256).Hash
    $idleLedgerHash = (Get-FileHash -LiteralPath $existingLedgerPath -Algorithm SHA256).Hash
    foreach ($failurePoint in @(1, 2)) {
        $failedAcquire = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $existingFailureRoot -AllowSystemTempFixture `
            -Agent codex -Scope automation_full_run -TtlSeconds 600 -ReasonCode failure_probe `
            -TestOnlyNowUtc "2026-08-11T02:11:00.0000000Z" -TestOnlyFailureAfterPublish $failurePoint
        $afterAcquireFailure = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $existingFailureRoot -AllowSystemTempFixture `
            -TestOnlyNowUtc "2026-08-11T02:11:01.0000000Z"
        Assert-LeaseTrue ($failedAcquire.status -ceq "blocked" -and
            $failedAcquire.reasonCode -ceq "lease_transaction_injected_failure" -and
            $afterAcquireFailure.leaseStatus -ceq "idle" -and $afterAcquireFailure.revision -eq 1 -and
            (Get-FileHash -LiteralPath $existingStatePath -Algorithm SHA256).Hash -ceq $idleStateHash -and
            (Get-FileHash -LiteralPath $existingLedgerPath -Algorithm SHA256).Hash -ceq $idleLedgerHash -and
            @(Get-ChildItem -LiteralPath $existingFailureRoot -Force | Where-Object { $_.Name -like ".lease-*" -or $_.Name -ceq "lease.lock" }).Count -eq 0) `
            ("Existing lease failure point " + $failurePoint + " did not restore the exact idle state.")
    }

    $concurrentRoot = Join-Path $testRoot "concurrent-acquire"
    [void][IO.Directory]::CreateDirectory($concurrentRoot)
    [void](Invoke-DualAgentWriteLease -Operation InitializeIdle -RuntimeRoot $concurrentRoot -AllowSystemTempFixture `
        -ReasonCode phase3_initial_idle -TestOnlyNowUtc "2026-08-11T02:20:00.0000000Z")
    $jobScript = {
        param($CorePath, $Root, $Agent, $Scope)
        . $CorePath
        Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $Root -AllowSystemTempFixture -Agent $Agent `
            -Scope $Scope -TtlSeconds 600 -ReasonCode concurrent_start -TestOnlyNowUtc "2026-08-11T02:21:00.0000000Z"
    }
    $jobs = @(
        Start-Job -ScriptBlock $jobScript -ArgumentList $corePath, $concurrentRoot, "codex", "automation_full_run"
        Start-Job -ScriptBlock $jobScript -ArgumentList $corePath, $concurrentRoot, "claude", "nightly_health"
    )
    try {
        $completedJobs = @($jobs | Wait-Job -Timeout 60)
        Assert-LeaseTrue ($completedJobs.Count -eq 2 -and @($jobs | Where-Object State -cne "Completed").Count -eq 0) "Concurrent lease workers did not finish."
        $jobResults = @($jobs | Receive-Job)
        $committed = @($jobResults | Where-Object { $_.status -ceq "ok" -and $_.transactionComplete })
        $blocked = @($jobResults | Where-Object { $_.status -ceq "blocked" -and $_.reasonCode -ceq "lease_busy" })
        $concurrentStatus = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $concurrentRoot -AllowSystemTempFixture `
            -TestOnlyNowUtc "2026-08-11T02:21:01.0000000Z"
        Assert-LeaseTrue ($jobResults.Count -eq 2 -and $committed.Count -eq 1 -and $blocked.Count -eq 1 -and
            $concurrentStatus.leaseStatus -ceq "active" -and $concurrentStatus.revision -eq 2 -and
            $concurrentStatus.holderAgent -cin @("codex", "claude")) "Concurrent Acquire did not produce exactly one lease holder."
    }
    finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }

    $concurrentStatePath = Join-Path $concurrentRoot "lease-state.json"
    $concurrentLedgerPath = Join-Path $concurrentRoot "lease-events.jsonl"
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $savedStateText = [IO.File]::ReadAllText($concurrentStatePath, $utf8)
    $savedLedgerText = [IO.File]::ReadAllText($concurrentLedgerPath, $utf8)
    $tamperedState = $savedStateText | ConvertFrom-Json
    $tamperedState.holderAgent = if ([string]$tamperedState.holderAgent -ceq "codex") { "claude" } else { "codex" }
    [IO.File]::WriteAllText($concurrentStatePath, ($tamperedState | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $stateTamper = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $concurrentRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T02:21:02.0000000Z"
    Assert-LeaseTrue ($stateTamper.status -ceq "blocked" -and
        $stateTamper.reasonCode -ceq "lease_state_ledger_mismatch") "A valid-looking state with a forged holder was not rejected against the event ledger."
    [IO.File]::WriteAllText($concurrentStatePath, $savedStateText, [Text.UTF8Encoding]::new($false))

    $ledgerLines = @($savedLedgerText -split "\r?\n" | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $tamperedEvent = $ledgerLines[-1] | ConvertFrom-Json
    $tamperedEvent.agent = if ([string]$tamperedEvent.agent -ceq "codex") { "claude" } else { "codex" }
    $ledgerLines[-1] = $tamperedEvent | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($concurrentLedgerPath, (($ledgerLines -join "`r`n") + "`r`n"), [Text.UTF8Encoding]::new($false))
    $ledgerTamper = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $concurrentRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T02:21:02.0000000Z"
    Assert-LeaseTrue ($ledgerTamper.status -ceq "blocked" -and $ledgerTamper.reasonCode -ceq "lease_ledger_invalid") "A tampered lease event was not rejected."
    [IO.File]::WriteAllText($concurrentLedgerPath, $savedLedgerText, [Text.UTF8Encoding]::new($false))

    $roguePath = Join-Path $concurrentRoot "lease-copy.json"
    [IO.File]::WriteAllText($roguePath, "{}", [Text.UTF8Encoding]::new($false))
    $rogueResult = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $concurrentRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T02:21:02.0000000Z"
    Assert-LeaseTrue ($rogueResult.status -ceq "blocked" -and
        $rogueResult.reasonCode -ceq "lease_runtime_unregistered_file") "An unregistered lease runtime file was accepted."
    [IO.File]::Delete($roguePath)

    $outsideResult = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $syntheticNonTempRoot -AllowSystemTempFixture `
        -TestOnlyNowUtc "2026-08-11T02:21:02.0000000Z"
    $unapprovedResult = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $concurrentRoot `
        -TestOnlyNowUtc "2026-08-11T02:21:02.0000000Z"
    Assert-LeaseTrue ($outsideResult.reasonCode -ceq "lease_test_root_not_system_temp" -and
        $unapprovedResult.reasonCode -ceq "lease_runtime_root_not_approved" -and
        -not (Test-Path -LiteralPath $syntheticNonTempRoot)) "A lease runtime crossed its approved path boundary."

    $junctionTarget = Join-Path $testRoot "junction-target"
    $junctionRoot = Join-Path $testRoot "junction-runtime"
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    [void](New-Item -ItemType Junction -Path $junctionRoot -Target $junctionTarget -ErrorAction Stop)
    try {
        $junctionResult = Invoke-DualAgentWriteLease -Operation Status -RuntimeRoot $junctionRoot -AllowSystemTempFixture `
            -TestOnlyNowUtc "2026-08-11T02:21:02.0000000Z"
        Assert-LeaseTrue ($junctionResult.reasonCode -ceq "lease_reparse_point_blocked") "A lease Junction root was accepted."
    }
    finally {
        if (Test-Path -LiteralPath $junctionRoot) { [IO.Directory]::Delete($junctionRoot, $false) }
    }

    $invalidReason = Invoke-DualAgentWriteLease -Operation Acquire -RuntimeRoot $existingFailureRoot -AllowSystemTempFixture `
        -Agent codex -Scope automation_full_run -TtlSeconds 600 -ReasonCode "synthetic-secret=C:\private\value" `
        -TestOnlyNowUtc "2026-08-11T02:30:00.0000000Z"
    $invalidJson = $invalidReason | ConvertTo-Json -Compress
    Assert-LeaseTrue ($invalidReason.reasonCode -ceq "lease_reason_code_invalid" -and
        -not $invalidJson.Contains("synthetic-secret") -and -not $invalidJson.Contains($existingFailureRoot)) "A rejected lease input leaked its value or runtime path."
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\") + "\"
        if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not [IO.Path]::GetFileName($resolved).StartsWith("DualAgentWriteLease-Test-", [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a write-lease test root outside controlled system TEMP."
        }
        [IO.Directory]::Delete($resolved, $true)
    }
}

$formalHashAfter = Get-LeaseProtectedManifestHash -Roots $protectedRoots
Assert-LeaseTrue ($formalHashAfter -ceq $formalHashBefore) "Write lease isolation tests changed a protected formal file."

[pscustomobject][ordered]@{
    status = "ok"
    assertions = $script:LeaseAssertionCount
    formalWrites = 0
    productionIntegration = $false
} | ConvertTo-Json -Depth 5
