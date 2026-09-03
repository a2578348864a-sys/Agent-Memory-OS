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

function Get-VaultNoteIndex {
    param([Parameter(Mandatory = $true)][string]$VaultRoot)
    $relWithExt = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $relNoExt = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $baseNames = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    $baseDirMap = @{}
    Get-ChildItem -LiteralPath $VaultRoot -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($VaultRoot.Length).TrimStart('\', '/').Replace('\', '/')
        [void]$relWithExt.Add($rel)
        if ($rel -match '(?i)\.md$') {
            $rel = $rel.Substring(0, $rel.Length - 3)
        }
        [void]$relNoExt.Add($rel)
        $base = [System.IO.Path]::GetFileNameWithoutExtension($_.Name)
        [void]$baseNames.Add($base)
        $dirKey = Split-Path -Parent $rel
        if (-not $baseDirMap.ContainsKey($base)) { $baseDirMap[$base] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase) }
        [void]$baseDirMap[$base].Add($dirKey)
    }
    $ambigBase = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $baseDirMap.Keys) {
        if ($baseDirMap[$k].Count -gt 1) { [void]$ambigBase.Add($k) }
    }
    return [pscustomobject]@{
        relWithExt = $relWithExt
        relNoExt = $relNoExt
        baseNames = $baseNames
        ambigBase = $ambigBase
    }
}

function Get-NormalizedWikiTarget {
    param([Parameter(Mandatory = $true)][string]$LinkBody)
    $t = $LinkBody.Trim()
    if ([string]::IsNullOrEmpty($t)) { return "" }
    $cut = $t.Length
    foreach ($sep in @('|', '#')) {
        $i = $t.IndexOf($sep)
        if ($i -ge 0 -and $i -lt $cut) { $cut = $i }
    }
    if ($cut -le 0) { return "" }
    return $t.Substring(0, $cut).Trim()
}

function Get-WikiLinkTargetsInText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $targets = New-Object System.Collections.Generic.HashSet[string]
    $sb = New-Object System.Text.StringBuilder
    $inFence = $false
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
        if (-not $inFence) { [void]$sb.AppendLine($line) }
    }
    $plain = $sb.ToString()
    # 行内代码中的 [[...]] 与代码块一样不是 Obsidian 可解析链接
    $plain = [regex]::Replace($plain, '`[^`]*`', '')
    foreach ($m in [regex]::Matches($plain, '\[\[(?<body>[^\[\]]+)\]\]')) {
        $target = Get-NormalizedWikiTarget -LinkBody $m.Groups["body"].Value
        if (-not [string]::IsNullOrWhiteSpace($target)) { [void]$targets.Add($target) }
    }
    return $targets
}

function Test-WikiTargetResolves {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][pscustomobject]$NoteIndex
    )
    # 返回值：resolved_rel（精确相对路径命中）/ resolved_base（按 basename 唯一命中）
    #        / ambiguous_base（同名文件存在于多个目录，必须改用相对路径）
    #        / missing（不存在）
    if ([string]::IsNullOrWhiteSpace($Target)) { return "resolved_rel" }
    $t = $Target.Trim().Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($t)) { return "resolved_rel" }
    # 1) 精确相对路径匹配优先（兼容带 .md 与不带 .md 两种写法）
    $candidates = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
    [void]$candidates.Add($t)
    if ($t -match '(?i)\.md$') {
        [void]$candidates.Add($t.Substring(0, $t.Length - 3))
    } else {
        [void]$candidates.Add($t + ".md")
    }
    foreach ($c in $candidates) {
        if ($NoteIndex.relWithExt.Contains($c) -or $NoteIndex.relNoExt.Contains($c)) { return "resolved_rel" }
    }
    # 2) 无路径的裸名：按 basename 唯一性匹配；同名多目录 = 歧义，明确报告
    $leaf = $t
    $lastSlash = $t.LastIndexOf('/')
    if ($lastSlash -ge 0) { $leaf = $t.Substring($lastSlash + 1) }
    if ($leaf -match '(?i)\.md$') { $leaf = $leaf.Substring(0, $leaf.Length - 3) }
    if ([string]::IsNullOrWhiteSpace($leaf)) { return "missing" }
    if ($NoteIndex.ambigBase.Contains($leaf)) { return "ambiguous_base" }
    if ($NoteIndex.baseNames.Contains($leaf)) { return "resolved_base" }
    return "missing"
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

        # 1b. 正式卡日期/证据合同：verified_at 必须为真实 YYYY-MM-DD（禁止 1970-01-01 哨兵）；
        #     evidence_level 必须属于允许集合（与草稿共用 AllowedEvidenceLevels）。
        $vaText = ""
        if ($fm.ContainsKey("verified_at")) { $vaText = ([string]$fm["verified_at"]).Trim().Trim('"') }
        if (-not [string]::IsNullOrWhiteSpace($vaText)) {
            if ($vaText -ceq "1970-01-01") {
                [void]$findings.Add([ordered]@{ type = "card_verified_at_sentinel"; file = $f.Name; detail = "正式卡 verified_at 为模板哨兵 1970-01-01，禁止（真实卡必须填实际验证日期）" })
            } elseif ($vaText -notmatch '^\d{4}-\d{2}-\d{2}$') {
                [void]$findings.Add([ordered]@{ type = "card_verified_at_invalid"; file = $f.Name; detail = "正式卡 verified_at 必须为 YYYY-MM-DD，实际: $vaText" })
            } else {
                $vaParsedOk = $true
                try { [void][datetime]::ParseExact($vaText, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) }
                catch { $vaParsedOk = $false }
                if (-not $vaParsedOk) {
                    [void]$findings.Add([ordered]@{ type = "card_verified_at_invalid"; file = $f.Name; detail = "正式卡 verified_at 不是合法日期，实际: $vaText" })
                }
            }
        }
        if ($fm.ContainsKey("evidence_level") -and -not [string]::IsNullOrWhiteSpace([string]$fm["evidence_level"]) -and
            $script:AllowedEvidenceLevels -cnotcontains [string]$fm["evidence_level"]) {
            [void]$findings.Add([ordered]@{ type = "card_evidence_level_invalid"; file = $f.Name; detail = "正式卡 evidence_level 不在允许范围，实际: $($fm["evidence_level"])" })
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

    # 5. 全库双链：Obsidian WikiLink 目标必须真实存在于库内。
    #    支持 [[文件名]]、[[文件名|别名]]、[[文件名#标题]]、[[目录/文件名]]、[[目录/文件名|别名]]；
    #    不要求带 .md 后缀，按 vault 相对路径或 basename 规范化解析；代码块/行内代码不参与解析。
    $noteIndex = Get-VaultNoteIndex -VaultRoot $VaultRoot
    $checkedTargets = New-Object System.Collections.Generic.HashSet[string]
    foreach ($mdFile in @(Get-ChildItem -LiteralPath $VaultRoot -Filter "*.md" -File -Recurse -ErrorAction SilentlyContinue)) {
        $fileContent = Get-FileContentUtf8 -Path $mdFile.FullName
        foreach ($target in @(Get-WikiLinkTargetsInText -Text $fileContent)) {
            if ($checkedTargets.Contains($target)) { continue }
            [void]$checkedTargets.Add($target)
            $resolve = Test-WikiTargetResolves -Target $target -NoteIndex $noteIndex
            if ($resolve -eq "ambiguous_base") {
                [void]$findings.Add([ordered]@{ type = "wiki_link_ambiguous"; file = "(all)"; detail = "双链 basename 在多个目录重复，请改用带目录的相对路径: $target" })
            } elseif ($resolve -eq "missing") {
                [void]$findings.Add([ordered]@{ type = "wiki_link_missing"; file = "(all)"; detail = "双链指向不存在的笔记: $target" })
            }
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
