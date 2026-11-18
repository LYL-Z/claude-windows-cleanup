# Claude Windows Cleanup — V1.1

Claude Desktop 正常卸载后的**最小化、可审计、可恢复**维护，外加对 Claude Code / 浏览器中
Claude 相关本地数据的**只读隐私评估**。

默认只读；只隔离不删除；真实操作需要「计划哈希 + 配置绑定 + 一次性口令」三重授权。

> 不处理系统清理、注册表、服务、环境变量、浏览器数据、开发工具或设备指纹。
> 只处理 6 个明确登记、且经证据确认属于 Claude Desktop 的路径。

## 它做什么

| 能力 | 脚本 |
|------|------|
| 环境基线（OS/PS/权限/受保护资源/源码指纹） | `scripts/preflight.ps1` |
| Claude Desktop 只读检查（VERIFIED/UNKNOWN/BLOCKED/PROTECTED） | `scripts/inspect.ps1` |
| 只读隐私评估（Claude Code / 浏览器 / 扩展，只看元数据） | `scripts/privacy-audit.ps1` |
| 生成计划 + 审批模板 + 一次性口令 | `scripts/plan.ps1` |
| 独立校验（计划/审批/配置/实时状态） | `scripts/validate-plan.ps1` |
| 同卷可恢复隔离（唯一写操作） | `scripts/quarantine.ps1` |
| 维护后验证 | `scripts/verify.ps1` |
| 原样恢复 / 崩溃对账 | `scripts/restore.ps1` |

## 它不做什么

- 不删除任何文件（唯一写操作是 `Move-Item`）
- 不 `takeown`、不改 ACL、不自动提权（默认非管理员）
- 不写注册表 / 环境变量，不动服务与计划任务
- 不联网、不上传、不读文件内容
- 不碰 `.claude`、`%APPDATA%\Claude`、浏览器数据、Git/SSH、Obsidian、Cursor/Codex/WorkBuddy/Trae、
  DeepSeek Harness、Clawd、个人文档

## 快速开始

```powershell
cd C:\path\to\claude-windows-cleanup

# 1) 只读
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\inspect.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\privacy-audit.ps1   # 可选

# 2) 计划（会打印一次性口令，注意别丢）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\plan.ps1 `
  -InspectionPath .\reports\inspection-<ts>.json

# 3) 干跑（零写入）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\quarantine.ps1 `
  -Plan .\manifests\plan-<id>.json

# 4) 填写审批后执行（需用户本人）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\quarantine.ps1 `
  -Plan .\manifests\plan-<id>.json `
  -Approval .\manifests\approval-<ts>.json -Execute

# 5) 验证 / 回滚
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1 `
  -Baseline .\reports\baseline-<ts>.json -InspectionPath .\reports\inspection-<ts>.json `
  -Journal .\manifests\journal-<id>.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\restore.ps1 `
  -Journal .\manifests\journal-<id>.json -Execute
```

## 目录

```text
claude-windows-cleanup/
├── SKILL.md                  Agent 执行手册（V1.1）
├── README.md                 本文件
├── SECURITY.md               安全边界、保证与非保证
├── CHANGELOG.md
├── config/
│   ├── scope.json            白名单 / 限额 / 隐私评估目标 / 执行策略
│   └── protected-resources.json  57 条红线 + 23 条模式
├── scripts/
│   ├── lib/Core.ps1          路径守卫 / 指纹 / 原子写 / 锁 / 脱敏 / 计划哈希
│   ├── lib/Plan.ps1          完整性 / 配置绑定 / 口令 / 实时复核
│   ├── preflight.ps1
│   ├── inspect.ps1
│   ├── privacy-audit.ps1     只读隐私评估（V1.1）
│   ├── plan.ps1
│   ├── validate-plan.ps1
│   ├── quarantine.ps1        唯一写操作
│   ├── verify.ps1
│   └── restore.ps1           含 -Reconcile 崩溃对账
├── tests/run-tests.ps1       52 项安全门禁（无 Pester 依赖）
├── manifests/                计划 / 审批 / 隔离日志
├── reports/                  基线 / 检查 / 隐私 / 验证 / 审计
└── docs/
    ├── reference-audit.md    参考仓库独立审计
    └── r1-audit-v1.1.md      第二轮独立复审
```

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

**52 项**，全部在 `%TEMP%` 沙盒、普通用户权限运行。覆盖：越界/不可读/重解析点/相似名称/穿越、
计划与配置绑定、口令、并发、日志失败回滚、崩溃对账、恢复占用/篡改/重试、报告脱敏、
探测失败降级、只读零写入。最近结果见 `reports/test-report-v11-*.txt`。

## 判定

| 判定 | 含义 |
|------|------|
| `PASS` | 检查/执行/验证全部符合预期 |
| `PARTIAL` | 存在 UNKNOWN，或审批真实性只能部分保证 |
| `FAIL` | 存在 FAIL（如配置漂移、受保护资源缺失） |
| `BLOCKED` | 等待用户授权，未执行 |
