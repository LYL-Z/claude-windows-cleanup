# R3 — 受保护资源核验报告（V1.1）

- 核对时间：2026-11-18
- 基线：`reports/baseline-20261118-061848.json`
- 清单：`config/protected-resources.json`（57 个根 + 23 个路径模式 + 8 类扩展名）
- 方法：**只判存在性与是否重解析点**，不读取内容、不做哈希（内容级校验会读取用户数据，与红线冲突）

---

## 1. 结果

| 指标 | 数值 |
|------|------|
| 受保护根总数 | 57 |
| 本机存在 | **34** |
| 本机不存在 | 23 |
| 存在项中为重解析点 | **0** |
| 配置哈希 | `f471cba54855368e3f6a6b467ce21b2e774dcd2c99f233cc24db0963fa220ace` |
| 白名单哈希 | 见计划文件 `config_sha256` |

`verify.ps1` 判定：`[PASS] protected_resources 34 项受保护资源均存在`、`[PASS] protected_no_reparse`。

---

## 2. 本机存在的 34 项（按类别）

| 类别 | 内容 |
|------|------|
| 系统 | `%WINDIR%`、`%ProgramFiles%`、`%ProgramFiles(x86)%`、`%ProgramData%\Microsoft`、UWP `Packages` |
| 浏览器 | Chrome `%LOCALAPPDATA%\Google`、Edge `%LOCALAPPDATA%\Microsoft\Edge` |
| 个人 | `Documents`、`Desktop`、`Downloads`、`Pictures`、`Videos`、`Music` |
| 凭据/代码 | `.ssh`、`.gitconfig`、`.claude`、`.claude.json`、`.claude\projects`、`.claude\plugins`、`.claude\skills`、`.claude\sessions`、`.claude\session-env`、`.claude\state` |
| AI 工具 | `%LOCALAPPDATA%\Programs\DeepSeek Harness`、`%USERPROFILE%\.cursor`、`%USERPROFILE%\.vscode`、`%USERPROFILE%\.codex`、`%USERPROFILE%\.workbuddy` |
| 应用数据 | `%APPDATA%\Claude`、`%APPDATA%\Clash Verge`、`%LOCALAPPDATA%\Docker` |

> 完整逐条列表见基线 JSON 的 `protected_roots` 字段（含每条 `exists` / `reparse` / 原因）。

---

## 3. 本机不存在的 23 项（不代表"可删"，只代表未安装）

包括：Firefox/Opera 数据、`.git-credentials`、`.claude\.credentials.json`、
`.claude\memory`、`file-history`、`shell-snapshots`、`agents`、`commands`、`plans`、`tasks`、`todos`、
`%APPDATA%\Anthropic`、Obsidian/Cursor/WorkBuddy/Trae 的部分安装目录等。

**处置**：不存在 → 不产生任何操作，也不从清单移除（换机器/换安装方式后仍需保护）。

---

## 4. 新增保护（V1.1 相比 V1.0）

V1.0：`%APPDATA%\Claude`、`.claude`、`.claude.json`、浏览器根、个人目录等 24 条根 + 12 条模式。
V1.1 扩展到：

- Claude Code 全部子路径：`projects`、`memory`、`history.jsonl`、`file-history`、`shell-snapshots`、
  `plugins`、`skills`、`agents`、`commands`、`plans`、`tasks`、`sessions`、`todos`、`debug`、
  `paste-cache`、`image-cache`、`uploads`、`backups`、`statsig`、`usage-data`、`feedback-bundles`、`.credentials.json`
- 项目级资产模式：`CLAUDE.md`、`CLAUDE.local.md`、`.mcp.json`、`settings.local.json`
- 浏览器凭据文件模式：`Cookies`、`Login Data`、`Local State`、`Web Data`、`Bookmarks`、`History`、`Network`
- 网络代理：Clash Verge；IDE：`.vscode`、`.cursor`、`.codex`、`.workbuddy`

---

## 5. 局限（如实说明）

1. **只到存在性**：无法证明这些目录"内容完整未被改动"；做内容校验就要读取用户数据。
2. **只覆盖已登记路径**：`%USERPROFILE%` 之外、WSL 内部、Credential Manager、注册表共享配置未枚举。
3. **"不存在"不是承诺**：某目录当前不存在，不代表将来不会被创建；清单保留。
4. **保护 ≠ 备份**：本 Skill 不备份这些资源，只保证不去动它们。
