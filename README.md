# Agent-Memory-OS 🧠⚡

<p align="center">
  <b>A Local-First, Zero-Setup External Memory & Governance OS for Multi-Agent AI Coding</b><br>
  面向 AI 编程与多 Agent 协同的纯本地、开箱即用「外挂长期记忆操作系统」模版
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Architecture-Local--First-22c55e?style=flat-square" alt="Local First">
  <img src="https://img.shields.io/badge/Supported_Agents-Claude_Code_|_Codex_|_Gemini_|_Cursor_|_Windsurf-3b82f6?style=flat-square" alt="Multi Agent">
  <img src="https://img.shields.io/badge/Storage-Obsidian_Markdown-8b5cf6?style=flat-square" alt="Obsidian Markdown">
  <img src="https://img.shields.io/badge/License-MIT-f59e0b?style=flat-square" alt="License">
</p>

---

## 🌟 为什么需要 Agent-Memory-OS？ (Why Agent-Memory-OS?)

在 AI 编程（AI Coding）的日常开发中，每个开发者都会遭遇以下灵魂痛点：
1. **多模型失忆与割裂**：同时使用 Claude Code, OpenAI Codex, Gemini (Antigravity), Cursor，但每个会话一关，记忆彻底归零。同一个 Bug 在不同工具里反复踩坑。
2. **多 Agent 并发踩踏**：尝试让多个 AI 并行跑任务，经常发生文件覆盖、写入冲突、代码被覆盖的灾难。
3. **市面方案太重、门槛太高**：动辄需要部署 Docker、配置向量数据库（Chroma/Milvus）、对接 Redis 或购买商业云端 API，非程序员根本跑不起来。

**Agent-Memory-OS 提供了一套极致优雅的纯本地工业级解法：**
- 📂 **纯本地优先（Local-First）**：基于标准 Obsidian Markdown，所有卡片和经验 100% 留在你自己的硬盘上，零外部服务依赖。
- 🔒 **多 Agent 写租约互斥（Write Lease）**：内置类似 Chubby/etcd 的轻量租约协议，彻底解决多模型并发写入踩踏，支持自动死锁自愈。
- 🛡️ **双保险全自动热备（Zero-Manual Backup）**：写操作后自动快照 + 系统级静默定时轮转热备，彻底消灭知识单点全损风险。
- 🎯 **5 大场景技术栈靶向导航**：开工前按需过滤，节省 60% Token 并彻底消除上百张卡片带来的注意力稀释。
- 📐 **两阶段卡片质量门禁**：严格的 7 段式知识结构 + 确定性 Lint 校验，拒绝垃圾提示词污染长期记忆。

---

## 🏗️ 系统架构 (Architecture)

```mermaid
graph TD
    subgraph "AI Coding Assistants (多 Agent 接入层)"
        Claude[Claude Code]
        Codex[OpenAI Codex]
        Gemini[Gemini / Antigravity]
        Cursor[Cursor / Windsurf]
    end

    subgraph "Governance & Concurrency Kernel (核心治理与安全层)"
        Lease[DualAgentWriteLeaseCore.ps1<br>分布式写租约互斥]
        Reset[重置写租约.ps1<br>死锁自愈引擎]
        Backup[知识库本地快照备份.ps1<br>自动滚动快照]
        Lint[知识库lint检查器.ps1<br>7段式卡片与双链校验]
    end

    subgraph "Obsidian Knowledge Vault (本地知识底座)"
        Inbox["01_收件箱 / 暂存区"]
        Cards["02_知识卡片 / 7段式原子经验"]
        Exec["04_执行记录 / 任务事实账本"]
        Pitfall["07_问题与踩坑 / 真实复盘"]
        Index["08_复盘与沉淀 / 场景导航索引"]
    end

    Claude -->|Acquire Lease| Lease
    Codex -->|Acquire Lease| Lease
    Gemini -->|Acquire Lease| Lease
    Cursor -->|Acquire Lease| Lease

    Lease -->|Audit & Grant| Obsidian Knowledge Vault
    Reset -.->|Auto Self-Healing| Lease
    Backup -.->|Post-Write Hook & Cron| Obsidian Knowledge Vault
    Lint -.->|Quality Gate| Cards
```

---

## ⚡ 痛点对比 (Comparison)

| 特性维度 | 传统单会话 AI / 提示词库 | 重型向量检索库 (RAG/Docker) | **Agent-Memory-OS (本项目)** |
| :--- | :--- | :--- | :--- |
| **持久性** | ❌ 换个窗口立即遗忘 | ⚠️ 依赖本地/云端服务常驻 | ✅ **永久纯本地存储（Markdown）** |
| **多 Agent 协同** | ❌ 毫无防护，并发踩踏 | ❌ 仅检索，无写锁机制 | ✅ **分布式写租约 + 自动死锁自愈** |
| **部署成本** | ✅ 零配置 | ❌ 需 Docker / Redis / 数据库 | ✅ **解压即用，零外部依赖** |
| **可读性与编辑** | ❌ 散落在各对话历史 | ❌ 向量黑盒，不可直观修改 | ✅ **Obsidian 渲染，双链双向直观** |
| **抗全损能力** | ❌ 无法回滚 | ⚠️ 需专业数据库备份机制 | ✅ **自动增量快照 + SHA256 校验** |

---

## 🚀 3 分钟极速上手 (Quick Start)

### 第 1 步：使用本模版 (Use this template)
在 GitHub 仓库右上角点击 **[Use this template]** -> **[Create a new repository]**，克隆到你本地工作区（推荐配合 [Obsidian](https://obsidian.md/) 打开本目录）。

### 第 2 步：配置你的 AI 工具
将知识库根目录下的通用规则挂载到你的工作区：
- **Claude Code**：在项目根目录创建符号链接或直接引用 `CLAUDE.md`
- **Gemini / Antigravity**：直接引用 `GEMINI.md`
- **Codex / Cursor / Windsurf**：在你的工作区全局提示词中加入：
  > “请优先读取工作区中的 `AGENTS.md`，并在开工前按 `08_复盘与沉淀/自动复用索引.md` 的场景导航精读相关卡片。”

### 第 3 步：开始享受长期记忆
对 AI 吩咐任意目标：
- *“查一下我们在 Windows 下读写 UTF-8 的经验”* → AI 自动检索 `02_知识卡片/PowerShell中文UTF8读写.md`。
- *“把这次踩坑沉淀进知识库”* → AI 自动申请写租约、按 7 段式编写卡片并自动触发本地快照热备！

---

## 📋 目录结构规划 (Directory Structure)

```text
Agent-Memory-OS/
├── 00_知识库总览.md               # 知识库总入口与使用指南
├── AGENTS.md                     # 多 Agent 协同核心规则源
├── CLAUDE.md / GEMINI.md / ...   # 各 AI 工具专属入口
├── 一键备份知识库.cmd             # Windows 极简热备快捷入口
├── 一键重置写租约.cmd             # Windows 极简死锁复位快捷入口
├── 01_收件箱/                    # 待整理的灵感与临时材料
├── 02_知识卡片/                  # 核心原子经验卡片（7段式 + Frontmatter）
│   └── _drafts/                  # 草稿隔离区
├── 03_项目索引/                  # 跨子项目元数据
├── 04_执行记录/                  # Agent 任务审计账本
├── 05_代码与配置/                # 治理引擎：写租约、自动备份、自愈、Lint
├── 06_测试与验证/                # 自动化测试套件与 Schema 契约
├── 07_问题与踩坑/                # 真实排查案例与事实依据
├── 08_复盘与沉淀/                # 场景导航表与自动复用索引
└── 09_模板/                      # 标准化卡片与记录模板
```

---

## 🛠️ 本地自动化验证 (Verification)

本仓库内置了严谨的工程测试套件，运行 PowerShell 验证所有契约：

```powershell
# 1. 验证所有知识卡片语法与双链完整性
powershell -NoProfile -ExecutionPolicy Bypass -File "05_代码与配置/知识库lint检查器.ps1"

# 2. 运行写租约核心 36 项回归测试
powershell -NoProfile -ExecutionPolicy Bypass -File "06_测试与验证/DualAgentWriteLeaseCore.Tests.ps1"

# 3. 运行 Lint 检查器自身的回归测试
powershell -NoProfile -ExecutionPolicy Bypass -File "06_测试与验证/知识库lint检查器.Tests.ps1"
```

---

## 🤝 贡献与许可 (License & Contributing)

本项目采用宽松的 [MIT License](LICENSE) 开源许可。  
欢迎提交 Issue 与 Pull Request，共同完善面向多 Agent 编程的下一代外挂记忆体系！