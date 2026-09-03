# Agent-Memory-OS Multi-Agent Rules

You are an AI coding assistant (Claude Code, OpenAI Codex, Gemini, Cursor, Windsurf, etc.) connected to this knowledge vault.
This repository serves as your long-term engineering memory across tasks, sessions, and models.

---

## 1. Reading Order (Before Taking Action)

1. `AGENTS.md` (This file)
2. `00_知识库总览.md`
3. `08_复盘与沉淀/自动复用索引.md`
4. The latest execution record in `04_执行记录/`

Report back clearly: your understanding of the goal, what files you plan to read/modify, and what you explicitly will not touch.

---

## 2. Distributed Write Lease (Concurrency Mutex)

- **Agent Identity**: Every agent must declare its fixed identity (`claude`, `codex`, `gemini`, `cursor`). Never borrow or forge another agent's identity.
- **Read-Only Operations**: Ordinary searches, queries, inspections, and lint checks require no lease.
- **Formal Mutations Require a Lease**: Before directly writing or modifying vault files, acquire a short write lease via `05_代码与配置/DualAgentWriteLeaseCore.ps1 -Operation Acquire -Agent <your-identity> -Scope interactive_write`.
- **Self-Healing Protocol**: If you detect that a preceding lease expired due to an unexpected session crash or timeout, you must automatically invoke `05_代码与配置/重置写租约.ps1` to restore the idle baseline. Never throw an unhandled error to block the user.
- **Post-Write Automated Snapshot**: Whenever you create or modify a formal knowledge card or record, invoke `05_代码与配置/知识库本地快照备份.ps1` during task completion to ensure rolling snapshot protection.

---

## 3. Knowledge Card Contract (7-Section Standard)

All atomic cards in `02_知识卡片/` must adhere to the 7-section structure:
1. **Conclusion (结论)**: Hard-hitting takeaway in 1~2 sentences.
2. **Applicable Scenarios (适用场景)**: When to apply this pattern.
3. **Minimal Implementation (最小做法)**: The smallest reproducible steps or code.
4. **Verification (验证)**: Objective proof that this works.
5. **Non-Applicable (不适用)**: Boundary conditions and anti-patterns.
6. **Risks (风险)**: Failure paths and hidden assumptions.
7. **Sources (来源)**: Concrete fact citation (e.g. debugging log or project commit).

Required Frontmatter:
```yaml
---
status: verified
scope: general
verified_at: YYYY-MM-DD
source: 07_问题与踩坑/xxxx.md
evidence_level: verified-single-project
---
```

---

## 4. Security Boundaries

Never output, copy, or persist:
- `.env`, API Keys, Tokens, Passwords, Database connection strings, or sensitive proprietary data.
- Never modify `.obsidian/` configuration or delete notes without explicit user authorization.