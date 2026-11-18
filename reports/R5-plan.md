# R5 — 维护计划复核与重生成（V1.1）

- 复核时间：2026-11-18
- 结论：**3 项普通卸载残留仍在，状态未变；已按 V1.1 格式重新生成计划；未批准、未执行。**

---

## 1. 三项残留是否仍然存在

重新执行 `inspect.ps1`（只读），结果与上一轮一致：

| ID | 状态 | 类型 | 大小 | 路径 | 与上轮相比 |
|----|------|------|------|------|-----------|
| cwc-0001 | VERIFIED | logs | 372.0 KB | `%LOCALAPPDATA%\Claude\logs` | 路径/大小一致 |
| cwc-0002 | VERIFIED | logs | 368.4 KB | `%ProgramData%\Claude\Logs` | 路径/大小一致 |
| cwc-0003 | VERIFIED | shortcut_dir | 0 B | `…\Start Menu\Programs\Anthropic` | 路径一致（空目录） |

**证据**：本轮计划哈希 `8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3`
与上一轮 **完全相同**。计划哈希只对"路径/状态/大小/时间/摘要"取值，
哈希相同即说明三项的内容指纹未变——这比"看起来一样"更强。

安装状态仍为 `UNINSTALLED_CONFIRMED`：无卸载注册项、无 MSIX、无进程/服务/任务、无安装目录。

---

## 2. 旧计划是否失效

- 上一轮 V1.0 的计划文件已在测试清理流程中被移除，无法再复验其失效。
- V1.1 用**格式**保证旧计划不可能被误用：
  - `schema_version` 必须 ≥ 2，否则 `plan_schema_outdated`；
  - `config_sha256` / `protection_sha256` / `skill_fingerprint` 必须存在且匹配，
    缺失即 `*_missing`，不再 SKIP；
  - `approval_nonce_sha256` 必须存在。
- **实测**：把当前计划降级成 V1.0 形态（schema=1、去掉绑定与口令）后执行完整性校验：

```text
[FAIL] plan_schema  schema=1，V1.1 要求 >= 2
[FAIL] config_binding  计划未记录该绑定
exit=2
```

---

## 3. 新计划

| 项 | 值 |
|----|-----|
| 计划 ID | `plan-20261118-065616-b6c5ef1f` |
| 计划哈希 | `8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3` |
| 条目 | 3（VERIFIED 3 / 可执行候选 3 / 默认选中 0） |
| 计划文件 | `manifests/plan-20261118-065616-b6c5ef1f.json` |
| 审批模板 | `manifests/approval-template-20261118-061919.json` |
| 口令 | 已在 `plan.ps1` 控制台输出，**未写入任何文件**，本报告不复制 |

审批模板当前状态：

```json
{
  "schema_version": 2,
  "plan_sha256": "8af7824c…f9a1d3",
  "decision": "",
  "approved_ids": [],
  "approved_by": "",
  "approved_at": "",
  "confirmation_nonce": ""
}
```

---

## 4. 本轮做了什么 / 没做什么

**做了**：只读重检、计划重生成、干跑（`quarantine.ps1` 不带 `-Execute`）。
干跑实测：未创建隔离目录、未写日志、未改动任何文件（`%LOCALAPPDATA%\ClaudeCleanup` 仍不存在）。

**没做**：

- 未填写 `decision`，未填写 `approved_ids`，未生成任何审批文件；
- 未执行隔离、未删除、未移动任何真实数据；
- 未修改注册表、服务、ACL、环境变量、系统配置。

---

## 5. 如果要授权

1. 在终端查看 `plan.ps1` 打印的**一次性口令**（本报告不保存它）。
2. 编辑 `manifests/approval-template-20261118-061919.json`：

```json
{
  "plan_sha256": "8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3",
  "decision": "APPROVE",
  "approved_ids": ["cwc-0003"],
  "approved_by": "<你的标识>",
  "approved_at": "<ISO 时间>",
  "confirmation_nonce": "<终端里的一次性口令>"
}
```

3. 执行（建议先跑一次干跑看清动作）：

```powershell
.\scripts\quarantine.ps1 -Plan .\manifests\plan-20261118-065616-b6c5ef1f.json
.\scripts\quarantine.ps1 -Plan .\manifests\plan-20261118-065616-b6c5ef1f.json `
  -Approval .\manifests\approval-<你的文件>.json -Execute
```

只填 `cwc-0003` 就只动那个空目录；未填的不会执行。
