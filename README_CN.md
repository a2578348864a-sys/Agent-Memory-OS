# Agent-Memory-OS 🧠⚡

<p align="center">
  <b>面向 AI 编程与多 Agent 协同的纯本地、高并发安全「外挂长期记忆操作系统」模版</b><br>
  <i>彻底终结 Claude Code、OpenAI Codex、Gemini、Cursor 与 Windsurf 的会话失忆与多 Agent 写入冲突。</i>
</p>

<p align="center">
  <a href="README.md">English</a> | <b>简体中文</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Architecture-Local--First-22c55e?style=flat-square" alt="Local First">
  <img src="https://img.shields.io/badge/Environment-Windows_PowerShell_5.1+-0078d4?style=flat-square" alt="Windows PowerShell">
  <img src="https://img.shields.io/badge/Supported_Agents-Claude_|_Codex_|_Gemini_|_Cursor_|_Windsurf-3b82f6?style=flat-square" alt="Multi Agent">
  <img src="https://img.shields.io/badge/Storage-Obsidian_Markdown-8b5cf6?style=flat-square" alt="Obsidian Markdown">
  <img src="https://img.shields.io/badge/Concurrency-Local_Write_Lease-ec4899?style=flat-square" alt="Local Write Lease">
  <img src="https://img.shields.io/badge/License-MIT-f59e0b?style=flat-square" alt="License">
</p>

<p align="center">
  <img src="assets/banner.png" alt="Agent-Memory-OS Hero Banner" width="100%">
</p>

---

## 🌟 为什么需要 Agent-Memory-OS？

在 AI 编程（AI Coding）的日常开发中，每个开发者都会遭遇以下三大核心瓶颈：

1. **多模型失忆与割裂**：每次新建会话或重启窗口，AI 记忆彻底归零。同一个 Bug 在不同工具里反复踩坑，白白浪费海量 Token。
2. **多 Agent 并发写入踩踏**：尝试让多个 AI 并行跑任务时，经常发生文件覆盖、写入冲突、代码被撤销覆盖的灾难。
3. **市面方案太重、门槛太高**：动辄需要部署 Docker 容器、配置向量数据库、Redis 缓存或对接昂贵的云端 API，难以直接审查与维护。

**Agent-Memory-OS 提供了一套开箱即用的纯本地工业级解法：**

- 📂 **纯本地优先（Local-First）**：基于标准 Obsidian Markdown，所有卡片和经验 100% 留在你自己的硬盘上，零外部服务依赖。
- 🔒 **本地多 Agent 写租约（Write Lease）**：内置轻量互斥写租约 CLI（`lease.ps1`），彻底杜绝多模型并发写入踩踏，支持自动死锁自愈。
- 🛡️ **双保险全自动热备（Zero-Manual Backup）**：写操作后自动快照 + SHA256 完整性清单，彻底消灭知识单点丢失风险。
- 🎯 **5 大场景技术栈靶向导航**：开工前按需过滤，消除上百张卡片带来的注意力稀释。
- 📐 **严格的两阶段门禁**：原子化 7 段式卡片合同 + 确定性 Lint 校验 + 原子转正工具（`promote-draft.ps1`），拒绝垃圾提示词污染长期记忆。

> [!NOTE]
> **环境要求**：Windows 10/11 系统，PowerShell 5.1 及以上版本（采用 Windows-first 原生设计）。

---

## 🏗️ 核心工作流与系统架构

<p align="center">
  <img src="assets/workflow.png" alt="Agent-Memory-OS Core Workflow" width="100%">
</p>

```mermaid
graph TD
    subgraph Clients["AI 编码助手 (多 Agent 接入层)"]
        Claude["Claude Code"]
        Codex["OpenAI Codex"]
        Gemini["Gemini / Antigravity"]
        Cursor["Cursor / Windsurf"]
    end

    subgraph Kernel["核心治理与安全层 (Kernel)"]
        Lease["写租约互斥<br>(lease.ps1 / DualAgentWriteLeaseCore.ps1)"]
        Reset["死锁自愈引擎<br>(lease.ps1 recover)"]
        Promote["草稿卡提升器<br>(promote-draft.ps1)"]
        Backup["自动滚动快照<br>(backup-obsidian-vault.ps1)"]
        Lint["7段式卡片与双链校验<br>(知识库lint检查器.ps1)"]
    end

    subgraph Vault["Obsidian 本地知识底座 (Local-First)"]
        Inbox["01_收件箱 / 暂存区"]
        Cards["02_知识卡片 / 7段式原子经验"]
        Exec["04_执行记录 / 任务事实账本"]
        Pitfalls["07_问题与踩坑 / 真实复盘"]
        Index["08_复盘与沉淀 / 场景导航索引"]
    end

    Claude -->|申请写租约| Lease
    Codex -->|申请写租约| Lease
    Gemini -->|申请写租约| Lease
    Cursor -->|申请写租约| Lease

    Lease -->|审计并授权落盘| Cards
    Reset -.->|自动识别并解锁| Lease
    Promote -->|原子提升转正| Cards
    Backup -.->|写后自动热备| Cards
    Lint -.->|质量门禁校验| Cards
```

---

## ⚡ 痛点对比 (Comparison)

| 特性维度 | 传统单会话 AI / 提示词库 | 重型向量检索库 (RAG/Docker) | **Agent-Memory-OS (本项目)** |
| :--- | :--- | :--- | :--- |
| **持久性** | ❌ 换个窗口立即遗忘 | ⚠️ 依赖本地/云端服务常驻 | ✅ **永久纯本地存储（Markdown）** |
| **多 Agent 协同** | ❌ 毫无防护，并发踩踏 | ❌ 仅检索，无写锁机制 | 🏆 **本地写租约 + 自动死锁自愈** |
| **部署成本** | ✅ 零配置 | ❌ 需 Docker / Redis / 数据库 | 🏆 **克隆即用，零外部依赖** |
| **知识纯度** | ❌ 幻觉提示词满天飞 | ⚠️ 向量近似猜测，质量失控 | 🏆 **严格 7 段式卡片 + Lint 门禁** |
| **容灾保护** | ❌ 误删直接全损 | ⚠️ 需手动配置数据库备份 | 🏆 **全自动本地滚动快照归档** |
| **Token 消耗** | ❌ 全量提示词硬塞上下文 | ⚠️ 相似度检索产生海量噪点 | 🏆 **5 大场景技术栈精准靶向直达** |

---

## 🚀 3 分钟快速上手

### 第 1 步：使用模板并完成一键初始化
点击本页面右上角绿色的 **[Use this template]** -> **[Create a new repository]**。  
克隆你的新仓库到本地，在根目录打开 PowerShell 并执行一键设置：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "setup.ps1"
```

该脚本将自动生成本仓库独立的唯一 `vaultId`，创建隔离的互斥锁环境，并完成首轮健康体验。

### 第 2 步：接入你的 AI 编程助手
将本仓库挂载到你的工作空间中：
- **Claude Code**：在项目指令中引用 `CLAUDE.md`。
- **OpenAI Codex**：在项目指令中引用 `CODEX.md`。
- **Gemini / Antigravity**：在系统指令中引用 `GEMINI.md`。
- **Cursor / Windsurf**：在全局提示词中配置：
  > *“在编写代码或修改架构前，务必先阅读 `AGENTS.md` 并查阅 `08_复盘与沉淀/自动复用索引.md` 中的相关经验。”*

### 第 3 步：并发安全的日常操作
所有 AI 助手均通过标准的命令行接口进行操作：
```powershell
# 1. 修改文件前申请租约
powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" acquire <your-agent>

# 2. 将审核合格的草稿卡原子提升为正式卡
powershell -NoProfile -ExecutionPolicy Bypass -File "promote-draft.ps1" -DraftName <card-name>

# 3. 任务结束释放租约
powershell -NoProfile -ExecutionPolicy Bypass -File "lease.ps1" release <your-agent>

# 4. 触发全库自动快照归档
powershell -NoProfile -ExecutionPolicy Bypass -File "backup-obsidian-vault.ps1"
```

---

## 📂 仓库目录结构说明

```text
Agent-Memory-OS/
├── README.md                     # 英文版项目文档
├── README_CN.md                  # [本文件] 简体中文项目文档
├── setup.ps1                     # 1-click 一键初始化与体检脚本
├── lease.ps1                     # 本地多 Agent 写租约 CLI 工具
├── promote-draft.ps1             # 原子两阶段草稿卡转正提升工具
├── backup-obsidian-vault.ps1     # 自动滚动快照备份入口
├── reset-obsidian-lease.ps1      # 租约死锁安全恢复入口
├── AGENTS.md                     # 多 Agent 协同统一规则源
├── CLAUDE.md / CODEX.md / ...    # 各工具专属接入配置
├── 一键备份知识库.cmd             # Windows 极简双击备份入口
├── 一键重置写租约.cmd             # Windows 极简双击恢复入口
├── 01_收件箱/                    # 待整理的临时想法、原始材料暂存
├── 02_知识卡片/                  # 经审核的原子化工程知识（7 段式结构）
│   └── _drafts/                  # 新卡片草稿区（待审核提升）
├── 03_项目索引/                  # 跨项目关系索引目录
├── 04_执行记录/                  # 任务执行历史事实账本
├── 05_代码与配置/                # 治理内核：写租约、备份、自愈、Lint、提升器
├── 06_测试与验证/                # 36+ 自动化测试套件与 Schema 契约
├── 07_问题与踩坑/                # 真实排查案例，为卡片提炼提供事实证据
├── 08_复盘与沉淀/                # 5 大场景快速导航索引与生命周期
└── 09_模板/                      # 标准化卡片与决策模板
```

---

## 🛡️ 内置自动化测试与质量保障

Agent-Memory-OS 将 AI 长期记忆视为严肃的企业级工程，配备严格的自动化测试集：

```powershell
# 1. 验证所有知识卡片的语法、7段式结构和双向链接
powershell -NoProfile -ExecutionPolicy Bypass -File "05_代码与配置/知识库lint检查器.ps1"

# 2. 运行 36 项断言的写租约互斥测试套件
powershell -NoProfile -ExecutionPolicy Bypass -File "06_测试与验证/DualAgentWriteLeaseCore.Tests.ps1"

# 3. 运行 38 项断言的卡片 Lint 校验器测试套件
powershell -NoProfile -ExecutionPolicy Bypass -File "06_测试与验证/知识库lint检查器.Tests.ps1"
```

---

## 🤝 贡献与开源许可

本项目基于宽松的 [MIT License](LICENSE) 开源。  
欢迎提交 Issue 和 Pull Request，共同打造面向未来的 AI 编程长期记忆底座！