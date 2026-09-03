# ResetWrapper.Tests.ps1
# 用途：验证“一键重置写租约”链路不存在假成功——
#   lease.ps1 recover 拒绝语义 -> 05_代码与配置/重置写租约.ps1 -> reset-obsidian-lease.ps1 -> 一键重置写租约.cmd
# 覆盖：
#   A. active 未过期且未 -Force：wrapper 与 CMD 都必须以非 0 退出（显示失败/被阻断，不显示 SUCCESS）
#   B. expired：wrapper 恢复成功（recovered_expired），exit 0
#   C. idle：wrapper 返回 already_idle，exit 0
# 本测试只调用 CLI 包装层，不改动 Lease Core 语义；每个场景使用独立 TEMP 克隆与独立 vaultId。

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

$repoRoot = Split-Path -Parent $PSScriptRoot
$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("AgentMemoryOS-ResetWrapper-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
$cleanupVaultIds = New-Object System.Collections.ArrayList

function New-ResetVault {
    param([string]$Name)
    $v = Join-Path $tempBase $Name
    [void][System.IO.Directory]::CreateDirectory($v)
    Copy-Item (Join-Path $repoRoot "*") -Destination $v -Recurse -Force
    $meta = Join-Path $v ".agent-memory-os.json"
    if (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force }
    return $v
}

function Get-VaultIdOf {
    param([string]$Vault)
    $meta = Join-Path $Vault ".agent-memory-os.json"
    if (Test-Path -LiteralPath $meta) {
        $j = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
        return [string]$j.vaultId
    }
    return $null
}

try {
    # ----------------------------------------------------
    # Scenario A: active unexpired, no -Force -> MUST FAIL
    # ----------------------------------------------------
    Write-Host "`n--- Scenario A: active unexpired (wrapper + CMD must fail) ---"
    $va = New-ResetVault "A-active"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $va "lease.ps1") acquire codex | Out-Null
    $vidA = Get-VaultIdOf -Vault $va
    if ($vidA) { [void]$cleanupVaultIds.Add($vidA) }

    $wrapperPath = Join-Path $va "05_代码与配置\重置写租约.ps1"
    $aOut = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapperPath 2>&1
    $aExit = $LASTEXITCODE
    $aText = ($aOut | Out-String)
    Assert-Test ($aExit -ne 0) "A1 wrapper exits non-zero on active unexpired (exit=$aExit)"
    Assert-Test ($aText -match "rejected_active_lease") "A2 wrapper reports rejected_active_lease"
    Assert-Test ($aText -notmatch "SUCCESS") "A3 wrapper output must not claim success"

    $cmdPath = Join-Path $va "一键重置写租约.cmd"
    $cOut = & $env:ComSpec /d /c ('"{0}" noninteractive' -f $cmdPath) 2>&1
    $cExit = $LASTEXITCODE
    $cText = ($cOut | Out-String)
    Write-Host "    (CMD exit=$cExit output=$($cText.Trim()))"
    Assert-Test ($cExit -ne 0) "A4 one-click CMD exits non-zero on active unexpired (exit=$cExit)"
    Assert-Test ($cText -notmatch "\[SUCCESS\]") "A5 one-click CMD must not print SUCCESS when blocked"
    Assert-Test ($cText -match "\[ERROR\]") "A6 one-click CMD prints [ERROR] when blocked"

    # ----------------------------------------------------
    # Scenario B: expired -> wrapper recovery succeeds
    # ----------------------------------------------------
    Write-Host "`n--- Scenario B: expired lease recovery (60s TTL, wait for expiry) ---"
    $vb = New-ResetVault "B-expired"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vb "lease.ps1") acquire codex -TtlSeconds 60 | Out-Null
    $vidB = Get-VaultIdOf -Vault $vb
    if ($vidB) { [void]$cleanupVaultIds.Add($vidB) }
    Start-Sleep -Seconds 62
    $bOut = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vb "05_代码与配置\重置写租约.ps1") 2>&1
    $bExit = $LASTEXITCODE
    $bText = ($bOut | Out-String)
    Assert-Test ($bExit -eq 0) "B1 wrapper exits zero on expired recovery (exit=$bExit)"
    Assert-Test ($bText -match "recovered_expired") "B2 wrapper reports recovered_expired"

    # ----------------------------------------------------
    # Scenario C: idle -> already_idle success
    # ----------------------------------------------------
    Write-Host "`n--- Scenario C: idle baseline (already initialized) ---"
    $vc = New-ResetVault "C-idle"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vc "lease.ps1") init | Out-Null
    $vidC = Get-VaultIdOf -Vault $vc
    if ($vidC) { [void]$cleanupVaultIds.Add($vidC) }
    $cOut2 = powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vc "05_代码与配置\重置写租约.ps1") 2>&1
    $cExit2 = $LASTEXITCODE
    $cText2 = ($cOut2 | Out-String)
    Assert-Test ($cExit2 -eq 0) "C1 wrapper exits zero on idle baseline (exit=$cExit2)"
    Assert-Test ($cText2 -match "already_idle") "C2 wrapper reports already_idle"

    Write-Host "`n=========================================================="
    Write-Host "ALL $script:PassedTests RESET-WRAPPER TESTS PASSED!"
    Write-Host "=========================================================="
    [pscustomobject]@{
        ok = $true
        passedTests = $script:PassedTests
        failedTests = $script:FailedTests
    } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $tempBase) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($vaultId in $cleanupVaultIds) {
        $rt = Join-Path (Join-Path $env:LOCALAPPDATA "AgentMemoryOS") $vaultId
        if (Test-Path -LiteralPath $rt) { Remove-Item -LiteralPath $rt -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
