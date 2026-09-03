---
status: verified
scope: cross-project
verified_at: 2026-01-01
source: "[[07_问题与踩坑/2026-01-01-示例环境踩坑记录]]"
evidence_level: needs-more-evidence
---

# PowerShell 中文文件：UTF-8 读写

## 结论

在 Windows PowerShell 中读取中文 Markdown 文件时，默认编码（OEM/GBK）会导致中文显示乱码。**必须显式指定 UTF-8 编码**读取和写入。PowerShell 5.x 和 7+ 的默认编码行为不同，写脚本时应兼容。

## 适用场景

- PowerShell 脚本读取中文 Markdown/文本文件
- AI 助手在 Windows 环境下处理中文内容
- 批处理/自动化脚本中涉及中文路径或内容

## 最小做法

1. 读取：`Get-Content -LiteralPath $path -Encoding UTF8`
2. 写入：`Add-Content -LiteralPath $path -Encoding UTF8` 或 `Set-Content -Encoding UTF8`
3. 避免在 `.cmd`/`.bat` 中处理中文（见 [[Windows-CMD脚本纯ASCII原则]]）。
4. 中文路径用 `-LiteralPath` 而非 `-Path`（避免通配符展开）。
5. **跨进程管道输出**（ps1 子进程 stdout 给 Node/其他程序按 UTF-8 读取）：PowerShell 5.1 默认按 OEM 代码页输出，接收方按 UTF-8 解码会得到 U+FFFD；应在脚本最前（任何 JSON/文本输出之前）设置 `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)` 与 `$OutputEncoding = [Console]::OutputEncoding`，接收方按 UTF-8 解码才能正确得到中文路径/内容。

## 验证

（示例验证，见 [[07_问题与踩坑/2026-01-01-示例环境踩坑记录]]）在模板自带的示例环境中复现并确认修复：
1. `.cmd` 保持纯 ASCII；中文说明移入以 UTF-8 with BOM 保存的 `.ps1`/`.md`。
2. 中文文件读取统一显式 `-Encoding UTF8`。
3. 重新执行后中文不再乱码、参数解析不再错乱；最后运行 `05_代码与配置/知识库lint检查器.ps1` 全库校验，issues=0。

> 本卡为模板内置**脱敏示例卡（demo evidence）**，用于演示 7 段式卡片合同；验证过程来自仓库自带的示例踩坑记录，不代表任何特定生产项目的真实验收证据。请在真实项目中复验后再升级 evidence_level。

## 不适用

- PowerShell 7+ 在 UTF-8 系统 locale 下（通常默认已是 UTF-8）
- 纯英文内容文件

## 风险

- PowerShell 5.x 控制台窗口本身的字体可能不支持中文显示（即使编码正确）。这是控制台渲染问题，不影响文件内容。
- 不同工具链（Git Bash、cmd、PowerShell）的编码默认值不同，跨工具传递内容时需显式指定。
- **管道输出编码比文件读写更隐蔽**：不经 `-Encoding` 参数，靠进程默认代码页；接收方无异常但内容已是 U+FFFD（无声坏数据），会以「奇怪的不匹配/校验失败」形式出现在下游逻辑中，排查时先怀疑编码。
- 执行权问题：`[Console]::OutputEncoding` 必须放在任何输出之前，只影响子进程 stdout 编码；不影响已输出内容与文件编码。

## 来源

- [[07_问题与踩坑/2026-01-01-示例环境踩坑记录]]（本卡对应的脱敏示例记录）
- 关联示例卡：[[Windows-CMD脚本纯ASCII原则]]
- 本卡为模板内置脱敏示例（demo evidence）。若在你的真实项目中再次验证，请按规范将 `evidence_level` 升级为 `verified-single-project` 并补充对应项目记录。
