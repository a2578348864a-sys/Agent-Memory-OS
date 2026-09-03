Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:WriteLeaseSchemaVersion = 1
$script:WriteLeaseProjectId = "agent-memory-os"
$script:WriteLeaseOperations = @("Status", "InitializeIdle", "Acquire", "Renew", "Release", "CanWrite", "RecoverExpired")
$script:WriteLeaseAgents = @("codex", "claude", "gemini", "cursor", "windsurf")
$script:WriteLeaseScopes = @("automation_full_run", "nightly_health", "interactive_write")
$script:WriteLeaseTargetDomains = @("formal", "fixture")
$script:WriteLeaseEventTypes = @("initialized_idle", "acquired", "renewed", "released", "expired_recovered")
$script:WriteLeaseStateName = "lease-state.json"
$script:WriteLeaseLedgerName = "lease-events.jsonl"
$script:WriteLeaseLockName = "lease.lock"
$script:WriteLeaseUtf8 = [Text.UTF8Encoding]::new($false, $true)
if ($null -eq (Get-Variable -Name DualAgentWriteLeaseContext -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DualAgentWriteLeaseContext = $null
}

function New-DualAgentWriteLeaseContext {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$ExecutingAgent,
        [AllowNull()][string]$LeaseId,
        [AllowNull()][string]$LeaseScope,
        [AllowNull()][string]$RuntimeRoot,
        [switch]$AllowSystemTempFixture,
        [AllowNull()][string]$TestOnlyNowUtc,
        [AllowNull()][ValidateSet("formal", "fixture")][string]$TargetDomain,
        [AllowNull()][string]$FixtureRoot
    )

    if ([string]::IsNullOrWhiteSpace($ExecutingAgent)) { throw "lease_agent_required" }
    if ($script:WriteLeaseAgents -cnotcontains $ExecutingAgent) { throw "lease_agent_invalid" }
    if ([string]::IsNullOrWhiteSpace($LeaseId)) { throw "lease_id_required" }
    if ([string]$LeaseId -cnotmatch "^[0-9a-f]{32}$") { throw "lease_id_invalid" }
    if ([string]::IsNullOrWhiteSpace($LeaseScope)) { throw "lease_scope_required" }
    if ($script:WriteLeaseScopes -cnotcontains $LeaseScope) { throw "lease_scope_invalid" }
    $fixtureParametersPresent = $PSBoundParameters.ContainsKey("RuntimeRoot") -or [bool]$AllowSystemTempFixture -or
        -not [string]::IsNullOrWhiteSpace($TestOnlyNowUtc) -or -not [string]::IsNullOrWhiteSpace($FixtureRoot)
    $effectiveDomain = if ([string]::IsNullOrWhiteSpace($TargetDomain)) {
        if ($fixtureParametersPresent) { "fixture" } else { "formal" }
    }
    else { $TargetDomain }
    if ($effectiveDomain -ceq "formal" -and $fixtureParametersPresent) { throw "formal_lease_fixture_parameter_rejected" }
    if ($effectiveDomain -ceq "fixture" -and
        (-not $AllowSystemTempFixture -or [string]::IsNullOrWhiteSpace($RuntimeRoot) -or [string]::IsNullOrWhiteSpace($FixtureRoot))) {
        throw "fixture_lease_contract_invalid"
    }
    if (-not [string]::IsNullOrWhiteSpace($TestOnlyNowUtc) -and -not $AllowSystemTempFixture) { throw "lease_test_clock_rejected" }

    $resolvedRoot = Assert-DualAgentWriteLeaseRuntimeRoot -RuntimeRoot $RuntimeRoot -AllowSystemTempFixture:$AllowSystemTempFixture
    $resolvedFixtureRoot = ""
    if ($effectiveDomain -ceq "fixture") {
        $resolvedFixtureRoot = Get-DualAgentWriteLeaseFullPath -Path $FixtureRoot
        $systemTempRoot = Get-DualAgentWriteLeaseFullPath -Path ([IO.Path]::GetTempPath())
        if (-not (Test-DualAgentWriteLeasePathInside -ChildPath $resolvedFixtureRoot -RootPath $systemTempRoot)) {
            throw "lease_fixture_root_not_system_temp"
        }
        if (-not ([string]::Equals($resolvedRoot, $resolvedFixtureRoot, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-DualAgentWriteLeasePathInside -ChildPath $resolvedRoot -RootPath $resolvedFixtureRoot))) {
            throw "lease_runtime_fixture_root_mismatch"
        }
        Assert-DualAgentWriteLeaseNoReparsePath -Path $resolvedRoot -Boundary $systemTempRoot
        Assert-DualAgentWriteLeaseNoReparsePath -Path $resolvedFixtureRoot -Boundary $systemTempRoot
    }
    $values = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $values.Add("agent", $ExecutingAgent)
    $values.Add("leaseId", $LeaseId)
    $values.Add("scope", $LeaseScope)
    $values.Add("runtimeRoot", $resolvedRoot)
    $values.Add("allowSystemTempFixture", ([bool]$AllowSystemTempFixture).ToString([cultureinfo]::InvariantCulture))
    $values.Add("testOnlyNowUtc", $(if ([string]::IsNullOrWhiteSpace($TestOnlyNowUtc)) { "" } else { $TestOnlyNowUtc }))
    $values.Add("targetDomain", $effectiveDomain)
    $values.Add("fixtureRoot", $resolvedFixtureRoot)
    return New-Object 'System.Collections.ObjectModel.ReadOnlyDictionary[string,string]' (,$values)
}

function Assert-DualAgentWriteLeaseContext {
    [CmdletBinding()]
    param(
        [AllowNull()]$LeaseContext,
        [string[]]$AllowedScopes = $script:WriteLeaseScopes
    )

    if ($null -eq $LeaseContext) { throw "lease_context_required" }
    if ($LeaseContext -isnot [System.Collections.ObjectModel.ReadOnlyDictionary[string,string]]) {
        throw "lease_context_invalid"
    }
    $requiredKeys = @("agent", "leaseId", "scope", "runtimeRoot", "allowSystemTempFixture", "testOnlyNowUtc", "targetDomain", "fixtureRoot")
    if ($LeaseContext.Count -ne $requiredKeys.Count -or @($requiredKeys | Where-Object { -not $LeaseContext.ContainsKey($_) }).Count -gt 0) {
        throw "lease_context_invalid"
    }
    if ($AllowedScopes -cnotcontains [string]$LeaseContext["scope"]) { throw "lease_scope_mode_denied" }
    $contextDomain = [string]$LeaseContext["targetDomain"]
    if ($script:WriteLeaseTargetDomains -cnotcontains $contextDomain) { throw "lease_context_invalid" }
    $contextAllowsFixture = [string]::Equals([string]$LeaseContext["allowSystemTempFixture"], "True", [StringComparison]::Ordinal)
    if ($contextDomain -ceq "formal") {
        if ($contextAllowsFixture -or -not [string]::IsNullOrWhiteSpace([string]$LeaseContext["testOnlyNowUtc"]) -or
            -not [string]::IsNullOrWhiteSpace([string]$LeaseContext["fixtureRoot"]) -or
            -not [string]::Equals([string]$LeaseContext["runtimeRoot"], (Get-DualAgentWriteLeaseDefaultRuntimeRoot), [StringComparison]::OrdinalIgnoreCase)) {
            throw "lease_context_invalid"
        }
    }
    else {
        if (-not $contextAllowsFixture -or [string]::IsNullOrWhiteSpace([string]$LeaseContext["fixtureRoot"])) { throw "lease_context_invalid" }
        $fixtureRoot = Get-DualAgentWriteLeaseFullPath -Path ([string]$LeaseContext["fixtureRoot"])
        $runtimeRoot = Get-DualAgentWriteLeaseFullPath -Path ([string]$LeaseContext["runtimeRoot"])
        $systemTempRoot = Get-DualAgentWriteLeaseFullPath -Path ([IO.Path]::GetTempPath())
        if (-not (Test-DualAgentWriteLeasePathInside -ChildPath $fixtureRoot -RootPath $systemTempRoot) -or
            -not ([string]::Equals($runtimeRoot, $fixtureRoot, [StringComparison]::OrdinalIgnoreCase) -or
            (Test-DualAgentWriteLeasePathInside -ChildPath $runtimeRoot -RootPath $fixtureRoot))) {
            throw "lease_context_invalid"
        }
    }

    $arguments = @{
        Operation = "CanWrite"
        Agent = [string]$LeaseContext["agent"]
        LeaseId = [string]$LeaseContext["leaseId"]
        Scope = [string]$LeaseContext["scope"]
        RuntimeRoot = [string]$LeaseContext["runtimeRoot"]
    }
    if ([string]::Equals([string]$LeaseContext["allowSystemTempFixture"], "True", [StringComparison]::Ordinal)) {
        $arguments.AllowSystemTempFixture = $true
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$LeaseContext["testOnlyNowUtc"])) {
        $arguments.TestOnlyNowUtc = [string]$LeaseContext["testOnlyNowUtc"]
    }
    $ownership = Invoke-DualAgentWriteLease @arguments
    if ([string]$ownership.status -cne "ok" -or -not [bool]$ownership.writeAllowed) {
        $reason = if ([string]::IsNullOrWhiteSpace([string]$ownership.reasonCode)) { "lease_context_invalid" } else { [string]$ownership.reasonCode }
        throw $reason
    }
    return $LeaseContext
}

function Get-DualAgentWriteTargetDomain {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$TargetPaths)

    if ($TargetPaths.Count -eq 0) { throw "lease_target_paths_required" }
    $systemTempRoot = Get-DualAgentWriteLeaseFullPath -Path ([IO.Path]::GetTempPath())
    $domains = @($TargetPaths | ForEach-Object {
        $target = Get-DualAgentWriteLeaseFullPath -Path $_
        if (Test-DualAgentWriteLeasePathInside -ChildPath $target -RootPath $systemTempRoot) { "fixture" } else { "formal" }
    } | Sort-Object -Unique)
    if ($domains.Count -ne 1) { throw "lease_target_domain_mixed" }
    return [string]$domains[0]
}

function Assert-DualAgentWriteLeaseTargetDomain {
    [CmdletBinding()]
    param(
        [AllowNull()]$LeaseContext,
        [Parameter(Mandatory = $true)][ValidateSet("formal", "fixture")][string]$TargetDomain,
        [Parameter(Mandatory = $true)][string[]]$TargetPaths,
        [string[]]$AllowedScopes = $script:WriteLeaseScopes
    )

    [void](Assert-DualAgentWriteLeaseContext -LeaseContext $LeaseContext -AllowedScopes $AllowedScopes)
    $derivedDomain = Get-DualAgentWriteTargetDomain -TargetPaths $TargetPaths
    if (-not [string]::Equals($derivedDomain, $TargetDomain, [StringComparison]::Ordinal)) { throw "lease_target_domain_invalid" }
    if (-not [string]::Equals([string]$LeaseContext["targetDomain"], $TargetDomain, [StringComparison]::Ordinal)) {
        throw "lease_target_domain_mismatch"
    }
    if ($TargetDomain -ceq "fixture") {
        $fixtureRoot = [string]$LeaseContext["fixtureRoot"]
        foreach ($path in $TargetPaths) {
            if (-not (Test-DualAgentWriteLeasePathInside -ChildPath $path -RootPath $fixtureRoot)) {
                throw "lease_fixture_target_outside_root"
            }
            Assert-DualAgentWriteLeaseNoReparsePath -Path $path -Boundary $fixtureRoot
        }
    }
    return $LeaseContext
}

function Set-DualAgentWriteLeaseContext {
    [CmdletBinding()]
    param([AllowNull()]$LeaseContext)
    if ($null -ne $LeaseContext) { [void](Assert-DualAgentWriteLeaseContext -LeaseContext $LeaseContext) }
    $script:DualAgentWriteLeaseContext = $LeaseContext
}

function New-DualAgentWriteLeaseResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$ReasonCode,
        [hashtable]$Fields = @{}
    )
    $result = [ordered]@{ schemaVersion = 1; status = $Status; reasonCode = $ReasonCode }
    foreach ($name in @($Fields.Keys | Sort-Object)) { $result[$name] = $Fields[$name] }
    return [pscustomobject]$result
}

function Get-DualAgentWriteLeaseVaultId {
    [CmdletBinding()]
    param([string]$VaultRoot)
    if ([string]::IsNullOrWhiteSpace($VaultRoot)) {
        $VaultRoot = Split-Path -Parent $PSScriptRoot
    }
    $normalized = [IO.Path]::GetFullPath($VaultRoot).TrimEnd("\/").ToLowerInvariant()
    $metaPath = Join-Path $VaultRoot ".agent-memory-os.json"
    if (Test-Path -LiteralPath $metaPath -PathType Leaf) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$meta.vaultId) -and
                (-not [string]::IsNullOrWhiteSpace([string]$meta.vaultRootPath)) -and
                ([string]::Equals([string]$meta.vaultRootPath.TrimEnd("\/").ToLowerInvariant(), $normalized, [StringComparison]::OrdinalIgnoreCase))) {
                return [string]$meta.vaultId
            }
        } catch {}
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalized))).Replace("-", "").Substring(0, 12).ToLowerInvariant()
        return "vault-$hash"
    } finally {
        $sha.Dispose()
    }
}

function Get-DualAgentWriteLeaseDefaultRuntimeRoot {
    [CmdletBinding()]
    param([string]$VaultRoot)
    if ([string]::IsNullOrWhiteSpace([string]$env:LOCALAPPDATA)) { throw "lease_local_app_data_missing" }
    $vaultId = Get-DualAgentWriteLeaseVaultId -VaultRoot $VaultRoot
    return [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AgentMemoryOS\$vaultId\write-lease")).TrimEnd("\")
}

function Get-DualAgentWriteLeaseFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "lease_runtime_root_invalid" }
    try { return [IO.Path]::GetFullPath($Path).TrimEnd("\") }
    catch { throw "lease_runtime_root_invalid" }
}

function Test-DualAgentWriteLeasePathInside {
    param([string]$ChildPath, [string]$RootPath)
    $child = Get-DualAgentWriteLeaseFullPath -Path $ChildPath
    $root = Get-DualAgentWriteLeaseFullPath -Path $RootPath
    return $child.StartsWith(($root + "\"), [StringComparison]::OrdinalIgnoreCase)
}

function Test-DualAgentWriteLeaseReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-DualAgentWriteLeaseNoReparsePath {
    param([string]$Path, [string]$Boundary)
    $cursor = Get-DualAgentWriteLeaseFullPath -Path $Path
    $boundaryPath = Get-DualAgentWriteLeaseFullPath -Path $Boundary
    while ($true) {
        if ((Test-Path -LiteralPath $cursor) -and (Test-DualAgentWriteLeaseReparsePoint -Path $cursor)) { throw "lease_reparse_point_blocked" }
        if ([string]::Equals($cursor, $boundaryPath, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path $cursor -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $cursor, [StringComparison]::OrdinalIgnoreCase)) {
            throw "lease_runtime_root_invalid"
        }
        $cursor = $parent
    }
}

function Assert-DualAgentWriteLeaseRuntimeRoot {
    param([AllowNull()][string]$RuntimeRoot, [switch]$AllowSystemTempFixture)
    $root = if ([string]::IsNullOrWhiteSpace($RuntimeRoot)) { Get-DualAgentWriteLeaseDefaultRuntimeRoot } else { Get-DualAgentWriteLeaseFullPath -Path $RuntimeRoot }
    if ($AllowSystemTempFixture) {
        $temp = Get-DualAgentWriteLeaseFullPath -Path ([IO.Path]::GetTempPath())
        if (-not (Test-DualAgentWriteLeasePathInside -ChildPath $root -RootPath $temp)) { throw "lease_test_root_not_system_temp" }
        Assert-DualAgentWriteLeaseNoReparsePath -Path $root -Boundary $temp
    }
    else {
        $fixed = Get-DualAgentWriteLeaseDefaultRuntimeRoot
        $appDataOS = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AgentMemoryOS")).TrimEnd("\")
        $isVault = (Test-DualAgentWriteLeasePathInside -ChildPath $root -RootPath $appDataOS)
        if (-not $isVault -and -not [string]::Equals($root, $fixed, [StringComparison]::OrdinalIgnoreCase)) { throw "lease_runtime_root_not_approved" }
        Assert-DualAgentWriteLeaseNoReparsePath -Path $root -Boundary (Get-DualAgentWriteLeaseFullPath -Path $env:LOCALAPPDATA)
    }
    if ((Test-Path -LiteralPath $root) -and -not (Test-Path -LiteralPath $root -PathType Container)) { throw "lease_runtime_root_invalid" }
    return $root
}

function Get-DualAgentWriteLeaseSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace("-", "").ToUpperInvariant() }
    finally { $algorithm.Dispose() }
}

function Get-DualAgentWriteLeaseCanonicalHash {
    param([Parameter(Mandatory = $true)]$Value)
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    return Get-DualAgentWriteLeaseSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($json))
}

function Assert-DualAgentWriteLeaseExactProperties {
    param($Value, [string[]]$Expected, [string]$ReasonCode)
    if ($null -eq $Value) { throw $ReasonCode }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if ($actual.Count -ne $wanted.Count -or $null -ne (Compare-Object $actual $wanted)) { throw $ReasonCode }
}

function ConvertTo-DualAgentWriteLeaseUtc {
    param([Parameter(Mandatory = $true)][string]$Value, [string]$ReasonCode = "lease_time_invalid")
    if ($Value -cnotmatch "Z$") { throw $ReasonCode }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($Value, "o", [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { throw $ReasonCode }
    return $parsed.ToUniversalTime()
}

function Get-DualAgentWriteLeaseNow {
    param([AllowNull()][string]$TestOnlyNowUtc, [switch]$AllowSystemTempFixture)
    if (-not [string]::IsNullOrWhiteSpace($TestOnlyNowUtc)) {
        if (-not $AllowSystemTempFixture) { throw "lease_test_time_rejected" }
        return ConvertTo-DualAgentWriteLeaseUtc -Value $TestOnlyNowUtc
    }
    return [DateTimeOffset]::UtcNow
}

function Format-DualAgentWriteLeaseUtc {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$Value)
    return $Value.UtcDateTime.ToString("o", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-DualAgentWriteLeaseEmptySnapshot {
    return [pscustomobject][ordered]@{
        schemaVersion = 1; projectId = $script:WriteLeaseProjectId; revision = [int64]0; leaseStatus = "idle"
        holderAgent = $null; leaseId = $null; scope = $null; acquiredAtUtc = $null; expiresAtUtc = $null
        updatedAtUtc = $null; lastEventSha256 = $null; events = @(); ledgerText = ""; stateSha256 = $null; ledgerSha256 = $null
    }
}

function Read-DualAgentWriteLeaseText {
    param([string]$Path, [long]$MaximumBytes, [string]$ReasonCode)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-DualAgentWriteLeaseReparsePoint -Path $Path)) { throw $ReasonCode }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 1 -or $bytes.Length -gt $MaximumBytes -or
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) { throw $ReasonCode }
    try { return $script:WriteLeaseUtf8.GetString($bytes) }
    catch { throw $ReasonCode }
}

function Read-DualAgentWriteLeaseState {
    param([string]$Path)
    try { $state = (Read-DualAgentWriteLeaseText -Path $Path -MaximumBytes 65536 -ReasonCode "lease_state_invalid") | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "lease_state_invalid" }
    Assert-DualAgentWriteLeaseExactProperties -Value $state -Expected @(
        "schemaVersion", "projectId", "revision", "leaseStatus", "holderAgent", "leaseId", "scope",
        "acquiredAtUtc", "expiresAtUtc", "updatedAtUtc", "lastEventSha256"
    ) -ReasonCode "lease_state_invalid"
    if (($state.schemaVersion -isnot [int] -and $state.schemaVersion -isnot [long]) -or
        ($state.revision -isnot [int] -and $state.revision -isnot [long])) { throw "lease_state_invalid" }
    if ([int64]$state.schemaVersion -ne 1 -or [string]$state.projectId -cne $script:WriteLeaseProjectId -or
        [int64]$state.revision -lt 1 -or [string]$state.leaseStatus -cnotin @("idle", "active") -or
        [string]$state.lastEventSha256 -cnotmatch "^[0-9A-F]{64}$") { throw "lease_state_invalid" }
    [void](ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$state.updatedAtUtc) -ReasonCode "lease_state_invalid")
    if ([string]$state.leaseStatus -ceq "idle") {
        if ($null -ne $state.holderAgent -or $null -ne $state.leaseId -or $null -ne $state.scope -or
            $null -ne $state.acquiredAtUtc -or $null -ne $state.expiresAtUtc) { throw "lease_state_invalid" }
    }
    else {
        if ($script:WriteLeaseAgents -cnotcontains [string]$state.holderAgent -or [string]$state.leaseId -cnotmatch "^[0-9a-f]{32}$" -or
            $script:WriteLeaseScopes -cnotcontains [string]$state.scope) { throw "lease_state_invalid" }
        $acquired = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$state.acquiredAtUtc) -ReasonCode "lease_state_invalid"
        $expires = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$state.expiresAtUtc) -ReasonCode "lease_state_invalid"
        if ($expires -le $acquired) { throw "lease_state_invalid" }
    }
    return $state
}

function New-DualAgentWriteLeaseEvent {
    param(
        [string]$EventType, [long]$Revision, [DateTimeOffset]$OccurredAt, [AllowNull()]$Agent,
        [AllowNull()]$LeaseId, [AllowNull()]$Scope, [AllowNull()]$AcquiredAtUtc,
        [AllowNull()]$ExpiresAtUtc, [AllowNull()]$PreviousEventSha256, [string]$ReasonCode
    )
    $contract = [ordered]@{
        schemaVersion = 1; eventType = $EventType; projectId = $script:WriteLeaseProjectId; revision = $Revision
        occurredAtUtc = Format-DualAgentWriteLeaseUtc -Value $OccurredAt; agent = $Agent; leaseId = $LeaseId; scope = $Scope
        acquiredAtUtc = $AcquiredAtUtc; expiresAtUtc = $ExpiresAtUtc; previousEventSha256 = $PreviousEventSha256; reasonCode = $ReasonCode
    }
    $eventSha = Get-DualAgentWriteLeaseCanonicalHash -Value $contract
    $eventId = Get-DualAgentWriteLeaseSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes("dual-agent-write-lease-event-v1|$($script:WriteLeaseProjectId)|$eventSha"))
    return [pscustomobject][ordered]@{
        schemaVersion = 1; eventType = $EventType; eventId = $eventId; projectId = $script:WriteLeaseProjectId; revision = $Revision
        occurredAtUtc = $contract.occurredAtUtc; agent = $Agent; leaseId = $LeaseId; scope = $Scope; acquiredAtUtc = $AcquiredAtUtc
        expiresAtUtc = $ExpiresAtUtc; previousEventSha256 = $PreviousEventSha256; eventSha256 = $eventSha; reasonCode = $ReasonCode
    }
}

function Read-DualAgentWriteLeaseLedger {
    param([string]$Path)
    $text = Read-DualAgentWriteLeaseText -Path $Path -MaximumBytes 4194304 -ReasonCode "lease_ledger_invalid"
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) { throw "lease_ledger_invalid" }
    $lines = @($text -split "\r?\n" | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($lines.Count -lt 1 -or $lines.Count -gt 10000) { throw "lease_ledger_invalid" }
    $events = New-Object System.Collections.ArrayList
    $previousHash = $null
    $previousAt = [DateTimeOffset]::MinValue
    $seen = @{}
    $derivedStatus = "idle"
    $derivedAgent = $null
    $derivedLeaseId = $null
    $derivedScope = $null
    $derivedAcquiredAtUtc = $null
    $derivedExpiresAtUtc = $null
    for ($index = 0; $index -lt $lines.Count; $index++) {
        try { $event = $lines[$index] | ConvertFrom-Json -ErrorAction Stop } catch { throw "lease_ledger_invalid" }
        Assert-DualAgentWriteLeaseExactProperties -Value $event -Expected @(
            "schemaVersion", "eventType", "eventId", "projectId", "revision", "occurredAtUtc", "agent", "leaseId", "scope",
            "acquiredAtUtc", "expiresAtUtc", "previousEventSha256", "eventSha256", "reasonCode"
        ) -ReasonCode "lease_ledger_invalid"
        if (($event.schemaVersion -isnot [int] -and $event.schemaVersion -isnot [long]) -or
            ($event.revision -isnot [int] -and $event.revision -isnot [long])) { throw "lease_ledger_invalid" }
        if ([int64]$event.schemaVersion -ne 1 -or [string]$event.projectId -cne $script:WriteLeaseProjectId -or
            [int64]$event.revision -ne ($index + 1) -or $script:WriteLeaseEventTypes -cnotcontains [string]$event.eventType -or
            [string]$event.reasonCode -cnotmatch "^[a-z][a-z0-9_]{0,63}$" -or
            [string]$event.eventId -cnotmatch "^[0-9A-F]{64}$" -or [string]$event.eventSha256 -cnotmatch "^[0-9A-F]{64}$" -or
            -not [string]::Equals([string]$event.previousEventSha256, [string]$previousHash, [StringComparison]::Ordinal)) { throw "lease_ledger_invalid" }
        $occurred = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$event.occurredAtUtc) -ReasonCode "lease_ledger_invalid"
        if ($occurred -lt $previousAt) { throw "lease_ledger_invalid" }
        $contract = [ordered]@{
            schemaVersion = 1; eventType = [string]$event.eventType; projectId = $script:WriteLeaseProjectId; revision = [int64]$event.revision
            occurredAtUtc = [string]$event.occurredAtUtc; agent = $event.agent; leaseId = $event.leaseId; scope = $event.scope
            acquiredAtUtc = $event.acquiredAtUtc; expiresAtUtc = $event.expiresAtUtc; previousEventSha256 = $event.previousEventSha256
            reasonCode = [string]$event.reasonCode
        }
        $expectedHash = Get-DualAgentWriteLeaseCanonicalHash -Value $contract
        $expectedId = Get-DualAgentWriteLeaseSha256 -Bytes ([Text.UTF8Encoding]::new($false).GetBytes("dual-agent-write-lease-event-v1|$($script:WriteLeaseProjectId)|$expectedHash"))
        if ([string]$event.eventSha256 -cne $expectedHash -or [string]$event.eventId -cne $expectedId -or $seen.ContainsKey($expectedId)) { throw "lease_ledger_invalid" }

        switch ([string]$event.eventType) {
            "initialized_idle" {
                if ($index -ne 0 -or $derivedStatus -cne "idle" -or $null -ne $event.agent -or
                    $null -ne $event.leaseId -or $null -ne $event.scope -or $null -ne $event.acquiredAtUtc -or
                    $null -ne $event.expiresAtUtc) { throw "lease_ledger_invalid" }
            }
            "acquired" {
                if ($derivedStatus -cne "idle" -or $script:WriteLeaseAgents -cnotcontains [string]$event.agent -or
                    [string]$event.leaseId -cnotmatch "^[0-9a-f]{32}$" -or $script:WriteLeaseScopes -cnotcontains [string]$event.scope) {
                    throw "lease_ledger_invalid"
                }
                $eventAcquired = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$event.acquiredAtUtc) -ReasonCode "lease_ledger_invalid"
                $eventExpires = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$event.expiresAtUtc) -ReasonCode "lease_ledger_invalid"
                if ($eventAcquired -ne $occurred -or $eventExpires -le $eventAcquired) { throw "lease_ledger_invalid" }
                $derivedStatus = "active"; $derivedAgent = [string]$event.agent; $derivedLeaseId = [string]$event.leaseId
                $derivedScope = [string]$event.scope; $derivedAcquiredAtUtc = [string]$event.acquiredAtUtc; $derivedExpiresAtUtc = [string]$event.expiresAtUtc
            }
            "renewed" {
                if ($derivedStatus -cne "active" -or [string]$event.agent -cne [string]$derivedAgent -or
                    [string]$event.leaseId -cne [string]$derivedLeaseId -or [string]$event.scope -cne [string]$derivedScope -or
                    [string]$event.acquiredAtUtc -cne [string]$derivedAcquiredAtUtc) { throw "lease_ledger_invalid" }
                $priorExpires = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$derivedExpiresAtUtc) -ReasonCode "lease_ledger_invalid"
                $eventExpires = ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$event.expiresAtUtc) -ReasonCode "lease_ledger_invalid"
                if ($occurred -ge $priorExpires -or $eventExpires -le $occurred) { throw "lease_ledger_invalid" }
                $derivedExpiresAtUtc = [string]$event.expiresAtUtc
            }
            "released" {
                if ($derivedStatus -cne "active" -or [string]$event.agent -cne [string]$derivedAgent -or
                    [string]$event.leaseId -cne [string]$derivedLeaseId -or [string]$event.scope -cne [string]$derivedScope -or
                    [string]$event.acquiredAtUtc -cne [string]$derivedAcquiredAtUtc -or [string]$event.expiresAtUtc -cne [string]$derivedExpiresAtUtc) {
                    throw "lease_ledger_invalid"
                }
                if ($occurred -ge (ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$derivedExpiresAtUtc) -ReasonCode "lease_ledger_invalid")) { throw "lease_ledger_invalid" }
                $derivedStatus = "idle"; $derivedAgent = $null; $derivedLeaseId = $null; $derivedScope = $null
                $derivedAcquiredAtUtc = $null; $derivedExpiresAtUtc = $null
            }
            "expired_recovered" {
                if ($derivedStatus -cne "active" -or $script:WriteLeaseAgents -cnotcontains [string]$event.agent -or
                    [string]$event.leaseId -cne [string]$derivedLeaseId -or [string]$event.scope -cne [string]$derivedScope -or
                    [string]$event.acquiredAtUtc -cne [string]$derivedAcquiredAtUtc -or [string]$event.expiresAtUtc -cne [string]$derivedExpiresAtUtc) {
                    throw "lease_ledger_invalid"
                }
                if ($occurred -lt (ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$derivedExpiresAtUtc) -ReasonCode "lease_ledger_invalid")) { throw "lease_ledger_invalid" }
                $derivedStatus = "idle"; $derivedAgent = $null; $derivedLeaseId = $null; $derivedScope = $null
                $derivedAcquiredAtUtc = $null; $derivedExpiresAtUtc = $null
            }
            default { throw "lease_ledger_invalid" }
        }
        $seen[$expectedId] = $true; $previousHash = [string]$event.eventSha256; $previousAt = $occurred; [void]$events.Add($event)
    }
    return [pscustomobject][ordered]@{
        text = $text; events = @($events); leaseStatus = $derivedStatus; holderAgent = $derivedAgent
        leaseId = $derivedLeaseId; scope = $derivedScope; acquiredAtUtc = $derivedAcquiredAtUtc; expiresAtUtc = $derivedExpiresAtUtc
    }
}

function Assert-DualAgentWriteLeaseRuntimeFiles {
    param([string]$RuntimeRoot, [switch]$IgnoreOwnedLock)
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) { return }
    foreach ($item in @(Get-ChildItem -LiteralPath $RuntimeRoot -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.PSIsContainer) { throw "lease_runtime_unregistered_file" }
        if ($item.Name -ceq $script:WriteLeaseLockName) { if (-not $IgnoreOwnedLock) { throw "lease_busy" }; continue }
        if ($item.Name -like ".lease-*") { throw "lease_transaction_residue_detected" }
        if ($item.Name -cnotin @($script:WriteLeaseStateName, $script:WriteLeaseLedgerName)) { throw "lease_runtime_unregistered_file" }
    }
}

function Get-DualAgentWriteLeaseSnapshot {
    param([string]$RuntimeRoot, [switch]$IgnoreOwnedLock)
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) { return Get-DualAgentWriteLeaseEmptySnapshot }
    Assert-DualAgentWriteLeaseRuntimeFiles -RuntimeRoot $RuntimeRoot -IgnoreOwnedLock:$IgnoreOwnedLock
    $statePath = Join-Path $RuntimeRoot $script:WriteLeaseStateName
    $ledgerPath = Join-Path $RuntimeRoot $script:WriteLeaseLedgerName
    $stateExists = Test-Path -LiteralPath $statePath -PathType Leaf
    $ledgerExists = Test-Path -LiteralPath $ledgerPath -PathType Leaf
    if (-not $stateExists -and -not $ledgerExists) { return Get-DualAgentWriteLeaseEmptySnapshot }
    if ($stateExists -ne $ledgerExists) { throw "lease_state_ledger_mismatch" }
    $state = Read-DualAgentWriteLeaseState -Path $statePath
    $ledger = Read-DualAgentWriteLeaseLedger -Path $ledgerPath
    $events = @($ledger.events); $last = $events[$events.Count - 1]
    if ([int64]$state.revision -ne $events.Count -or [string]$state.lastEventSha256 -cne [string]$last.eventSha256 -or
        [string]$state.updatedAtUtc -cne [string]$last.occurredAtUtc -or [string]$state.leaseStatus -cne [string]$ledger.leaseStatus -or
        [string]$state.holderAgent -cne [string]$ledger.holderAgent -or [string]$state.leaseId -cne [string]$ledger.leaseId -or
        [string]$state.scope -cne [string]$ledger.scope -or [string]$state.acquiredAtUtc -cne [string]$ledger.acquiredAtUtc -or
        [string]$state.expiresAtUtc -cne [string]$ledger.expiresAtUtc) { throw "lease_state_ledger_mismatch" }
    return [pscustomobject][ordered]@{
        schemaVersion = 1; projectId = $script:WriteLeaseProjectId; revision = [int64]$state.revision; leaseStatus = [string]$state.leaseStatus
        holderAgent = $state.holderAgent; leaseId = $state.leaseId; scope = $state.scope; acquiredAtUtc = $state.acquiredAtUtc
        expiresAtUtc = $state.expiresAtUtc; updatedAtUtc = [string]$state.updatedAtUtc; lastEventSha256 = [string]$state.lastEventSha256
        events = $events; ledgerText = [string]$ledger.text
        stateSha256 = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToUpperInvariant()
        ledgerSha256 = (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

function Enter-DualAgentWriteLeaseLock {
    param([string]$RuntimeRoot)
    $createdRoot = $false
    if (-not (Test-Path -LiteralPath $RuntimeRoot -PathType Container)) { [void][IO.Directory]::CreateDirectory($RuntimeRoot); $createdRoot = $true }
    if (Test-DualAgentWriteLeaseReparsePoint -Path $RuntimeRoot) { throw "lease_reparse_point_blocked" }
    $lockPath = Join-Path $RuntimeRoot $script:WriteLeaseLockName
    try {
        $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        return [pscustomobject][ordered]@{ path = $lockPath; stream = $stream; createdRoot = $createdRoot; runtimeRoot = $RuntimeRoot }
    }
    catch [IO.IOException] {
        if ($createdRoot -and @(Get-ChildItem -LiteralPath $RuntimeRoot -Force).Count -eq 0) { [IO.Directory]::Delete($RuntimeRoot, $false) }
        return $null
    }
}

function Exit-DualAgentWriteLeaseLock {
    param([AllowNull()]$Lock)
    if ($null -eq $Lock) { return }
    if ($null -ne $Lock.stream) { $Lock.stream.Dispose() }
    if (Test-Path -LiteralPath ([string]$Lock.path) -PathType Leaf) { [IO.File]::Delete([string]$Lock.path) }
    if ([bool]$Lock.createdRoot -and (Test-Path -LiteralPath ([string]$Lock.runtimeRoot) -PathType Container) -and
        @(Get-ChildItem -LiteralPath ([string]$Lock.runtimeRoot) -Force).Count -eq 0) { [IO.Directory]::Delete([string]$Lock.runtimeRoot, $false) }
}

function Write-DualAgentWriteLeasePreparedFile {
    param([string]$Path, [string]$Content)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() -cne (Get-DualAgentWriteLeaseSha256 -Bytes $bytes)) { throw "lease_transaction_prepare_failed" }
}

function Invoke-DualAgentWriteLeaseTransaction {
    param([string]$RuntimeRoot, $Snapshot, $State, $Event, [ValidateRange(0, 2)][int]$InjectFailureAfterPublish = 0)
    $suffix = [guid]::NewGuid().ToString("N")
    $statePath = Join-Path $RuntimeRoot $script:WriteLeaseStateName; $ledgerPath = Join-Path $RuntimeRoot $script:WriteLeaseLedgerName
    $stateText = $State | ConvertTo-Json -Depth 8; $eventLine = $Event | ConvertTo-Json -Depth 8 -Compress
    $ledgerText = if ([int64]$Snapshot.revision -eq 0) { $eventLine + "`r`n" } else { [string]$Snapshot.ledgerText + $eventLine + "`r`n" }
    $operations = @(
        [pscustomobject][ordered]@{ path=$ledgerPath; temporary=Join-Path $RuntimeRoot (".lease-$suffix-ledger.tmp"); backup=Join-Path $RuntimeRoot (".lease-$suffix-ledger.bak"); existed=([int64]$Snapshot.revision-gt0); expected=$Snapshot.ledgerSha256; backedUp=$false; published=$false; content=$ledgerText },
        [pscustomobject][ordered]@{ path=$statePath; temporary=Join-Path $RuntimeRoot (".lease-$suffix-state.tmp"); backup=Join-Path $RuntimeRoot (".lease-$suffix-state.bak"); existed=([int64]$Snapshot.revision-gt0); expected=$Snapshot.stateSha256; backedUp=$false; published=$false; content=$stateText }
    )
    $preserveBackups = $false
    try {
        foreach($operation in $operations){
            $exists=Test-Path -LiteralPath ([string]$operation.path) -PathType Leaf
            $actual=if($exists){(Get-FileHash -LiteralPath ([string]$operation.path) -Algorithm SHA256).Hash.ToUpperInvariant()}else{$null}
            if($exists-ne[bool]$operation.existed-or-not[string]::Equals([string]$actual,[string]$operation.expected,[StringComparison]::OrdinalIgnoreCase)){throw "lease_transaction_target_drifted"}
            Write-DualAgentWriteLeasePreparedFile -Path ([string]$operation.temporary) -Content ([string]$operation.content)
        }
        $publishedCount=0
        foreach($operation in $operations){
            if([bool]$operation.existed){[IO.File]::Move([string]$operation.path,[string]$operation.backup);$operation.backedUp=$true}
            [IO.File]::Move([string]$operation.temporary,[string]$operation.path);$operation.published=$true;$publishedCount++
            if($InjectFailureAfterPublish-eq$publishedCount){throw "lease_transaction_injected_failure"}
        }
        $verifiedState=Read-DualAgentWriteLeaseState -Path $statePath
        $verifiedLedger=Read-DualAgentWriteLeaseLedger -Path $ledgerPath
        $verifiedEvents=@($verifiedLedger.events);$verifiedLast=$verifiedEvents[$verifiedEvents.Count-1]
        if([int64]$verifiedState.revision-ne[int64]$State.revision-or[string]$verifiedState.lastEventSha256-cne[string]$State.lastEventSha256-or
            $verifiedEvents.Count-ne[int64]$State.revision-or[string]$verifiedLast.eventSha256-cne[string]$Event.eventSha256){throw "lease_transaction_post_verify_failed"}
        foreach($operation in $operations){if(Test-Path -LiteralPath ([string]$operation.backup)-PathType Leaf){[IO.File]::Delete([string]$operation.backup)}}
        return [pscustomobject][ordered]@{committed=$true;publishedCount=$publishedCount}
    }
    catch {
        $failure=[string]$_.Exception.Message
        try{for($i=$operations.Count-1;$i-ge0;$i--){$operation=$operations[$i];if([bool]$operation.published-and(Test-Path -LiteralPath ([string]$operation.path)-PathType Leaf)){[IO.File]::Delete([string]$operation.path)};if([bool]$operation.backedUp-and(Test-Path -LiteralPath ([string]$operation.backup)-PathType Leaf)){[IO.File]::Move([string]$operation.backup,[string]$operation.path)}}}
        catch{$preserveBackups=$true;throw "lease_transaction_rollback_failed"}
        if($failure.StartsWith("lease_",[StringComparison]::Ordinal)){throw $failure};throw "lease_transaction_failed"
    }
    finally{foreach($operation in $operations){if(Test-Path -LiteralPath ([string]$operation.temporary)-PathType Leaf){[IO.File]::Delete([string]$operation.temporary)};if(-not$preserveBackups-and(Test-Path -LiteralPath ([string]$operation.backup)-PathType Leaf)){[IO.File]::Delete([string]$operation.backup)}}}
}

function New-DualAgentWriteLeaseState {
    param($Snapshot, [string]$LeaseStatus, [AllowNull()]$Agent, [AllowNull()]$LeaseId,
        [AllowNull()]$Scope, [AllowNull()]$AcquiredAtUtc, [AllowNull()]$ExpiresAtUtc, $Event)
    return [pscustomobject][ordered]@{
        schemaVersion=1;projectId=$script:WriteLeaseProjectId;revision=[int64]$Snapshot.revision+1;leaseStatus=$LeaseStatus
        holderAgent=$Agent;leaseId=$LeaseId;scope=$Scope;acquiredAtUtc=$AcquiredAtUtc;expiresAtUtc=$ExpiresAtUtc
        updatedAtUtc=[string]$Event.occurredAtUtc;lastEventSha256=[string]$Event.eventSha256
    }
}

function Invoke-DualAgentWriteLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [AllowNull()][string]$RuntimeRoot,
        [AllowNull()][string]$Agent,
        [AllowNull()][string]$LeaseId,
        [AllowNull()][string]$Scope,
        [int]$TtlSeconds = -1,
        [AllowNull()][string]$ReasonCode,
        [switch]$AllowSystemTempFixture,
        [switch]$UserConfirmedRecovery,
        [AllowNull()][string]$TestOnlyNowUtc,
        [ValidateRange(0, 2)][int]$TestOnlyFailureAfterPublish = 0
    )
    try {
        if ($script:WriteLeaseOperations -cnotcontains $Operation) { throw "lease_operation_invalid" }
        $root = Assert-DualAgentWriteLeaseRuntimeRoot -RuntimeRoot $RuntimeRoot -AllowSystemTempFixture:$AllowSystemTempFixture
        $now = Get-DualAgentWriteLeaseNow -TestOnlyNowUtc $TestOnlyNowUtc -AllowSystemTempFixture:$AllowSystemTempFixture
        if ($TestOnlyFailureAfterPublish -gt 0 -and -not $AllowSystemTempFixture) { throw "lease_test_injection_rejected" }
        if ($UserConfirmedRecovery -and $Operation -cne "RecoverExpired") { throw "lease_arguments_invalid" }
        if ($Operation -ceq "Status" -or $Operation -ceq "CanWrite") {
            if ($TtlSeconds -ne -1 -or -not [string]::IsNullOrWhiteSpace($ReasonCode) -or $TestOnlyFailureAfterPublish -ne 0) { throw "lease_arguments_invalid" }
            if ($Operation -ceq "Status" -and (-not [string]::IsNullOrWhiteSpace($Agent) -or -not [string]::IsNullOrWhiteSpace($LeaseId) -or -not [string]::IsNullOrWhiteSpace($Scope))) { throw "lease_arguments_invalid" }
            if ($Operation -ceq "CanWrite" -and ($script:WriteLeaseAgents -cnotcontains $Agent -or [string]$LeaseId -cnotmatch "^[0-9a-f]{32}$" -or $script:WriteLeaseScopes -cnotcontains $Scope)) { throw "lease_arguments_invalid" }
            $snapshot = Get-DualAgentWriteLeaseSnapshot -RuntimeRoot $root
            $effectiveStatus = if ($snapshot.leaseStatus -ceq "active" -and $now -ge (ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$snapshot.expiresAtUtc))) { "expired" } else { [string]$snapshot.leaseStatus }
            if ($Operation -ceq "Status") {
                return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{
                    projectId=$snapshot.projectId;revision=$snapshot.revision;leaseStatus=$effectiveStatus;holderAgent=$snapshot.holderAgent
                    scope=$snapshot.scope;acquiredAtUtc=$snapshot.acquiredAtUtc;expiresAtUtc=$snapshot.expiresAtUtc;updatedAtUtc=$snapshot.updatedAtUtc
                }
            }
            $reason = "none"; $allowed = $true
            if ($effectiveStatus -ceq "idle") { $allowed=$false;$reason="lease_not_active" }
            elseif ($effectiveStatus -ceq "expired") { $allowed=$false;$reason="lease_expired" }
            elseif ([string]$snapshot.holderAgent -cne $Agent) { $allowed=$false;$reason="lease_holder_mismatch" }
            elseif ([string]$snapshot.leaseId -cne $LeaseId) { $allowed=$false;$reason="lease_id_mismatch" }
            elseif ([string]$snapshot.scope -cne $Scope) { $allowed=$false;$reason="lease_scope_mismatch" }
            return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode $reason -Fields @{
                projectId=$snapshot.projectId;revision=$snapshot.revision;leaseStatus=$effectiveStatus;holderAgent=$snapshot.holderAgent
                requestedAgent=$Agent;scope=$snapshot.scope;writeAllowed=$allowed;expiresAtUtc=$snapshot.expiresAtUtc
            }
        }
        if ($Operation -ceq "InitializeIdle") {
            if (-not [string]::IsNullOrWhiteSpace($Agent) -or -not [string]::IsNullOrWhiteSpace($LeaseId) -or -not [string]::IsNullOrWhiteSpace($Scope) -or
                $TtlSeconds -ne -1 -or [string]::IsNullOrWhiteSpace($ReasonCode)) { throw "lease_arguments_invalid" }
            if ($ReasonCode -cnotmatch "^[a-z][a-z0-9_]{0,63}$") { throw "lease_reason_code_invalid" }
            $lock=Enter-DualAgentWriteLeaseLock -RuntimeRoot $root;if($null-eq$lock){throw "lease_busy"}
            try{
                $snapshot=Get-DualAgentWriteLeaseSnapshot -RuntimeRoot $root -IgnoreOwnedLock
                if([int64]$snapshot.revision-ne0){throw "lease_already_initialized"}
                $event=New-DualAgentWriteLeaseEvent -EventType initialized_idle -Revision 1 -OccurredAt $now -Agent $null -LeaseId $null -Scope $null -AcquiredAtUtc $null -ExpiresAtUtc $null -PreviousEventSha256 $null -ReasonCode $ReasonCode
                $state=New-DualAgentWriteLeaseState -Snapshot $snapshot -LeaseStatus idle -Agent $null -LeaseId $null -Scope $null -AcquiredAtUtc $null -ExpiresAtUtc $null -Event $event
                $tx=Invoke-DualAgentWriteLeaseTransaction -RuntimeRoot $root -Snapshot $snapshot -State $state -Event $event -InjectFailureAfterPublish $TestOnlyFailureAfterPublish
                return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{leaseStatus="idle";revision=1;transactionComplete=[bool]$tx.committed;replayed=$false}
            }finally{Exit-DualAgentWriteLeaseLock -Lock $lock}
        }
        if ($Operation -ceq "Acquire") {
            if ($script:WriteLeaseAgents -cnotcontains $Agent -or -not [string]::IsNullOrWhiteSpace($LeaseId) -or
                $script:WriteLeaseScopes -cnotcontains $Scope -or $TtlSeconds -lt 60 -or $TtlSeconds -gt 3600 -or
                [string]::IsNullOrWhiteSpace($ReasonCode)) { throw "lease_arguments_invalid" }
            if ($ReasonCode -cnotmatch "^[a-z][a-z0-9_]{0,63}$") { throw "lease_reason_code_invalid" }
            $lock=Enter-DualAgentWriteLeaseLock -RuntimeRoot $root;if($null-eq$lock){throw "lease_busy"}
            try{
                $snapshot=Get-DualAgentWriteLeaseSnapshot -RuntimeRoot $root -IgnoreOwnedLock
                if([int64]$snapshot.revision-eq0){throw "lease_not_initialized"}
                if($snapshot.leaseStatus -ceq "active"){
                    if($now-ge(ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$snapshot.expiresAtUtc))){throw "lease_expired_recovery_required"}
                    throw "lease_busy"
                }
                $newLeaseId=[guid]::NewGuid().ToString("N");$acquiredAt=Format-DualAgentWriteLeaseUtc -Value $now;$expiresAt=Format-DualAgentWriteLeaseUtc -Value $now.AddSeconds($TtlSeconds)
                $event=New-DualAgentWriteLeaseEvent -EventType acquired -Revision ([int64]$snapshot.revision+1) -OccurredAt $now -Agent $Agent -LeaseId $newLeaseId -Scope $Scope -AcquiredAtUtc $acquiredAt -ExpiresAtUtc $expiresAt -PreviousEventSha256 ([string]$snapshot.lastEventSha256) -ReasonCode $ReasonCode
                $state=New-DualAgentWriteLeaseState -Snapshot $snapshot -LeaseStatus active -Agent $Agent -LeaseId $newLeaseId -Scope $Scope -AcquiredAtUtc $acquiredAt -ExpiresAtUtc $expiresAt -Event $event
                $tx=Invoke-DualAgentWriteLeaseTransaction -RuntimeRoot $root -Snapshot $snapshot -State $state -Event $event -InjectFailureAfterPublish $TestOnlyFailureAfterPublish
                return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{leaseStatus="active";holderAgent=$Agent;leaseId=$newLeaseId;scope=$Scope;acquiredAtUtc=$acquiredAt;expiresAtUtc=$expiresAt;revision=$state.revision;transactionComplete=[bool]$tx.committed;replayed=$false}
            }finally{Exit-DualAgentWriteLeaseLock -Lock $lock}
        }
        if ($Operation -ceq "Renew") {
            if ($script:WriteLeaseAgents -cnotcontains $Agent -or [string]$LeaseId -cnotmatch "^[0-9a-f]{32}$" -or
                $script:WriteLeaseScopes -cnotcontains $Scope -or $TtlSeconds -lt 60 -or $TtlSeconds -gt 3600 -or
                [string]::IsNullOrWhiteSpace($ReasonCode)) { throw "lease_arguments_invalid" }
            if ($ReasonCode -cnotmatch "^[a-z][a-z0-9_]{0,63}$") { throw "lease_reason_code_invalid" }
            $lock=Enter-DualAgentWriteLeaseLock -RuntimeRoot $root;if($null-eq$lock){throw "lease_busy"}
            try{
                $snapshot=Get-DualAgentWriteLeaseSnapshot -RuntimeRoot $root -IgnoreOwnedLock
                if($snapshot.leaseStatus -cne "active"){throw "lease_not_active"}
                if($now-ge(ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$snapshot.expiresAtUtc))){throw "lease_expired"}
                if([string]$snapshot.holderAgent-cne$Agent){throw "lease_holder_mismatch"}
                if([string]$snapshot.leaseId-cne$LeaseId){throw "lease_id_mismatch"}
                if([string]$snapshot.scope-cne$Scope){throw "lease_scope_mismatch"}
                $expiresAt=Format-DualAgentWriteLeaseUtc -Value $now.AddSeconds($TtlSeconds)
                $event=New-DualAgentWriteLeaseEvent -EventType renewed -Revision ([int64]$snapshot.revision+1) -OccurredAt $now -Agent $Agent -LeaseId $LeaseId -Scope $Scope -AcquiredAtUtc ([string]$snapshot.acquiredAtUtc) -ExpiresAtUtc $expiresAt -PreviousEventSha256 ([string]$snapshot.lastEventSha256) -ReasonCode $ReasonCode
                $state=New-DualAgentWriteLeaseState -Snapshot $snapshot -LeaseStatus active -Agent $Agent -LeaseId $LeaseId -Scope $Scope -AcquiredAtUtc ([string]$snapshot.acquiredAtUtc) -ExpiresAtUtc $expiresAt -Event $event
                $tx=Invoke-DualAgentWriteLeaseTransaction -RuntimeRoot $root -Snapshot $snapshot -State $state -Event $event -InjectFailureAfterPublish $TestOnlyFailureAfterPublish
                return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{leaseStatus="active";holderAgent=$Agent;leaseId=$LeaseId;scope=$Scope;acquiredAtUtc=$snapshot.acquiredAtUtc;expiresAtUtc=$expiresAt;revision=$state.revision;transactionComplete=[bool]$tx.committed;replayed=$false}
            }finally{Exit-DualAgentWriteLeaseLock -Lock $lock}
        }
        if ($Operation -ceq "Release") {
            if ($script:WriteLeaseAgents -cnotcontains $Agent -or [string]$LeaseId -cnotmatch "^[0-9a-f]{32}$" -or
                $script:WriteLeaseScopes -cnotcontains $Scope -or $TtlSeconds -ne -1 -or [string]::IsNullOrWhiteSpace($ReasonCode)) { throw "lease_arguments_invalid" }
            if ($ReasonCode -cnotmatch "^[a-z][a-z0-9_]{0,63}$") { throw "lease_reason_code_invalid" }
            $lock=Enter-DualAgentWriteLeaseLock -RuntimeRoot $root;if($null-eq$lock){throw "lease_busy"}
            try{
                $snapshot=Get-DualAgentWriteLeaseSnapshot -RuntimeRoot $root -IgnoreOwnedLock
                if($snapshot.leaseStatus -ceq "idle"){
                    $matching=@($snapshot.events|Where-Object{$_.eventType-ceq"released"-and[string]$_.agent-ceq$Agent-and[string]$_.leaseId-ceq$LeaseId-and[string]$_.scope-ceq$Scope-and[string]$_.reasonCode-ceq$ReasonCode})
                    if($matching.Count-eq1){return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{leaseStatus="idle";revision=$snapshot.revision;transactionComplete=$true;replayed=$true}}
                    throw "lease_not_active"
                }
                if([string]$snapshot.holderAgent-cne$Agent){throw "lease_holder_mismatch"}
                if([string]$snapshot.leaseId-cne$LeaseId){throw "lease_id_mismatch"}
                if([string]$snapshot.scope-cne$Scope){throw "lease_scope_mismatch"}
                if($now-ge(ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$snapshot.expiresAtUtc))){throw "lease_expired_recovery_required"}
                $event=New-DualAgentWriteLeaseEvent -EventType released -Revision ([int64]$snapshot.revision+1) -OccurredAt $now -Agent $Agent -LeaseId $LeaseId -Scope $Scope -AcquiredAtUtc ([string]$snapshot.acquiredAtUtc) -ExpiresAtUtc ([string]$snapshot.expiresAtUtc) -PreviousEventSha256 ([string]$snapshot.lastEventSha256) -ReasonCode $ReasonCode
                $state=New-DualAgentWriteLeaseState -Snapshot $snapshot -LeaseStatus idle -Agent $null -LeaseId $null -Scope $null -AcquiredAtUtc $null -ExpiresAtUtc $null -Event $event
                $tx=Invoke-DualAgentWriteLeaseTransaction -RuntimeRoot $root -Snapshot $snapshot -State $state -Event $event -InjectFailureAfterPublish $TestOnlyFailureAfterPublish
                return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{leaseStatus="idle";revision=$state.revision;transactionComplete=[bool]$tx.committed;replayed=$false}
            }finally{Exit-DualAgentWriteLeaseLock -Lock $lock}
        }
        if ($Operation -ceq "RecoverExpired") {
            if ($script:WriteLeaseAgents -cnotcontains $Agent -or [string]$LeaseId -cnotmatch "^[0-9a-f]{32}$" -or
                $script:WriteLeaseScopes -cnotcontains $Scope -or $TtlSeconds -ne -1 -or [string]::IsNullOrWhiteSpace($ReasonCode)) { throw "lease_arguments_invalid" }
            if (-not $UserConfirmedRecovery) { throw "lease_recovery_authorization_required" }
            if ($ReasonCode -cnotmatch "^[a-z][a-z0-9_]{0,63}$") { throw "lease_reason_code_invalid" }
            $lock=Enter-DualAgentWriteLeaseLock -RuntimeRoot $root;if($null-eq$lock){throw "lease_busy"}
            try{
                $snapshot=Get-DualAgentWriteLeaseSnapshot -RuntimeRoot $root -IgnoreOwnedLock
                if($snapshot.leaseStatus -cne "active"){throw "lease_not_active"}
                if([string]$snapshot.leaseId-cne$LeaseId){throw "lease_id_mismatch"}
                if([string]$snapshot.scope-cne$Scope){throw "lease_scope_mismatch"}
                if($now-lt(ConvertTo-DualAgentWriteLeaseUtc -Value ([string]$snapshot.expiresAtUtc))){throw "lease_not_expired"}
                $event=New-DualAgentWriteLeaseEvent -EventType expired_recovered -Revision ([int64]$snapshot.revision+1) -OccurredAt $now -Agent $Agent -LeaseId $LeaseId -Scope $Scope -AcquiredAtUtc ([string]$snapshot.acquiredAtUtc) -ExpiresAtUtc ([string]$snapshot.expiresAtUtc) -PreviousEventSha256 ([string]$snapshot.lastEventSha256) -ReasonCode $ReasonCode
                $state=New-DualAgentWriteLeaseState -Snapshot $snapshot -LeaseStatus idle -Agent $null -LeaseId $null -Scope $null -AcquiredAtUtc $null -ExpiresAtUtc $null -Event $event
                $tx=Invoke-DualAgentWriteLeaseTransaction -RuntimeRoot $root -Snapshot $snapshot -State $state -Event $event -InjectFailureAfterPublish $TestOnlyFailureAfterPublish
                return New-DualAgentWriteLeaseResult -Status "ok" -ReasonCode "none" -Fields @{leaseStatus="idle";revision=$state.revision;transactionComplete=[bool]$tx.committed;replayed=$false}
            }finally{Exit-DualAgentWriteLeaseLock -Lock $lock}
        }
        throw "lease_operation_not_implemented"
    }
    catch {
        $reason=[string]$_.Exception.Message;if(-not$reason.StartsWith("lease_",[StringComparison]::Ordinal)){$reason="lease_internal_error"}
        return New-DualAgentWriteLeaseResult -Status "blocked" -ReasonCode $reason
    }
}
