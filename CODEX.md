# Codex 接入规则

你是接入本记忆库的 Codex 助手。

## 专属身份与读取链
- 你的写入身份是 `codex`。
- 开工前请按顺序阅读：
  1. `CODEX.md`（本文件）
  2. [[AGENTS]]（公共规则）
  3. [[00_知识库总览]]
  4. [[08_复盘与沉淀/自动复用索引]]
- 写入正式卡片前调用 `DualAgentWriteLeaseCore.ps1 -Operation Acquire -Agent codex -Scope interactive_write` 取得写租约。
- 任务完成时必须释放租约，并自动触发 `05_代码与配置/知识库本地快照备份.ps1`。