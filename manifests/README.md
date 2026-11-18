# manifests/ — 为什么不发布机器绑定的计划文件

本目录在本地运行时存放三类文件：

| 文件 | 作用 |
|------|------|
| `plan-<id>.json` / `.sha256` | 维护计划 + 计划文件哈希 |
| `approval-template-<ts>.json` | 审批模板（默认空） |
| `journal-<id>.json` | 隔离运行日志（含 `planned_dest`，用于崩溃对账） |

**公开仓库里不包含这些 JSON。** 原因不是"没产物"，而是两条硬约束：

1. **含本机路径**：计划条目里是 `C:\Users\<user>\...` 的绝对路径，公开即泄露隐私。
2. **路径参与哈希**：`plan_sha256` 由 `id|kind|path|status|action|bytes|mtime|digest` 规范化文本计算；
   把路径脱敏成占位符，哈希必然改变，计划就**不再是同一份计划**。发布一个"哈希对不上"的计划，
   比不发布更糟——它会训练读者忽略完整性告警。

因此：计划与日志只在本地存在，仓库里保留它们的**人读版**与**哈希值**：

- `reports/plan-<id>.md` —— 计划摘要（逐项列出）
- 本地 `reports/` 下的验收记录（已被 `.gitignore` 排除）—— 计划 ID、`plan_sha256`、授权方式
- `examples/synthetic-plan.md` —— 公开示例（占位哈希，不可校验）

要复现同样的计划，在目标机器上重跑 `inspect.ps1` + `plan.ps1` 即可；内容不变时 `plan_sha256` 不变
（本仓库记录的是 `8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3`）。