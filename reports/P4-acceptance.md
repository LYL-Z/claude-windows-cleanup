# P0–P4 交付验收报告

- 生成时间：2026-11-18 05:55（本地）
- 机器：<HOSTNAME> / <user>
- 系统：Microsoft Windows 11 家庭版 中文版，build 26300
- PowerShell：5.1.26100.9818（Desktop，**无 pwsh 7**）
- 管理员：**False**（全程未提权）
- Skill 源码指纹：`c10968ba74d4aeb7a13a76e8bb1f2db5bb36149af73bb2d737fc0a6a41e99def`

---

## 1. 结论

| 阶段 | 状态 | 说明 |
|------|------|------|
| P0 环境基线与源码复核 | **PASS** | 基线已落盘；参考仓库独立审计完成 |
| P1 Claude 专项只读检查 | **PASS** | 安装状态 `UNINSTALLED_CONFIRMED`；3 项 VERIFIED；0 项 BLOCKED |
| P2 安全执行引擎 | **PASS** | 10 个脚本；默认拒绝、只隔离不删除、哈希绑定、失败即停全部在代码层 |
| P3 自动化安全测试 | **PASS** | 36 passed / 0 failed |
| P4 只读检查 + 维护计划 | **PASS** | 计划已生成，**所有条目默认未选中** |
| P5 实际维护 | **BLOCKED** | 等待用户逐项授权；本轮未执行任何删除/隔离/注册表/ACL/系统配置修改 |
| P6 维护后验证 | 未开始 | 依赖 P5 |
| P7 最终交付 | 进行中 | 本报告 + 源码 + 全部证据 |

**一句话**：开发与验证阶段 PASS；真实维护停在授权门前，状态 **BLOCKED**。

---

## 2. 参考仓库复核（P0）

`boyingliu01/windows-residual-cleaner` @ `93ab08e`：无恶意代码、无外联、无提权、无凭据访问，
但存在 **4 HIGH / 8 MEDIUM / 8 LOW**，判定 **PARTIAL**。详见 `docs/reference-audit.md`。

其中三条是本次新 Skill 的直接设计动因：

1. 不可读目录被判「空目录 Safe」→ 夺权后递归删除从未读取过的内容（实测复现）；
2. 删除层没有路径白名单，`final-report.json` 是唯一信任源（实测 DryRun 接受系统路径）；
3. 三道安全闸门只写在 `SKILL.md`，代码不强制（`-Mode A` 可批量删除）。

---

## 3. 只读检查结果（P1）

- 安装状态：**UNINSTALLED_CONFIRMED**
- 依据：无卸载注册项、无 MSIX、无进程/服务/任务、无安装目录；但存在产品数据目录
- 受保护资源观察：**23 项存在**（只判存在性，未读取内容）
- 检查报告：`reports/inspection-20261118-055151.json`

| ID | 状态 | 类型 | 大小 | 路径 | 处置 |
|----|------|------|------|------|------|
| cwc-0001 | VERIFIED | logs | 372.0 KB | `C:\Users\<user>\AppData\Local\Claude\logs` | 可隔离（未选中） |
| cwc-0002 | VERIFIED | logs | 368.4 KB | `C:\ProgramData\Claude\Logs` | 可隔离（未选中） |
| cwc-0003 | VERIFIED | shortcut_dir | 0 B | `C:\Users\<user>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Anthropic` | 可隔离（未选中） |

> `%APPDATA%\Claude`（约 455 MB，含登录态 / 缓存 / `claude_desktop_config.json`）与
> `%USERPROFILE%\.claude`（Claude Code）均被标记为 **PROTECTED**，不在候选清单内。
> 这是有意设计，不是遗漏。

---

## 4. 执行引擎的代码层保障（P2）

| 保障 | 实现 |
|------|------|
| 默认只读 | 只有 `quarantine.ps1 -Execute` 会写文件系统 |
| 默认拒绝 | 6 个规范根之外一律 BLOCKED（`Test-CwcItemSafety`） |
| 不可读 ≠ 不存在 | 枚举/打开失败即 `BLOCKED(unreadable)` |
| 拒绝重解析点 | 目标、祖先、子树任一 junction/symlink 即拒绝 |
| 只隔离不删除 | 唯一写操作是 `Move-Item` 到同卷隔离区 |
| 不做 takeown / ACL / 提权 | 全仓无相关调用 |
| 不写注册表 / 环境变量 / 服务 | 全仓只读这些对象 |
| 计划-审批哈希绑定 | `plan_sha256` + sidecar + 审批绑定 + 实时复核 |
| 执行前逐项复核 | 类型 + 大小 + 目录摘要 + 可读性 |
| 失败即停 | 任一条目失败立即停止并写日志 |

---

## 5. 测试结果（P3）

- 报告：`reports/test-report-20261118-055129.txt`
- 结果：**36 passed / 0 failed**（无 Pester 依赖，全部在 `%TEMP%` 沙盒）
- 覆盖：越界、不可读、联接点、相似名称、路径穿越、通配符、UNC、相对路径、卷根、
  `.git` / `.claude` / `%APPDATA%\Claude` 保护、计划哈希、审批篡改、未授权、DryRun 零修改、
  状态变化、中途失败、隔离根不可用、恢复完整性、幂等。

开发过程中实测发现并修正 5 个真实缺陷（详见 `CHANGELOG.md`）：

1. `File.Replace(..., $null)` 在 PowerShell 中被转成空串 → 原子写一直失败；
2. `@($list)` 对 `List[object]` 在 PS 5.1 下抛错 → 隔离日志 `entries` 恒为空；
3. `New-Item -Force` 在父路径是文件时**静默成功**却不建目录；
4. `inspect` 状态机复用 `$status` 初值 → 全部条目误判 BLOCKED；
5. PSCustomObject 直接赋新属性无效 → `restore_result` 丢失。

---

## 6. 维护计划（P4，待授权）

- 计划 ID：`plan-20261118-055159-7a9e4dc1`
- 计划哈希：`8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3`
- 条目：共 3 项，可执行候选 3 项
- 计划文件：`manifests/plan-20261118-055159-7a9e4dc1.json`
- 审批模板：`manifests/approval-template-20261118-055159.json`
- 人读版：`reports/plan-20261118-055159-7a9e4dc1.md`

**当前状态：0 项被选中，未执行任何移动。**
干跑（`quarantine.ps1` 不带 `-Execute`）已执行：未创建隔离目录、未写日志、未改动任何文件。

### 授权方式

编辑审批模板，只填你确认过的 id：

```json
{
  "plan_sha256": "8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3",
  "decision": "APPROVE",
  "approved_ids": ["cwc-0003"],
  "approved_by": "你的标识",
  "approved_at": "2026-11-18T06:00:00Z"
}
```

然后执行：

```powershell
.\scripts\quarantine.ps1 -Plan ".\manifests\plan-20261118-055159-7a9e4dc1.json" `
  -Approval ".\manifests\approval-<你的文件>.json" -Execute
```

未填写的 id 不会执行；改动计划或哈希会得到 `2（拒绝）`。

---

## 7. 如实说明（未覆盖与不确定项）

1. **`%APPDATA%\Claude`（约 455 MB）未处理**：含 Electron 登录态、缓存、MCP 配置。
   若计划重装，保留它可保住登录与配置；若要彻底清除，需要你单独决定（本 Skill 不做）。
2. **`D:\Claude Setup*.exe` 未处理**：用户文件，不在白名单内，属范围外。
3. **"已卸载"是推断**：依据是无卸载注册项 / 无 MSIX / 无进程服务任务 / 无安装目录；
   不排除残留注册项被其他工具提前清掉。因此不宣称"官方确认已卸载"。
4. **不处理服务 / 计划任务 / 注册表**：本机未发现 Claude 相关项，且设计上就不处理。
5. **P5–P7 未执行**：按任务书要求停在授权门前。
6. **不使用"新账号注册成功"作为验收指标**（任务书明确禁止）。

---

## 8. 证据文件

| 文件 | 内容 |
|------|------|
| `reports/baseline-20261118-055151.json` | 环境基线（OS/PS/权限/受保护资源/Skill 指纹） |
| `reports/inspection-20261118-055151.json` | 只读检查报告（全部条目与证据） |
| `reports/test-report-20261118-055129.txt` | 36 项安全门禁测试输出 |
| `reports/verify-20261118-055200.json` | 维护前基线核对（判定 **PASS**） |
| `manifests/plan-20261118-055159-7a9e4dc1.json` | 维护计划 + `plan_sha256` |
| `manifests/plan-20261118-055159-7a9e4dc1.json.sha256` | 计划文件哈希 |
| `manifests/approval-template-20261118-055159.json` | 审批模板（空） |
| `reports/plan-20261118-055159-7a9e4dc1.md` | 人读版计划 |
| `docs/reference-audit.md` | 参考仓库独立审计 |
| `SECURITY.md` / `SKILL.md` / `README.md` / `CHANGELOG.md` | 交付文档 |

本轮**未产生**操作日志与隔离清单，因为未执行任何维护操作。
