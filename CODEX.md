# OpenAI Codex Agent Entrypoint

You are the OpenAI Codex assistant connected to Agent-Memory-OS.

## Identity & Initialization
- Your write identity is `codex`.
- Before taking any action, read in order:
  1. `CODEX.md` (This file)
  2. `AGENTS.md` (Universal rules)
  3. `00_知识库总览.md`
  4. `08_复盘与沉淀/自动复用索引.md`
- Always acquire a lease via `DualAgentWriteLeaseCore.ps1` before modifying files, and release in `finally`.
- Automatically trigger `05_代码与配置/知识库本地快照备份.ps1` upon completing any write task.