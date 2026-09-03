# BackupWrapper.Tests.ps1
# 用途：验证“一键备份知识库”链路不存在假成功——
#   一键备份知识库.cmd -> backup-obsidian-vault.ps1 -> 05_代码与配置/知识库本地快照备份.ps1
# 覆盖：
#   A. 成功备份：根 PS1 与 CMD 都以 exit 0 退出，CMD 打印 [SUCCESS]，且确实生成 ZIP 产物
#   B. 内部备份脚本失败（参数绑定错误注入）：根 PS1 与 CMD 都必须非 0 退出，CMD 禁止打印 [SUCCESS]
#   C. 内部实现定位失败（05_* 目录缺失注入）：根 PS1 与 CMD 都必须非 0 退出，CMD 禁止打印 [SUCCESS]
# 本测试只调用 CLI 包装层，不改动备份核心逻辑；每个场景使用独立 TEMP fixture，
# 不触碰真实 Vault / 真实 backup / 真实 runtime，测试结束整体清理。
# 注意：native 命令的 stderr 在 EAP=Stop 下会以 NativeCommandError 中断，故所有
# native 捕获均经 Invoke-NativeCapture（临时 EAP=Continue）执行。

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

function Invoke-NativeCapture {
    param([scriptblock]$Block)
    $saved = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try { & $Block 2>&1 } finally { $ErrorActionPreference = $saved }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ("AgentMemoryOS-BackupWrapper-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))

function New-BackupFixture {
    param([string]$Name)
    $v = Join-Path $tempBase $Name
    [void][System.IO.Directory]::CreateDirectory($v)
    Copy-Item (Join-Path $repoRoot "*") -Destination $v -Recurse -Force
    $meta = Join-Path $v ".agent-memory-os.json"
    if (Test-Path -LiteralPath $meta) { Remove-Item -LiteralPath $meta -Force }
    $bk = Join-Path $v "_backups"
    if (Test-Path -LiteralPath $bk) { Remove-Item -LiteralPath $bk -Recurse -Force -ErrorAction SilentlyContinue }
    return $v
}

try {
    # ----------------------------------------------------
    # Scenario A: success -> root PS1 exit 0 + JSON ok; CMD exit 0 + [SUCCESS]
    # ----------------------------------------------------
    Write-Host "`n--- Scenario A: successful backup (root PS1 + CMD) ---"
    $va = New-BackupFixture "A-success"

    $aRaw = Invoke-NativeCapture { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $va "backup-obsidian-vault.ps1") }
    $aExit = $LASTEXITCODE
    $aJson = ($aRaw | Out-String) | ConvertFrom-Json
    Assert-Test ($aExit -eq 0) "A1 root PS1 exits zero on success (exit=$aExit)"
    Assert-Test ($aJson.ok -eq $true) "A2 root PS1 reports ok=true"
    Assert-Test (Test-Path -LiteralPath $aJson.zipPath -PathType Leaf) "A3 root PS1 created ZIP at $($aJson.zipPath)"

    $aCmd = Invoke-NativeCapture { & $env:ComSpec /d /c ('"{0}" noninteractive' -f (Join-Path $va "一键备份知识库.cmd")) }
    $aCmdExit = $LASTEXITCODE
    $aCmdText = ($aCmd | Out-String)
    Write-Host "    (CMD exit=$aCmdExit)"
    Assert-Test ($aCmdExit -eq 0) "A4 one-click CMD exits zero on success (exit=$aCmdExit)"
    Assert-Test ($aCmdText -match "\[SUCCESS\]") "A5 one-click CMD prints [SUCCESS] on success"
    Assert-Test ($aCmdText -notmatch "\[ERROR\]") "A6 one-click CMD must not print [ERROR] on success"

    # ----------------------------------------------------
    # Scenario B: internal backup script failure -> MUST be non-zero everywhere
    # ----------------------------------------------------
    Write-Host "`n--- Scenario B: internal script failure (param bind error injection) ---"
    $vb = New-BackupFixture "B-internal-fail"

    $bRaw = Invoke-NativeCapture { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vb "backup-obsidian-vault.ps1") -RetentionCount abc }
    $bExit = $LASTEXITCODE
    Assert-Test ($bExit -ne 0) "B1 root PS1 exits non-zero when internal backup fails (exit=$bExit)"

    $bCmd = Invoke-NativeCapture { & $env:ComSpec /d /c ('"{0}" noninteractive -RetentionCount abc' -f (Join-Path $vb "一键备份知识库.cmd")) }
    $bCmdExit = $LASTEXITCODE
    $bCmdText = ($bCmd | Out-String)
    Write-Host "    (CMD exit=$bCmdExit)"
    Assert-Test ($bCmdExit -ne 0) "B2 one-click CMD exits non-zero when internal backup fails (exit=$bCmdExit)"
    Assert-Test ($bCmdText -match "\[ERROR\]") "B3 one-click CMD prints [ERROR] when internal backup fails"
    Assert-Test ($bCmdText -notmatch "\[SUCCESS\]") "B4 one-click CMD must not print [SUCCESS] when internal backup fails"

    # ----------------------------------------------------
    # Scenario C: internal implementation cannot be located -> MUST be non-zero everywhere
    # ----------------------------------------------------
    Write-Host "`n--- Scenario C: code dir missing (05_* not found) ---"
    $vc = New-BackupFixture "C-no-codedir"
    Rename-Item -LiteralPath (Join-Path $vc "05_代码与配置") -NewName "05xx_disabled"
    Assert-Test (@(Get-ChildItem -LiteralPath $vc -Directory | Where-Object { $_.Name -like "05_*" }).Count -eq 0) "C0 fixture has no 05_* directory"

    $cRaw = Invoke-NativeCapture { powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $vc "backup-obsidian-vault.ps1") }
    $cExit = $LASTEXITCODE
    Assert-Test ($cExit -ne 0) "C1 root PS1 exits non-zero when code dir missing (exit=$cExit)"

    $cCmd = Invoke-NativeCapture { & $env:ComSpec /d /c ('"{0}" noninteractive' -f (Join-Path $vc "一键备份知识库.cmd")) }
    $cCmdExit = $LASTEXITCODE
    $cCmdText = ($cCmd | Out-String)
    Write-Host "    (CMD exit=$cCmdExit)"
    Assert-Test ($cCmdExit -ne 0) "C2 one-click CMD exits non-zero when code dir missing (exit=$cCmdExit)"
    Assert-Test ($cCmdText -match "\[ERROR\]") "C3 one-click CMD prints [ERROR] when code dir missing"
    Assert-Test ($cCmdText -notmatch "\[SUCCESS\]") "C4 one-click CMD must not print [SUCCESS] when code dir missing"

    Write-Host "`n=========================================================="
    Write-Host "ALL $script:PassedTests BACKUP-WRAPPER TESTS PASSED!"
    Write-Host "=========================================================="
    [pscustomobject]@{
        ok = $true
        passedTests = $script:PassedTests
        failedTests = $script:FailedTests
    } | ConvertTo-Json
} finally {
    if (Test-Path -LiteralPath $tempBase) { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction SilentlyContinue }
}
