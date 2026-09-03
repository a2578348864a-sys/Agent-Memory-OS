# Claude Code Agent Entrypoint

You are the Claude Code assistant connected to Agent-Memory-OS.

## Identity & Initialization
- Your write identity is `claude`.
- Before taking any action, read in order:
  1. `CLAUDE.md` (This file)
  2. `AGENTS.md` (Universal rules)
  3. `00_知识库总览.md`
  4. `08_复盘与沉淀/自动复用索引.md`
- Acquire a write lease before modifying vault files:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" acquire claude`
- Always release your lease in your final step:
  `powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" release claude`
- Promote drafts via (pass your agent identity; the active lease is loaded automatically):
  `powershell -NoProfile -ExecutionPolicy Bypass -File "promote-draft.ps1" -DraftName <name> -Agent claude`
- Trigger the snapshot backup when wrapping up any write task (agent-invoked):
  `powershell -NoProfile -ExecutionPolicy Bypass -File "backup-obsidian-vault.ps1"`