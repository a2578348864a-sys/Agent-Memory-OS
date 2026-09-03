---
status: verified
scope: cross-project
verified_at: 2026-07-10
source: "[[07_问题与踩坑/2026-07-02-CMD脚本编码导致解析错乱]]"
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

```powershell
cmd /c "脚本路径.cmd" --version
```
确认正常输出，无编码解析错误。

## 不适用

- PowerShell `.ps1` 脚本（可用 UTF-8 中文）
- Unix shell 脚本
- 不需要被 `cmd.exe` 解析的纯数据文件

## 风险

- 如果 `.cmd` 和 `.ps1` 文件不同步更新，可能出现行为不一致。
- 编码转换工具（如 `iconv`）可能引入不可见字符，验证时直接运行而非只看文件内容。
- PowerShell 侧的中文读写规范见 [[PowerShell中文UTF8读写]]。

## 来源

- [[07_问题与踩坑/2026-07-02-CMD脚本编码导致解析错乱]]
- `启动Codex.cmd` 为按此原则编写的实例
