---
name: claude-windows-cleanup
description: "Claude 专项软件维护与隐私安全管理 Skill（V1.1）。默认只读；只处理经可靠证据确认的普通安装残留；执行方式是同卷可恢复隔离（移动），从不删除；真实操作必须由用户逐项授权，并以「计划哈希 + 配置绑定 + 一次性口令」三重绑定。不处理系统目录、注册表、服务、环境变量、浏览器数据、Claude Code、开发工具或任何个人文件，不修改设备指纹与账号机制。"
---

# Claude Windows Cleanup — V1.1

范围极窄、默认只读、只隔离不删除的 Claude 专项维护 Skill。
V1.1 增加了：独立复审后的并发/事务/配置绑定加固、只读隐私评估、受保护资源扩容、52 项故障注入测试。

---

## 1. 什么时候用

- Claude Desktop 卸载后还留了日志 / 空目录，想**重装前**清干净；
- 想审计 Claude Code / 浏览器里 Claude 相关本地数据的**风险面**（只看元数据）；
- 想要一份可审计、逐项授权、可回滚的维护清单。

**不要**用于：系统清理、注册表/服务优化、驱动清理、"让 C 盘变大"、账号/指纹相关需求。

---

## 2. 硬边界（全部在代码里，不在提示词里）

| 边界 | 实现 |
|------|------|
| 默认拒绝：只有 6 个规范根内的路径才可能成为候选 | `Test-CwcItemSafety` |
| 不可读 ≠ 不存在 → `BLOCKED(unreadable)` | 同上 |
| 目标/祖先/子树任一重解析点 → 拒绝 | 同上 + `Get-TreeFingerprint` |
| 通配符 / UNC / 设备路径 / ADS / 相对路径 / 卷根 → 拒绝 | 同上 |
| 只隔离不删除；唯一写操作是 `Move-Item` | `quarantine.ps1` |
| 无 takeown / 无 ACL 变更 / 无提权 | 全仓无相关调用 |
| 不写注册表 / 环境变量 / 服务 / 计划任务 | 只读这些对象 |
| 不联网 | 全仓无网络调用 |
| 执行前逐项复核（类型/大小/摘要/可读性/重解析点） | `Test-LiveItemState` |
| 计划 ↔ 审批 ↔ 配置 ↔ 源码 四重绑定 | `Test-PlanIntegrity` |
| 同一时间只允许一个执行进程 | `Enter-CwcLock` |
| 移动成功但日志失败 → 自动搬回；搬不回 → 应急记录 + 退出 15 | `Invoke-CwcMoveWithJournal` |
| 崩溃后可按 `planned_dest` 对账恢复 | `restore.ps1 -Reconcile` |
| 报告/日志全局脱敏（token/cookie/secret/…） | `Hide-CwcSensitive` |
| 默认不预选 | `plan.ps1` 全部 `selected=false` |

---

## 3. 状态词汇

| 状态 | 含义 | 可执行 |
|------|------|--------|
| `VERIFIED` | 归属由规范根确定 + 已确认卸载 + 可读 + 无重解析点 | ✅ |
| `UNKNOWN` | 仍安装/运行、或关键探测失败、或无法确认 | ❌ |
| `BLOCKED` | 越界、不可读、重解析点、超限、路径非法 | ❌ |
| `PROTECTED` | 命中受保护资源（`.claude`、`%APPDATA%\Claude`、浏览器、个人目录…） | ❌ |
| `APPROVAL_REQUIRED` | 计划已生成，等待用户逐项授权 | — |

安装状态：`NOT_PRESENT` / `UNINSTALLED_CONFIRMED` / `INSTALLED` / `UNKNOWN`。
**关键探测失败一律 UNKNOWN**，不得当成"没装"。

---

## 4. 流程

```powershell
# 0) 环境基线（只读）
.\scripts\preflight.ps1

# 1) 专项只读检查（只读）
.\scripts\inspect.ps1

# 2) 隐私评估（只读元数据，可选）
.\scripts\privacy-audit.ps1

# 3) 生成计划（不执行；会打印一次性口令）
.\scripts\plan.ps1 -InspectionPath .\reports\inspection-<ts>.json

# 4) 干跑（零写入）
.\scripts\quarantine.ps1 -Plan .\manifests\plan-<id>.json

# —— 到此必须停止，等用户授权 ——

# 5) 用户填写审批（含口令）后执行
.\scripts\quarantine.ps1 -Plan .\manifests\plan-<id>.json `
  -Approval .\manifests\approval-<ts>.json -Execute

# 6) 验证 / 回滚
.\scripts\verify.ps1 -Baseline .\reports\baseline-<ts>.json `
  -InspectionPath .\reports\inspection-<ts>.json -Journal .\manifests\journal-<id>.json
.\scripts\restore.ps1 -Journal .\manifests\journal-<id>.json -Execute
.\scripts\restore.ps1 -Journal .\manifests\journal-<id>.json -Reconcile -Execute
```

### 审批文件（必须由用户本人填写）

```json
{
  "plan_sha256": "<计划里的哈希，不要改>",
  "decision": "APPROVE",
  "approved_ids": ["cwc-0003"],
  "approved_by": "<用户标识>",
  "approved_at": "<ISO 时间>",
  "confirmation_nonce": "<plan.ps1 终端里的一次性口令>"
}
```

- 口令只在 `plan.ps1` 控制台出现一次，**不落盘**；丢失就重新生成计划。
- 未填的 ID 不会执行；改动计划/哈希/配置/源码 → 全部拒绝。

---

## 5. 退出码

| 码 | 含义 |
|----|------|
| 0 | 成功 / 干跑完成 / 校验通过 |
| 1 | 一般错误（写盘失败等） |
| 2 | **拒绝**：未授权、口令错、计划/配置/源码被改、状态变化、跨卷、并发、隔离根不安全 |
| 3 | 输入缺失 |
| 4 | `verify` 存在 UNKNOWN |
| 5 | 执行/恢复中途失败（已停止，可重试） |
| 15 | 持久化失败（移动已回滚或需按应急记录对账） |

---

## 6. Agent 纪律

1. **不得**把开发/测试授权当成真实操作授权。
2. **不得**修改 `plan_sha256`、**不得**替用户填 `approved_ids` / `decision` / `confirmation_nonce`。
3. 展示计划必须逐项列出 `id / 状态 / 类型 / 大小 / 路径 / 原因`，并说明"默认未选中"。
4. 执行后必须报告：移动几项、隔离目录、日志路径、**没有删除任何东西**。
5. `PROTECTED` 项（尤其 `%APPDATA%\Claude`、`.claude`）必须明说"保留、未处理"。
6. 不得把"文件存在"说成"账号仍有效"，不得把"本地清理"说成"服务端记录已消除"。
7. 不做反检测/指纹伪造/账号关联规避。

---

## 7. 已知限制（如实）

- 只覆盖 `config/scope.json` 的 6 个规范根；D 盘安装包、下载目录等一律不处理。
- `%APPDATA%\Claude`（455 MB，含登录态/MCP 配置）与 `.claude`（Claude Code）**有意保护**。
- 隔离区占磁盘，需人工清理。
- TOCTOU：已做三次复核 + 移动后校验，但微秒级窗口无法在用户态消除（UNKNOWN）。
- 审批：口令提高门槛，但不能密码学证明"这是用户本人"（PARTIAL）。
- 隐私评估只到元数据，不做内容级完整性。
