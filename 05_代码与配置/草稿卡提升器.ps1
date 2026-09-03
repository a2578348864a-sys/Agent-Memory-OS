<#
.SYNOPSIS
    Promotes an atomic knowledge draft card from 02_知识卡片/_drafts/ to 02_知识卡片/.
.DESCRIPTION
    1. Gate 1: Validates active Write Lease gate (ensures caller holds valid, unexpired write lease).
    2. Gates 2-4: Validates draft structure, frontmatter, and 7 sections.
    3. Gate 5: Re-validates the identical immutable LeaseContext immediately before the first formal write.
    4. Step 6: Performs atomic formal card publication, index registration, full lint validation,
       and transactional byte-level rollback on any failure.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$DraftName,

    [Parameter(Position = 1)]
    [string]$Agent = "",

    [string]$LeaseId = "",

    [ValidateSet("automation_full_run", "nightly_health", "interactive_write")]
    [string]$Scope = "interactive_write",

    [string]$VaultRoot = "",

    [switch]$Force,

    [switch]$TestFailPrePublishLeaseCheck,

    [switch]$TestInjectFailureAfterTargetWrite
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($VaultRoot)) {
    $VaultRoot = Split-Path -Parent $PSScriptRoot
}

$coreScript = Join-Path (Join-Path $VaultRoot "05_代码与配置") "DualAgentWriteLeaseCore.ps1"
if (-not (Test-Path -LiteralPath $coreScript -PathType Leaf)) {
    throw "DualAgentWriteLeaseCore.ps1 not found at $coreScript"
}
. $coreScript

$cleanName = (Split-Path -Leaf $DraftName)
if (-not $cleanName.EndsWith(".md", [StringComparison]::OrdinalIgnoreCase)) {
    $cleanName += ".md"
}

$draftDir = Join-Path (Join-Path $VaultRoot "02_知识卡片") "_drafts"
$cardDir = Join-Path $VaultRoot "02_知识卡片"
$draftPath = Join-Path $draftDir $cleanName
$targetPath = Join-Path $cardDir $cleanName
$indexFile = Join-Path (Join-Path $VaultRoot "08_复盘与沉淀") "自动复用索引.md"
$lintScript = Join-Path (Join-Path $VaultRoot "05_代码与配置") "知识库lint检查器.ps1"
$runtimeRoot = Get-DualAgentWriteLeaseDefaultRuntimeRoot -VaultRoot $VaultRoot

# ---------------------------------------------------------
# Gate 1: Enforce Active Write Lease before processing draft
# ---------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($Agent)) {
    throw "lease_blocked: Write lease validation failed (lease_agent_required). An active lease holder must be specified."
}

if ([string]::IsNullOrWhiteSpace($LeaseId)) {
    $statePath = Join-Path $runtimeRoot "lease-state.json"
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $stateJson = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            if ($stateJson.holderAgent -ceq $Agent) {
                $LeaseId = [string]$stateJson.leaseId
            }
        } catch {}
    }
}

if ([string]::IsNullOrWhiteSpace($LeaseId)) {
    throw "lease_blocked: Write lease validation failed (lease_not_active). No active lease found for agent '$Agent'."
}

$canWrite = Invoke-DualAgentWriteLease -Operation CanWrite -Agent $Agent -LeaseId $LeaseId -Scope $Scope -RuntimeRoot $runtimeRoot
if (-not $canWrite.writeAllowed -or $canWrite.status -cne "ok") {
    $code = if ([string]::IsNullOrWhiteSpace([string]$canWrite.reasonCode)) { "lease_denied" } else { [string]$canWrite.reasonCode }
    throw "lease_blocked: Write lease validation failed ($code)."
}

# Construct immutable LeaseContext
$immutableLeaseContext = [ordered]@{
    agent = $Agent
    leaseId = $LeaseId
    scope = $Scope
    runtimeRoot = $runtimeRoot
}

# ---------------------------------------------------------
# Gate 2: Validate Target & Draft File Existence
# ---------------------------------------------------------
if (-not (Test-Path -LiteralPath $draftPath -PathType Leaf)) {
    throw "draft_not_found: $draftPath"
}

if ((Test-Path -LiteralPath $targetPath -PathType Leaf) -and -not $Force) {
    throw "target_card_already_exists: $targetPath (Use -Force to overwrite)"
}

$content = [System.IO.File]::ReadAllText($draftPath, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)

# ---------------------------------------------------------
# Gate 3: Validate YAML Frontmatter
# ---------------------------------------------------------
if ($content -notmatch "(?s)^---\r?\n(?<body>.*?)\r?\n---") {
    throw "invalid_frontmatter: Missing YAML frontmatter block"
}
$frontmatterBody = $Matches["body"]
$fields = @{}
foreach ($line in @($frontmatterBody -split "\r?\n")) {
    if ($line -match "^(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?<value>.*)$") {
        $fields[$Matches["key"]] = $Matches["value"].Trim().Trim('"')
    }
}

$requiredKeys = @("status", "scope", "verified_at", "source", "evidence_level")
foreach ($rk in $requiredKeys) {
    if (-not $fields.ContainsKey($rk) -or [string]::IsNullOrWhiteSpace([string]$fields[$rk])) {
        throw "missing_frontmatter_key: $rk"
    }
}

# ---------------------------------------------------------
# Gate 4: Validate 7 Required Sections
# ---------------------------------------------------------
$requiredSections = @("结论", "适用场景", "最小做法", "验证", "不适用", "风险", "来源")
$sectionNames = @([regex]::Matches($content, "(?m)^## (?<name>[^#\r\n]+?)\s*$") | ForEach-Object { $_.Groups["name"].Value.Trim() })
foreach ($rs in $requiredSections) {
    if ($sectionNames -cnotcontains $rs) {
        throw "missing_required_section: $rs"
    }
}

# ---------------------------------------------------------
# Step 5: Upgrade Content
# ---------------------------------------------------------
$todayUtc = [System.DateTime]::UtcNow.ToString("yyyy-MM-dd")
$newContent = $content
$newContent = [regex]::Replace($newContent, "(?m)^status\s*:\s*draft", "status: verified")
$newContent = [regex]::Replace($newContent, "(?m)^evidence_level\s*:\s*needs-more-evidence", "evidence_level: verified-single-project")
$newContent = [regex]::Replace($newContent, "(?m)^verified_at\s*:\s*1970-01-01", "verified_at: $todayUtc")

# ---------------------------------------------------------
# Gate 5: Pre-Publish Re-Verification of Immutable LeaseContext
# (Re-verified immediately before first formal write to disk)
# ---------------------------------------------------------
if ($TestFailPrePublishLeaseCheck) {
    throw "lease_blocked: Pre-publish write lease validation failed (test_injected_pre_publish_lease_failure)."
}

$prePublishCheck = Invoke-DualAgentWriteLease -Operation CanWrite -Agent $immutableLeaseContext.agent -LeaseId $immutableLeaseContext.leaseId -Scope $immutableLeaseContext.scope -RuntimeRoot $immutableLeaseContext.runtimeRoot
if (-not $prePublishCheck.writeAllowed -or $prePublishCheck.status -cne "ok") {
    $code = if ([string]::IsNullOrWhiteSpace([string]$prePublishCheck.reasonCode)) { "lease_denied" } else { [string]$prePublishCheck.reasonCode }
    throw "lease_blocked: Pre-publish write lease validation failed ($code)."
}

# ---------------------------------------------------------
# Step 6: Atomic Publication with Complete Rollback Guarantee
# (First formal card write begins; all actions from here roll back on failure)
# ---------------------------------------------------------
$originalDraftContent = $content
$originalIndexBytes = if (Test-Path -LiteralPath $indexFile -PathType Leaf) { [System.IO.File]::ReadAllBytes($indexFile) } else { $null }
$targetExisted = Test-Path -LiteralPath $targetPath -PathType Leaf
$originalTargetBytes = if ($targetExisted) { [System.IO.File]::ReadAllBytes($targetPath) } else { $null }

$tempStageDir = Join-Path ([System.IO.Path]::GetTempPath()) ("promote-stage-" + [System.Guid]::NewGuid().ToString("N"))
[void][System.IO.Directory]::CreateDirectory($tempStageDir)

try {
    # 6a. Write target formal card (first formal write)
    [System.IO.File]::WriteAllText($targetPath, $newContent, [System.Text.UTF8Encoding]::new($false))

    # [Fault Injection Point]: Simulate mid-transaction crash after target write
    if ($TestInjectFailureAfterTargetWrite) {
        throw "injected_failure_after_target_write: Simulated mid-transaction failure after formal write."
    }

    # 6b. Remove draft from staging
    Remove-Item -LiteralPath $draftPath -Force

    # 6c. Register in index
    $baseCardName = [System.IO.Path]::GetFileNameWithoutExtension($cleanName)
    if (Test-Path -LiteralPath $indexFile -PathType Leaf) {
        $indexText = [System.IO.File]::ReadAllText($indexFile, [System.Text.Encoding]::UTF8)
        if ($indexText -notmatch "\[\[$baseCardName(\]\]|\|)") {
            $updatedIndex = $indexText.TrimEnd() + "`r`n- [[$baseCardName]]`r`n"
            [System.IO.File]::WriteAllText($indexFile, $updatedIndex, [System.Text.UTF8Encoding]::new($false))
        }
    }

    # 6d. Validate with Lint
    $lintResultRaw = & $lintScript -VaultPath $VaultRoot
    $lintResult = $lintResultRaw | ConvertFrom-Json
    if (-not $lintResult.ok -or $lintResult.summary.issues -gt 0) {
        $issuesStr = ($lintResult.findings | ConvertTo-Json -Compress)
        throw "lint_failed_after_promotion: $issuesStr"
    }

    $result = [ordered]@{
        ok = $true
        action = "promoted"
        card = $cleanName
        vaultRoot = $VaultRoot
        targetPath = $targetPath
    }
    return ($result | ConvertTo-Json)
} catch {
    Write-Warning "Promotion failed. Performing atomic rollback: $_"
    # Rollback 1: Delete or restore target formal card
    if (-not $targetExisted -and (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        Remove-Item -LiteralPath $targetPath -Force
    } elseif ($targetExisted -and $null -ne $originalTargetBytes) {
        [System.IO.File]::WriteAllBytes($targetPath, $originalTargetBytes)
    }
    # Rollback 2: Restore original draft card
    [System.IO.File]::WriteAllText($draftPath, $originalDraftContent, [System.Text.UTF8Encoding]::new($false))
    # Rollback 3: Byte-level restore of index
    if ($null -ne $originalIndexBytes) {
        [System.IO.File]::WriteAllBytes($indexFile, $originalIndexBytes)
    }
    throw
} finally {
    # Cleanup TEMP staging files
    if (Test-Path -LiteralPath $tempStageDir -PathType Container) {
        Remove-Item -LiteralPath $tempStageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}