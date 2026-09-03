[CmdletBinding()]
param(
    [string]$VaultPath = ""
)

if ([string]::IsNullOrWhiteSpace($VaultPath)) {
    $VaultPath = Split-Path -Parent $PSScriptRoot
}

# 只读 lint 检查器：扫描知识卡片目录，报告结构问题，不写任何文件。
# 设计原则：
# - 只读：绝不创建、修改或删除正式目录中的任何文件。
# - 确定性：同一输入必得同一输出，不依赖 AI、时间和外部网络。
# - 结构化输出：返回 JSON，失败/成功都可用，供脚本和人工查看。

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:CardDir = Join-Path $VaultPath "02_知识卡片"
$script:DraftDir = Join-Path $script:CardDir "_drafts"
$script:RawDir = Join-Path $VaultPath "raw"
$script:CardFile = Join-Path $script:CardDir "00_知识卡片说明.md"
$script:RequiredSections = @("结论", "适用场景", "最小做法", "验证", "不适用", "风险", "来源")
$script:RequiredFrontmatter = @("status", "scope", "verified_at", "source", "evidence_level")
$script:AllowedEvidenceLevels = @("needs-more-evidence", "verified-multi-project", "verified-single-project-strong", "verified-single-project")

function Get-FileContentUtf8 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $utf8.GetString($bytes)
}

function Get-FrontmatterFields {
    param([Parameter(Mandatory = $true)][string]$Content)
    $result = @{}
    if ($Content -notmatch "(?s)^---\r?\n(?<body>.*?)\r?\n---") { return $result }
    $body = $Matches["body"]
    foreach ($line in @($body -split "\r?\n")) {
        if ($line -match "^(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?<value>.*)$") {
            $result[$Matches["key"]] = $Matches["value"].Trim().Trim('"')
        }
    }
    return $result
}

function Get-CardMarkdownFiles {
    @(Get-ChildItem -LiteralPath $script:CardDir -Filter "*.md" -File | Sort-Object Name)
}

function Get-DraftCardMarkdownFiles {
    if (-not (Test-Path -LiteralPath $script:DraftDir -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $script:DraftDir -Filter "*.md" -File | Sort-Object Name)
}

function Get-AllWikiLinkTargets {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $targets = New-Object System.Collections.Generic.HashSet[string]
    Get-ChildItem -LiteralPath $Directory -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $content = Get-FileContentUtf8 -Path $_.FullName
        foreach ($m in [regex]::Matches($content, "\[\[(?<t>[^\]\|#]+)")) {
            [void]$targets.Add($m.Groups["t"].Value.Trim())
        }
        foreach ($m in [regex]::Matches($content, "\[\[[^\]]*\|(?<t>[^\]\]]+)\]\]")) {
            [void]$targets.Add($m.Groups["t"].Value.Trim())
        }
    }
    return $targets
}

function Get-ExistingNoteBaseNames {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $names = New-Object System.Collections.Generic.HashSet[string]
    Get-ChildItem -LiteralPath $Directory -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        [void]$names.Add($_.BaseName)
    }
    return $names
}

function ConvertTo-JsonSafe {
    param([Parameter(Mandatory = $true)]$Value)
    $Value | ConvertTo-Json -Depth 10
}

function Invoke-KbLint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$VaultRoot)

    $findings = New-Object System.Collections.ArrayList
    $summary = [ordered]@{}

    if (-not (Test-Path -LiteralPath $VaultRoot -PathType Container)) {
        return [ordered]@{
            ok = $false
            vault = $VaultRoot
            error = "vault_not_found"
            findings = @()
            summary = [ordered]@{ cards_checked = 0; issues = 0 }
        }
    }

    $cardDir = Join-Path $VaultRoot "02_知识卡片"
    if (-not (Test-Path -LiteralPath $cardDir -PathType Container)) {
        return [ordered]@{
            ok = $false
            vault = $VaultRoot
            error = "card_directory_not_found"
            findings = @()
            summary = [ordered]@{ cards_checked = 0; issues = 0 }
        }
    }

    $cardFiles = @(Get-ChildItem -LiteralPath $cardDir -Filter "*.md" -File | Sort-Object Name)
    $cardSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $cardFiles) { [void]$cardSet.Add($f.BaseName) }

    # 1. 每张卡片：必须带全部必填 frontmatter 字段
    #    （00_知识卡片说明.md 是索引文件，不检查卡片结构）
    foreach ($f in $cardFiles) {
        if ($f.BaseName -ceq "00_知识卡片说明") { continue }
        $content = Get-FileContentUtf8 -Path $f.FullName
        if ([string]::IsNullOrWhiteSpace($content)) {
            [void]$findings.Add([ordered]@{ type = "empty_card"; file = $f.Name; detail = "卡片文件为空" })
            continue
        }
        $fm = Get-FrontmatterFields -Content $content
        foreach ($req in $script:RequiredFrontmatter) {
            if (-not $fm.ContainsKey($req) -or [string]::IsNullOrWhiteSpace([string]$fm[$req])) {
                [void]$findings.Add([ordered]@{ type = "missing_frontmatter"; file = $f.Name; detail = "缺少必填字段: $req" })
            }
        }
        if ($fm.ContainsKey("source") -and [string]::IsNullOrWhiteSpace([string]$fm["source"])) {
            [void]$findings.Add([ordered]@{ type = "missing_source"; file = $f.Name; detail = "frontmatter source 为空" })
        }
        if ($fm.ContainsKey("status") -and [string]$fm["status"] -cne "verified") {
            [void]$findings.Add([ordered]@{ type = "card_status_invalid"; file = $f.Name; detail = "正式卡 status 必须为 verified，实际: $($fm["status"])" })
        }

        # 2. 必填章节必须齐全且顺序一致
        $sectionNames = @([regex]::Matches($content, "(?m)^## (?<name>[^#\r\n]+?)\s*$") | ForEach-Object { $_.Groups["name"].Value.Trim() })
        foreach ($req in $script:RequiredSections) {
            if ($sectionNames -cnotcontains $req) {
                [void]$findings.Add([ordered]@{ type = "missing_section"; file = $f.Name; detail = "缺少章节: $req" })
            }
        }
        if (@($sectionNames | Where-Object { $script:RequiredSections -contains $_ }).Count -ne $script:RequiredSections.Count) {
            # 章节不完整，跳过顺序检查，避免重复报告
        }
        elseif (($sectionNames -join "|") -cne ($script:RequiredSections -join "|")) {
            [void]$findings.Add([ordered]@{ type = "section_order"; file = $f.Name; detail = "章节顺序或多余章节: $($sectionNames -join ', ')" })
        }
    }

    # 2b. 草稿卡（02_知识卡片/_drafts/）：结构要求同正式卡，但 status 必须 draft、source 必须 raw/、evidence_level 可放宽
    $draftFiles = @(Get-DraftCardMarkdownFiles)
    foreach ($f in $draftFiles) {
        if ($f.BaseName -like "00_*") { continue }
        $content = Get-FileContentUtf8 -Path $f.FullName
        if ([string]::IsNullOrWhiteSpace($content)) {
            [void]$findings.Add([ordered]@{ type = "empty_draft_card"; file = $f.Name; detail = "草稿文件为空" })
            continue
        }
        $dm = Get-FrontmatterFields -Content $content
        foreach ($req in $script:RequiredFrontmatter) {
            if (-not $dm.ContainsKey($req) -or [string]::IsNullOrWhiteSpace([string]$dm[$req])) {
                [void]$findings.Add([ordered]@{ type = "missing_frontmatter"; file = $f.Name; detail = "草稿缺少必填字段: $req" })
            }
        }
        if ($dm.ContainsKey("status") -and [string]$dm["status"] -cne "draft") {
            [void]$findings.Add([ordered]@{ type = "draft_status_invalid"; file = $f.Name; detail = "草稿 status 必须为 draft，实际: $($dm["status"])" })
        }
        if ($dm.ContainsKey("evidence_level") -and $script:AllowedEvidenceLevels -cnotcontains [string]$dm["evidence_level"]) {
            [void]$findings.Add([ordered]@{ type = "draft_evidence_level_invalid"; file = $f.Name; detail = "草稿 evidence_level 不在允许范围: $($dm["evidence_level"])" })
        }
        if ($dm.ContainsKey("source") -and -not ([string]$dm["source"] -like "raw/*")) {
            [void]$findings.Add([ordered]@{ type = "draft_source_invalid"; file = $f.Name; detail = "草稿 source 必须以 raw/ 开头，实际: $($dm["source"])" })
        }
        $draftSectionNames = @([regex]::Matches($content, "(?m)^## (?<name>[^#\r\n]+?)\s*$") | ForEach-Object { $_.Groups["name"].Value.Trim() })
        foreach ($req in $script:RequiredSections) {
            if ($draftSectionNames -cnotcontains $req) {
                [void]$findings.Add([ordered]@{ type = "missing_section"; file = $f.Name; detail = "草稿缺少章节: $req" })
            }
        }
        if (@($draftSectionNames | Where-Object { $script:RequiredSections -contains $_ }).Count -eq $script:RequiredSections.Count -and
            ($draftSectionNames -join "|") -cne ($script:RequiredSections -join "|")) {
            [void]$findings.Add([ordered]@{ type = "section_order"; file = $f.Name; detail = "草稿章节顺序或多余章节: $($draftSectionNames -join ', ')" })
        }
    }

    # 3. 孤儿卡片：未被卡片说明索引、自动复用索引、执行记录、方案设计、测试验证等引用
    $searchDirs = @(
        (Join-Path $VaultRoot "03_项目索引"),
        (Join-Path $VaultRoot "04_执行记录"),
        (Join-Path $VaultRoot "03_方案与设计"),
        (Join-Path $VaultRoot "06_测试与验证"),
        (Join-Path $VaultRoot "07_问题与踩坑"),
        (Join-Path $VaultRoot "08_复盘与沉淀"),
        (Join-Path $VaultRoot "99_归档")
    )
    $linked = New-Object System.Collections.Generic.HashSet[string]
    # 卡片目录内的引用（含 00_知识卡片说明.md 索引）也计入
    foreach ($f in $cardFiles) {
        if ($f.BaseName -ceq "00_知识卡片说明") { continue }
        $content = Get-FileContentUtf8 -Path $f.FullName
        foreach ($m in [regex]::Matches($content, "\[\[(?<t>[^\]\|#]+)")) {
            $t = $m.Groups["t"].Value.Trim()
            if ($cardSet.Contains($t)) { [void]$linked.Add($t) }
        }
    }
    $indexContent = Get-FileContentUtf8 -Path $script:CardFile
    foreach ($m in [regex]::Matches($indexContent, "\[\[(?<t>[^\]\|#]+)")) {
        $t = $m.Groups["t"].Value.Trim()
        if ($cardSet.Contains($t)) { [void]$linked.Add($t) }
    }
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $dir -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $content = Get-FileContentUtf8 -Path $_.FullName
            foreach ($m in [regex]::Matches($content, "\[\[(?<t>[^\]\|#]+)")) {
                $t = $m.Groups["t"].Value.Trim()
                if ($cardSet.Contains($t)) { [void]$linked.Add($t) }
            }
        }
    }
    foreach ($card in $cardSet) {
        if ($card -ceq "00_知识卡片说明") { continue }
        if (-not $linked.Contains($card)) {
            [void]$findings.Add([ordered]@{ type = "orphan_card"; file = $card; detail = "未被任何索引或记录引用" })
        }
    }

    # 4. 知识卡片说明索引：检查索引中的卡片是否全部存在（引用漂移）
    if (Test-Path -LiteralPath $script:CardFile -PathType Leaf) {
        $indexContent = Get-FileContentUtf8 -Path $script:CardFile
        foreach ($m in [regex]::Matches($indexContent, "\[\[(?<t>[^\]\|#]+)")) {
            $t = $m.Groups["t"].Value.Trim()
            if (-not $cardSet.Contains($t) -and $t -ne "00_知识卡片说明") {
                [void]$findings.Add([ordered]@{ type = "index_break"; file = "00_知识卡片说明.md"; detail = "索引引用了不存在的卡片: $t" })
            }
        }
    }

    # 5. 全库双链：指向 .md 的链接必须存在于库内（跨目录引用检查）
    $existingNotes = Get-ExistingNoteBaseNames -Directory $VaultRoot
    $wikiTargets = Get-AllWikiLinkTargets -Directory $VaultRoot
    foreach ($target in $wikiTargets) {
        if ($target -match "\.md$" -and -not $existingNotes.Contains($target)) {
            [void]$findings.Add([ordered]@{ type = "wiki_link_missing"; file = "(all)"; detail = "双链指向不存在的文件: $target" })
        }
    }

    # 5b. 双向联动：卡片引用了另一张卡片时，被引用卡片必须回链本卡
    foreach ($f in $cardFiles) {
        if ($f.BaseName -ceq "00_知识卡片说明") { continue }
        $content = Get-FileContentUtf8 -Path $f.FullName
        $outbound = @([regex]::Matches($content, "\[\[(?<t>[^\]\|#]+)") | ForEach-Object { $_.Groups["t"].Value.Trim() } | Where-Object { $cardSet.Contains($_) -and $_ -cne $f.BaseName } | Sort-Object -Unique)
        foreach ($target in $outbound) {
            $targetFile = Join-Path $script:CardDir ($target + ".md")
            $targetContent = Get-FileContentUtf8 -Path $targetFile
            $backlink = [regex]::IsMatch($targetContent, "\[\[" + [regex]::Escape($f.BaseName) + "(?:\||\]\])")
            if (-not $backlink) {
                [void]$findings.Add([ordered]@{ type = "missing_backlink"; file = $f.Name; detail = "引用卡片 $target 未回链本卡" })
            }
        }
    }

    # 6. raw 目录：只读边界（lint 本身不写，只报告是否存在；若存在应含说明文件）
    if (Test-Path -LiteralPath $script:RawDir -PathType Container) {
        $rawFiles = @(Get-ChildItem -LiteralPath $script:RawDir -Filter "*.md" -File -ErrorAction SilentlyContinue)
        if ($rawFiles.Count -eq 0) {
            [void]$findings.Add([ordered]@{ type = "raw_empty"; file = "raw/"; detail = "raw 目录为空" })
        }
    }

    $issues = @($findings).Count
    return [ordered]@{
        ok = ($issues -eq 0)
        vault = $VaultRoot
        cards_checked = @($cardFiles).Count
        drafts_checked = @($draftFiles).Count
        findings = @($findings)
        summary = [ordered]@{ cards_checked = @($cardFiles).Count; drafts_checked = @($draftFiles).Count; issues = $issues }
    }
}

$result = Invoke-KbLint -VaultRoot $VaultPath
Write-Output (ConvertTo-JsonSafe -Value $result)
