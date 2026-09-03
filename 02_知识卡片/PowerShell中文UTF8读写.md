---
status: verified
scope: cross-project
verified_at: 2026-08-28
source: "[[04_执行记录/2026-07-02-Codex接入Obsidian知识库]]"
evidence_level: verified-single-project
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
5. **跨进程管道输出**（ps1 子进程 stdout 给 Node/其他程序按 UTF-8 读取）：PowerShell 5.1 默认按 OEM 代码页输出，接收方按 UTF-8 解码会得到 U+FFFD；必须在脚本最前（任何 JSON/文本输出之前）设置 `[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)` 与 `$OutputEncoding = [Console]::OutputEncoding`（5.1 实测语法有效），Node 端 `execFile(...,{encoding:'utf8'})` 才能正确解码中文路径/内容。

## 验证

```powershell
Get-Content -LiteralPath "中文文件.md" -Encoding UTF8 | Select-Object -First 3
```
确认中文正常显示。

管道场景验证（TDD 红→绿 + 反向）：
```powershell
# 在生成 JSON 的脚本最前执行
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
```
LOCAL_RUNTIME_SAFE_STOP：修复前真实管道测试 17 失败（中文『测试』变成 `D:\����\���̹���\...` U+FFFD，约 12 处 + 残留 U+0339），修复后 28/28 通过；反向验证仅移除两行 OutputEncoding → 测试 17 红（27/1）→ 字节级恢复锁 SHA256 后全套复绿 28/28。

## 不适用

- PowerShell 7+ 在 UTF-8 系统 locale 下（通常默认已是 UTF-8）
- 纯英文内容文件

## 风险

- PowerShell 5.x 控制台窗口本身的字体可能不支持中文显示（即使编码正确）。这是控制台渲染问题，不影响文件内容。
- 不同工具链（Git Bash、cmd、PowerShell）的编码默认值不同，跨工具传递内容时需显式指定。
- **管道输出编码比文件读写更隐蔽**：不经 `-Encoding` 参数，靠进程默认代码页；接收方无异常但内容已是 U+FFFD（无声坏数据），会以「奇怪的不匹配/校验失败」形式出现在下游逻辑中，排查时先怀疑编码。
- 执行权问题：`[Console]::OutputEncoding` 必须放在任何输出之前，只影响子进程 stdout 编码；不影响已输出内容与文件编码。

## 来源

- [[04_执行记录/2026-07-02-Codex接入Obsidian知识库]]
- `99_归档/2026-07-02-确认Obsidian知识库执行规则.md`（已归档，中文乱码问题首次出现于此）
- sourceId: demo-fullstack-service（管道输出编码）
- relativePath: 电商工具/docs/v4.1/LOCAL_RUNTIME_SAFE_STOP_PROGRESS.md
- sourceSha256: 0ED5FCC792A24C8DAA9BF401D66775E4DF183F2515DDEFDFBE5F2BBA1B161780
- verifiedAt: 2026-08-28
- evidenceLevel: verified-single-project
- verificationResult: 已核对 P1 根因（powershell.exe 5.1 管道默认 OEM 代码页 → Node execFile utf8 读中文路径得 U+FFFD，真实 3005 next start CommandLine 恒 child_next_entry_mismatch）、修复（OutputEncoding 前置两行）、红→绿（27/1 → 28/28）与反向验证（移除两行 → 红 → 字节级恢复复绿）
