# 维护计划（SYNTHETIC 示例）

> **本文件是人工构造的示例，不是真实计划。**
> 计划哈希为占位符，无法通过 `validate-plan.ps1` 校验——这是刻意的：
> 真实计划绑定本机路径，脱敏后哈希必然变化，发布"校验不过的计划"只会训练人忽略告警。

- 生成时间：`2026-01-01T00:00:00Z`（示例）
- 安装状态：`UNINSTALLED_CONFIRMED`
- 计划哈希：`<synthetic-not-verifiable>`
- 条目：共 2 项（VERIFIED 2 / UNKNOWN 0 / BLOCKED 0 / PROTECTED 0）

| ID | 状态 | 类型 | 大小 | 路径 | 说明 |
|----|------|------|------|------|------|
| cwc-0001 | VERIFIED | logs | 100.0 KB | `C:\Users\<user>\AppData\Local\Claude\logs` | 示例：日志目录 |
| cwc-0002 | VERIFIED | shortcut_dir | 0 B | `C:\Users\<user>\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Anthropic` | 示例：空目录 |

## 执行规则（与真实计划一致）

1. 只有 `VERIFIED` 且 `proposed_action=QUARANTINE` 的条目可以被批准。
2. 审批必须绑定计划哈希 + 一次性口令。
3. 计划生成后若 `config/` 或脚本被改动，旧计划立即失效。
4. 执行只做同卷隔离移动，不删除；`restore.ps1` 可原样搬回。
5. 执行前逐项复核指纹，任何变化都会中止整轮。

## 下一步（示例）

```powershell
.\scripts\quarantine.ps1 -Plan .\manifests\plan-<id>.json
.\scripts\quarantine.ps1 -Plan .\manifests\plan-<id>.json -Approval .\manifests\approval-<ts>.json -Execute
```
