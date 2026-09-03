---
status: verified
scope: cross-project
verified_at: 2026-01-01
source: "[[07_问题与踩坑/2026-01-01-示例环境踩坑记录]]"
evidence_level: needs-more-evidence
---

# Windows CMD/BAT 脚本：纯 ASCII 原则

## 结论

Windows `.cmd` / `.bat` 批处理脚本**必须使用纯 ASCII 内容**。嵌入中文或其他非 ASCII 字符会导致 `cmd.exe` 解析错乱，抛出 `'xxx' is not recognized as an internal or external command`。

## 适用场景

- 编写或修改 Windows `.cmd` / `.bat` 启动脚本
- 在批处理脚本中拼接路径、传递参数
- 跨工具链调用（`.cmd` → PowerShell、Node.js CLI 等）

## 最小做法

1. `.cmd` / `.bat` 全程只用 ASCII 字符。
2. 换行使用 Windows CRLF（`\r\n`）。
3. 中文说明、注释、提示全部放到 `.md` 或 `.ps1` 文件中。
4. `.cmd` 只做薄包装：设环境变量、调用 PowerShell、转发参数。

## 验证

（示例验证，见 [[07_问题与踩坑/2026-01-01-示例环境踩坑记录]]）在示例环境中：
1. 用含中文参数/注释的 `.cmd` 调用 PowerShell，复现解析错乱；
2. 将 `.cmd` 改为纯 ASCII 内容后重新执行，命令正常解析、无乱码报错；
3. 仓库根目录的 `一键备份知识库.cmd`、`一键重置写租约.cmd` 均为按此原则编写的薄包装实例。

> 本卡为模板内置**脱敏示例卡（demo evidence）**，用于演示 7 段式卡片合同；验证过程来自仓库自带的示例踩坑记录，不代表任何特定生产项目的真实验收证据。

## 不适用

- PowerShell `.ps1` 脚本（可用 UTF-8 中文）
- Unix shell 脚本
- 不需要被 `cmd.exe` 解析的纯数据文件

## 风险

- 如果 `.cmd` 和 `.ps1` 文件不同步更新，可能出现行为不一致。
- 编码转换工具（如 `iconv`）可能引入不可见字符，验证时直接运行而非只看文件内容。
- PowerShell 侧的中文读写规范见 [[PowerShell中文UTF8读写]]。

## 来源

- [[07_问题与踩坑/2026-01-01-示例环境踩坑记录]]（本卡对应的脱敏示例记录）
- 仓库内按此原则编写的薄包装实例：`一键备份知识库.cmd`、`一键重置写租约.cmd`
- 关联示例卡：[[PowerShell中文UTF8读写]]
- 本卡为模板内置脱敏示例（demo evidence）。若在你的真实项目中再次验证，请按规范将 `evidence_level` 升级为 `verified-single-project` 并补充对应项目记录。
