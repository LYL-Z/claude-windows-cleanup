# R2 — Claude 本地数据只读隐私安全评估

- 生成时间：2026-11-18
- 数据来源：`scripts/privacy-audit.ps1`（只读元数据）
- 原始报告：`reports/privacy-20261118-061653.json` / `.md`
- 模式：**不读取任何文件内容**，只统计路径、大小、文件数、修改时间、敏感文件名是否存在
- 判定：**PASS**（13 个目标 / 11 个存在 / 0 无法判定）

---

## 1. 实际检查结果（本机）

| 目标 | 状态 | 级别 | 规模 | 说明 |
|------|------|------|------|------|
| `.claude`（Claude Code 全局） | PRESENT | HIGH | 29.00 MB / 1314 文件 | 配置、会话、记忆、插件 |
| `.claude.json` | PRESENT | HIGH | 6.9 KB | 账号信息 / MCP / 项目状态 |
| `.claude\projects` | PRESENT | HIGH | 14.03 MB / 35 文件 | **明文会话记录** |
| `.claude\.credentials.json` | **ABSENT** | CRITICAL | — | 未发现 OAuth 凭据文件 |
| `.claude\backups` | PRESENT | MEDIUM | 32.2 KB / 5 文件 | 配置备份 |
| `%APPDATA%\Anthropic` | ABSENT | HIGH | — | 该认证方式未使用 |
| `%APPDATA%\Claude`（Desktop） | PRESENT | HIGH | 455 MB / 4607 文件 | 登录态 / 缓存 / MCP 配置 |
| `%LOCALAPPDATA%\Claude` | PRESENT | MEDIUM | 372 KB / 8 文件 | 日志 + 桌面端配置 |
| Chrome `User Data` | PRESENT | HIGH | 5.28 GB / 17749 文件 | 与所有网站共享 |
| Chrome `Default\Extensions` | PRESENT | MEDIUM | 60 MB / 1794 文件 | 是否含 Claude 扩展未确认 |
| Edge `User Data` | PRESENT | HIGH | 1.06 GB / 10419 文件 | 同上 |
| VS Code 扩展 | PRESENT | LOW | 1.31 GB / 18186 文件 | — |
| `.cursor` | PRESENT | MEDIUM | 241 MB / ≥20001 文件 | 计数达到上限，为下限值 |

运行中的相关进程：`chrome ×14`、`msedge ×15`、`WorkBuddy ×7`。

---

## 2. 风险发现（7 条）

| 级别 | 发现 | 含义 |
|------|------|------|
| **HIGH** | 明文会话记录 | `.claude\projects` 存在；官方文档说明 jsonl 里可能含代码片段、命令输出与配置 |
| MEDIUM | `.claude` 顶层存在敏感文件名 | 仅名称命中（`settings.json` 等），未读取内容 |
| MEDIUM | `%APPDATA%\Claude` 顶层存在敏感文件名 | `claude_desktop_config.json`、`Local State` 等 |
| MEDIUM | `%LOCALAPPDATA%\Claude` 存在配置文件 | 桌面端配置 |
| MEDIUM | Chrome 顶层存在 `Local State` | 浏览器加密密钥容器 |
| MEDIUM | Edge 顶层存在 `Local State` | 同上 |
| MEDIUM | 浏览器共享数据 | Cookie/本地存储与所有网站共享，本 Skill 不读不删 |

**没有发现** `.credentials.json`。这不等于"账号已退出"或"Token 不存在"——
凭据也可能在 Windows Credential Manager、`%APPDATA%\Anthropic` 之外的位置，或用其他机制保存。
本评估**只覆盖已登记的 13 个目标**。

---

## 3. 多账号与封号：能说与不能说

**能说的：**

- 本地数据按"目录/会话"组织，**不是按账号隔离**；不同账号使用期间的会话、记忆、备份可能共存。
- 封禁是**服务端**状态，不会触发本地清理；本地残留与账号是否可用是两件事。
- 退出登录只改变认证状态，不会自动删除历史会话、项目记忆、浏览器历史或已下载文件。
- 浏览器里同一 Profile 切换账号，站点数据会在同一份存储里累积；不同 Profile 才是隔离的。

**不能说的（本报告不主张）：**

- 不主张"存在某个文件 = 某账号仍有效"。
- 不主张"删除本地文件 = 服务端记录消失"。
- 不主张 Anthropic 具体采集了哪些硬件字段或用何种风控算法——没有公开证据。
- 不提供、也不会建立"账号关联痕迹清除清单"或任何反检测/指纹规避方案。

---

## 4. 官方退出与数据管理（由用户执行，本 Skill 不代劳）

1. **网页版**：`claude.ai` 右上角账户菜单 → 退出登录。是否清除该站点数据自行决定
   （Chrome：设置 → 隐私和安全 → 网站设置 → 查看权限和数据）。
2. **Chrome 扩展**：`chrome://extensions` 查看是否存在 Claude 相关扩展；不再使用可自行移除。
3. **Claude Code**：使用官方登录/登出流程；本 Skill 不执行、不读取凭据文件。
4. **被封禁账号的数据**：走 Anthropic 官方渠道申请导出或删除；本地操作不改变服务端记录。

---

## 5. 与维护流程的关系

- 隐私评估是**独立只读脚本**，不参与隔离/恢复，也不会把任何路径加入清理计划。
- `.claude`、`%APPDATA%\Claude`、浏览器目录在 `protected-resources.json` 里是硬保护项：
  即使有人放宽 `scope.json`，它们仍然被拒绝。
- 评估只输出"存在/大小/文件名"，不输出内容，因此不会把 Token、Cookie 写进报告。
- 已知边界：只核验存在性，不做内容级完整性；`%USERPROFILE%` 之外的盘符、WSL 内部、Credential Manager 未覆盖。

---

## 6. 结论

- 本机存在 **1 项 HIGH**（Claude Code 明文会话记录）与 **6 项 MEDIUM**（敏感文件名/浏览器共享数据）。
- 没有发现明文 OAuth 凭据文件；但"未发现"不等于"不存在"。
- 这些数据**全部保留**，本 Skill 不删除、不迁移、不改权限。
- 需要清理时必须由用户对具体路径逐项决定，并自行承担"重装后丢失登录态/配置"的后果。
