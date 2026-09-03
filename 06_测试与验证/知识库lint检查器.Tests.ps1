Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$lintPath = Join-Path (Split-Path $PSScriptRoot -Parent) "05_代码与配置\知识库lint检查器.ps1"
if (-not (Test-Path -LiteralPath $lintPath -PathType Leaf)) { throw "Lint script not found." }

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("kb-lint-test-" + [System.Guid]::NewGuid().ToString("N"))
$script:PassCount = 0
$script:FailCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $script:FailCount++
        Write-Host ("FAIL: " + $Message)
    }
    else {
        $script:PassCount++
    }
}

function New-TestVault {
    param([string]$Name)
    $vault = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $vault "02_知识卡片") -Force | Out-Null
    return $vault
}

function New-Card {
    param(
        [string]$Vault,
        [string]$Name,
        [string]$Frontmatter = "",
        [string]$Body = ""
    )
    $content = ""
    if ($Frontmatter -ne "") {
        $content = "---`n" + $Frontmatter + "`n---`n"
    }
    $content += $Body
    [System.IO.File]::WriteAllText(
        (Join-Path $Vault "02_知识卡片\$Name.md"),
        $content,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function New-RawDir {
    param([string]$Vault)
    New-Item -ItemType Directory -Path (Join-Path $Vault "raw") -Force | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $Vault "raw\00_raw说明.md"),
        "# raw 说明",
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function New-DraftCard {
    param(
        [string]$Vault,
        [string]$Name,
        [string]$Frontmatter = "",
        [string]$Body = ""
    )
    $draftDir = Join-Path $Vault "02_知识卡片\_drafts"
    if (-not (Test-Path -LiteralPath $draftDir -PathType Container)) {
        New-Item -ItemType Directory -Path $draftDir -Force | Out-Null
    }
    $content = ""
    if ($Frontmatter -ne "") {
        $content = "---`n" + $Frontmatter + "`n---`n"
    }
    $content += $Body
    [System.IO.File]::WriteAllText(
        (Join-Path $draftDir ($Name + ".md")),
        $content,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Run-Lint {
    param([string]$Vault)
    $out = & $lintPath -VaultPath $Vault 2>&1
    return ($out | Out-String | ConvertFrom-Json)
}

$validFrontmatter = @"
status: verified
scope: cross-project
verified_at: 2026-07-16
source: "demo-service/07_问题与踩坑/2026-07-16-xxx.md"
evidence_level: verified-single-project-strong
"@
$validBody = @"

# 卡片标题

## 结论

结论内容

## 适用场景

场景

## 最小做法

做法

## 验证

验证

## 不适用

不适用

## 风险

风险

## 来源

来源
"@

# --- 测试 1：空 vault（无卡片目录）---
$v = Join-Path $tempRoot "no-card-dir"
New-Item -ItemType Directory -Path $v -Force | Out-Null
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T1 无卡片目录应 ok=false"
Assert-True ($r.error -eq "card_directory_not_found") "T1 错误应为 card_directory_not_found"

# --- 测试 2：正常卡片，无问题 ---
$v = New-TestVault "clean"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
$r = Run-Lint $v
Assert-True ($r.ok -eq $true) "T2 正常库应 ok=true"
Assert-True ($r.cards_checked -eq 2) "T2 cards_checked 应为 2"
Assert-True ($r.summary.issues -eq 0) "T2 issues 应为 0"

# --- 测试 11：单向引用（A 引用 B，B 未回链）---
$v = New-TestVault "backlink"
New-Card -Vault $v -Name "卡片A" -Frontmatter $validFrontmatter -Body ($validBody + "`n[[卡片B]]")
New-Card -Vault $v -Name "卡片B" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[卡片A]]`n[[卡片B]]"
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T11 单向引用应 ok=false"
$backlinks = @($r.findings | Where-Object { $_.type -eq "missing_backlink" })
Assert-True ($backlinks.Count -ge 1) "T11 应报告 missing_backlink"

# --- 测试 12：双向引用正常 ---
$v = New-TestVault "backlink-ok"
New-Card -Vault $v -Name "卡片A" -Frontmatter $validFrontmatter -Body ($validBody + "`n[[卡片B]]")
New-Card -Vault $v -Name "卡片B" -Frontmatter $validFrontmatter -Body ($validBody + "`n[[卡片A]]")
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[卡片A]]`n[[卡片B]]"
$r = Run-Lint $v
Assert-True ($r.ok -eq $true) "T12 双向引用应 ok=true"

# --- 测试 3：缺少必填 frontmatter 字段 ---
$v = New-TestVault "missing-fm"
New-Card -Vault $v -Name "缺字段卡片" -Frontmatter "status: verified" -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[缺字段卡片]]"
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T3 缺字段应 ok=false"
$missing = @($r.findings | Where-Object { $_.type -eq "missing_frontmatter" })
Assert-True ($missing.Count -ge 4) "T3 应报告至少 4 个缺失字段，实际 $($missing.Count)"

# --- 测试 4：缺少必填章节 ---
$v = New-TestVault "missing-section"
New-Card -Vault $v -Name "缺章节卡片" -Frontmatter $validFrontmatter -Body "# 标题`n`n## 结论`n`n内容"
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[缺章节卡片]]"
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T4 缺章节应 ok=false"
$missing = @($r.findings | Where-Object { $_.type -eq "missing_section" })
Assert-True ($missing.Count -ge 1) "T4 应报告缺少章节"

# --- 测试 5：孤儿卡片（无引用）---
$v = New-TestVault "orphan"
New-Card -Vault $v -Name "孤儿卡片" -Frontmatter $validFrontmatter -Body $validBody
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T5 孤儿卡应 ok=false"
$orphans = @($r.findings | Where-Object { $_.type -eq "orphan_card" })
Assert-True ($orphans.Count -ge 1) "T5 应报告孤儿卡片"

# --- 测试 6：索引引用不存在的卡片 ---
$v = New-TestVault "index-break"
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[不存在的卡片]]"
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T6 索引漂移应 ok=false"
$breaks = @($r.findings | Where-Object { $_.type -eq "index_break" })
Assert-True ($breaks.Count -ge 1) "T6 应报告 index_break"

# --- 测试 7：双链指向不存在的 .md 文件 ---
$v = New-TestVault "wiki-link"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
[System.IO.File]::WriteAllText(
    (Join-Path $v "02_知识卡片\00_知识卡片说明.md"),
    "# 说明`n`n[[不存在文件.md]]",
    (New-Object System.Text.UTF8Encoding($false))
)
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T7 断链应 ok=false"
$missing = @($r.findings | Where-Object { $_.type -eq "wiki_link_missing" })
Assert-True ($missing.Count -ge 1) "T7 应报告 wiki_link_missing"

# --- 测试 8：raw 目录为空 ---
$v = New-TestVault "raw-empty"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-Item -ItemType Directory -Path (Join-Path $v "raw") -Force | Out-Null
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T8 raw 空应 ok=false"
$raw = @($r.findings | Where-Object { $_.type -eq "raw_empty" })
Assert-True ($raw.Count -ge 1) "T8 应报告 raw_empty"

# --- 测试 9：不存在的 vault 路径 ---
$r = Run-Lint "C:\definitely\not\here"
Assert-True ($r.ok -eq $false) "T9 不存在路径应 ok=false"
Assert-True ($r.error -eq "vault_not_found") "T9 错误应为 vault_not_found"

# --- 测试 10：lint 不修改任何文件（只读验证）---
$v = New-TestVault "readonly"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
$before = @(Get-ChildItem -LiteralPath (Join-Path $v "02_知识卡片") -Recurse | Select-Object FullName, Length, LastWriteTimeUtc | ConvertTo-Json -Depth 5) -join "`n"
Run-Lint $v | Out-Null
$after = @(Get-ChildItem -LiteralPath (Join-Path $v "02_知识卡片") -Recurse | Select-Object FullName, Length, LastWriteTimeUtc | ConvertTo-Json -Depth 5) -join "`n"
Assert-True ($before -ceq $after) "T10 lint 运行前后文件状态应完全一致"

$validDraftFrontmatter = @"
status: draft
scope: cross-project
verified_at: 1970-01-01
source: "raw/2026-08-10-外部资料.md"
evidence_level: needs-more-evidence
"@

# --- 测试 13：合法草稿卡（raw 来源）---
$v = New-TestVault "draft-ok"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
[System.IO.File]::WriteAllText((Join-Path $v "raw\2026-08-10-外部资料.md"), "# 外部资料", (New-Object System.Text.UTF8Encoding($false)))
New-DraftCard -Vault $v -Name "草稿卡" -Frontmatter $validDraftFrontmatter -Body $validBody
$r = Run-Lint $v
Assert-True ($r.ok -eq $true) "T13 合法草稿应 ok=true"
Assert-True ($r.summary.drafts_checked -eq 1) "T13 drafts_checked 应为 1，实际 $($r.summary.drafts_checked)"

# --- 测试 14：草稿卡缺章节 ---
$v = New-TestVault "draft-section"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
[System.IO.File]::WriteAllText((Join-Path $v "raw\2026-08-10-外部资料.md"), "# 外部资料", (New-Object System.Text.UTF8Encoding($false)))
New-DraftCard -Vault $v -Name "缺节草稿" -Frontmatter $validDraftFrontmatter -Body "# 标题`n`n## 结论`n`n内容"
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T14 草稿缺章节应 ok=false"
$missing = @($r.findings | Where-Object { $_.type -eq "missing_section" -and $_.file -like "*缺节草稿*" })
Assert-True ($missing.Count -ge 1) "T14 应报告草稿缺章节"

# --- 测试 15：草稿区卡 status 不是 draft ---
$v = New-TestVault "draft-status"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
New-DraftCard -Vault $v -Name "错状态草稿" -Frontmatter ($validDraftFrontmatter -replace "status: draft", "status: verified") -Body $validBody
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T15 草稿区 status=verified 应 ok=false"
$invalid = @($r.findings | Where-Object { $_.type -eq "draft_status_invalid" })
Assert-True ($invalid.Count -ge 1) "T15 应报告 draft_status_invalid"

# --- 测试 16：正式区卡 status 不是 verified ---
$v = New-TestVault "card-status"
New-Card -Vault $v -Name "错状态卡" -Frontmatter ($validFrontmatter -replace "status: verified", "status: draft") -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[错状态卡]]"
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T16 正式区 status=draft 应 ok=false"
$invalid = @($r.findings | Where-Object { $_.type -eq "card_status_invalid" })
Assert-True ($invalid.Count -ge 1) "T16 应报告 card_status_invalid"

# --- 测试 17：草稿 source 非 raw/ 前缀 ---
$v = New-TestVault "draft-source"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
New-DraftCard -Vault $v -Name "错来源草稿" -Frontmatter ($validDraftFrontmatter -replace 'raw/2026-08-10-外部资料.md', 'demo-project/07_问题与踩坑/x.md') -Body $validBody
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T17 草稿 source 非 raw 应 ok=false"
$invalid = @($r.findings | Where-Object { $_.type -eq "draft_source_invalid" })
Assert-True ($invalid.Count -ge 1) "T17 应报告 draft_source_invalid"

# --- 测试 18：正式卡链接草稿，草稿不回链 ---
$v = New-TestVault "draft-backlink"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body ($validBody + "`n[[草稿卡]]")
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
New-DraftCard -Vault $v -Name "草稿卡" -Frontmatter $validDraftFrontmatter -Body $validBody
$r = Run-Lint $v
Assert-True ($r.ok -eq $true) "T18 正式卡链接草稿（草稿不回链）应 ok=true"
$backlinks = @($r.findings | Where-Object { $_.type -eq "missing_backlink" })
Assert-True ($backlinks.Count -eq 0) "T18 草稿不应触发回链检查"

# --- 测试 19：草稿链接不存在目标 ---
$v = New-TestVault "draft-broken"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
New-DraftCard -Vault $v -Name "断链草稿" -Frontmatter $validDraftFrontmatter -Body ($validBody + "`n[[不存在文件.md]]")
$r = Run-Lint $v
Assert-True ($r.ok -eq $false) "T19 草稿断链应 ok=false"
$missing = @($r.findings | Where-Object { $_.type -eq "wiki_link_missing" })
Assert-True ($missing.Count -ge 1) "T19 应报告 wiki_link_missing"

# --- 测试 20：草稿区存在时 lint 仍只读 ---
$v = New-TestVault "draft-readonly"
New-Card -Vault $v -Name "正常卡片" -Frontmatter $validFrontmatter -Body $validBody
New-Card -Vault $v -Name "00_知识卡片说明" -Body "# 说明`n`n[[正常卡片]]"
New-RawDir $v
New-DraftCard -Vault $v -Name "草稿卡" -Frontmatter $validDraftFrontmatter -Body $validBody
$before = @(Get-ChildItem -LiteralPath (Join-Path $v "02_知识卡片") -Recurse -File | Select-Object FullName, Length, LastWriteTimeUtc | ConvertTo-Json -Depth 5) -join "`n"
Run-Lint $v | Out-Null
$after = @(Get-ChildItem -LiteralPath (Join-Path $v "02_知识卡片") -Recurse -File | Select-Object FullName, Length, LastWriteTimeUtc | ConvertTo-Json -Depth 5) -join "`n"
Assert-True ($before -ceq $after) "T20 有草稿时 lint 运行前后文件状态应完全一致"

# 清理
Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("通过: " + $script:PassCount + "  失败: " + $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
