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

## 2. Local Multi-Agent Write Lease (Concurrency Mutex)

- **Agent Identity**: Every agent must declare its fixed identity (`codex`, `claude`, `gemini`, `cursor`, `windsurf`). Never borrow or forge another agent's identity.
- **Read-Only Operations**: Ordinary searches, queries, inspections, and lint checks require no lease.
- **Acquire Lease Before Mutation**:
  Before writing or modifying vault files, acquire a write lease via the CLI:
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" acquire <your-agent-identity>
  ```
- **Release Lease When Done**:
  Always release the lease in your final step:
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" release <your-agent-identity>
  ```
- **Self-Healing Protocol**:
  If a preceding lease expired due to an unexpected session crash or timeout, invoke recovery to restore the idle baseline:
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" recover
  ```
  *(Note: Active unexpired leases will be protected; only pass `-Force` if explicitly confirmed by the user).*
- **Post-Write Automated Snapshot**:
  Whenever you create or modify a formal knowledge card or record, invoke the backup script during task completion to ensure rolling snapshot protection:
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File "backup-obsidian-vault.ps1"
  ```

---

## 3. Knowledge Card Contract (7-Section Standard)

All atomic cards in `02_知识卡片/` must adhere to the 7-section structure:
1. **结论 (Conclusion)**: Hard-hitting takeaway in 1~2 sentences.
2. **适用场景 (Applicable Scenarios)**: When to apply this pattern.
3. **最小做法 (Minimal Implementation)**: The smallest reproducible steps or code.
4. **验证 (Verification)**: Objective proof that this works.
5. **不适用 (Non-Applicable)**: Boundary conditions and anti-patterns.
6. **风险 (Risks)**: Failure paths and hidden assumptions.
7. **来源 (Sources)**: Concrete fact citation (e.g. debugging log or project commit).

Required Frontmatter:
```yaml
---
status: verified
scope: cross-project
verified_at: YYYY-MM-DD
source: 07_问题与踩坑/xxxx.md
evidence_level: verified-single-project
---
```

To promote a staged draft from `02_知识卡片/_drafts/` to formal storage:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "promote-draft.ps1" -DraftName <card-name>
```

---

## 4. Security Boundaries

Never output, copy, or persist:
- `.env`, API Keys, Tokens, Passwords, Database connection strings, or sensitive proprietary data.
- Never modify `.obsidian/` configuration or delete notes without explicit user authorization.