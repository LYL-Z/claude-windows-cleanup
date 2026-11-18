# claude-windows-cleanup

Claude Desktop 正常卸载后的**最小化、可审计、可恢复**维护工具，附 Claude 相关本地数据的**只读隐私评估**。

默认只读；只隔离不删除；真实操作需要「计划哈希 + 配置绑定 + 一次性口令」三重授权。

> 本项目**不**提供账号封禁规避、设备指纹修改、平台关联识别规避，也不做全盘清理或注册表优化。
> 它只处理 6 个明确登记、且经证据确认属于 Claude Desktop 的路径。

---

## 状态（请按级别理解，不要合并成一句"通过"）

| 维度 | 状态 | 含义 |
|------|------|------|
| 开发完成 | ✅ V1.1.1 | 代码、配置、文档齐备 |
| 自动化测试 | ✅ 52/52（PowerShell 5.1） | 全部在 `%TEMP%` 沙盒，普通用户权限 |
| PowerShell 7 | ⚠️ UNVERIFIED | 维护者机器未安装 pwsh 7，未实测 |
| 独立安全复审 | ⚠️ 作者自审 + 外部待复核 | `docs/r1-audit-v1.1.md` 为作者第二轮自审，不构成第三方结论 |
| 实机维护验收 | ⛔ 未进行 | 真实数据一条未动；等待逐项授权 |
| 开源许可 | ⏳ 待所有者确认 | 分支内附 MIT 候选（`LICENSE`），合并即视为确认 |

> 本项目不宣称"绝对安全""零风险""彻底清除"。它只承诺：**在声明边界内 fail-closed，越界即拒绝。**

---

## 它做什么

| 能力 | 脚本 |
|------|------|
| 环境基线（OS/PS/权限/受保护资源/源码指纹） | `scripts/preflight.ps1` |
| Claude Desktop 只读检查（VERIFIED/UNKNOWN/BLOCKED/PROTECTED） | `scripts/inspect.ps1` |
| 只读隐私评估（Claude Code / 浏览器 / IDE，仅元数据） | `scripts/privacy-audit.ps1` |
| 生成计划 + 审批模板 + 一次性口令 | `scripts/plan.ps1` |
| 独立校验（计划/审批/配置/实时状态） | `scripts/validate-plan.ps1` |
| 同卷可恢复隔离（唯一写操作） | `scripts/quarantine.ps1` |
| 维护后验证 | `scripts/verify.ps1` |
| 原样恢复 / 崩溃对账 | `scripts/restore.ps1` |

## 它不做什么

- 不删除任何文件（唯一写操作是 `Move-Item` 到同卷隔离区）
- 不 `takeown`、不改 ACL、不自动提权（默认非管理员）
- 不写注册表 / 环境变量，不动服务与计划任务
- 不联网、不上传、不读取文件内容
- 不碰 `.claude`、`%APPDATA%\Claude`、浏览器数据、Git/SSH、Obsidian、Cursor/Codex/WorkBuddy/Trae、
  DeepSeek Harness、个人文档

---

## 快速开始

```powershell
git clone https://github.com/LYL-Z/claude-windows-cleanup.git
cd claude-windows-cleanup

# 1) 只读
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\preflight.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\inspect.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\privacy-audit.ps1   # 可选

# 2) 计划（控制台会打印一次性口令，注意别丢）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\plan.ps1 `
  -InspectionPath .\reports\inspection-<ts>.json

# 3) 干跑（零写入）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\quarantine.ps1 `
  -Plan .\manifests\plan-<id>.json

# 4) 由用户本人填写审批（含口令）后执行
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

审批文件格式与退出码见 [`SKILL.md`](SKILL.md)。

---

## 目录

```text
claude-windows-cleanup/
├── SKILL.md                  Agent 执行手册
├── README.md                 本文件
├── SECURITY.md               安全边界、保证与非保证
├── CONTRIBUTING.md           贡献规则
├── CHANGELOG.md
├── LICENSE                   MIT 候选（待所有者确认）
├── config/                   scope.json（白名单/限额）、protected-resources.json（红线）
├── scripts/                  9 个入口 + 2 个库
├── tests/run-tests.ps1       52 项安全门禁
├── tools/Test-PublishSet.ps1 公开集合守卫
├── examples/                 SYNTHETIC 合成示例（非真实数据）
├── reports/                  仅保留通用矩阵；真实运行数据本地保存
├── manifests/                本地计划/日志；仓库中只有说明
└── docs/                     参考仓库审计、第二轮自审
```

---

## 数据卫生：仓库里没有你的电脑

真实运行产生的 `baseline-*`、`inspection-*`、`privacy-*`、`verify-*`、`plan-*`、
`test-report-*`、`audit.jsonl` 以及 `manifests/*.json` **全部被 `.gitignore` 排除**，
只留在本地。仓库里只有：

- 源码、配置、文档、测试；
- `examples/synthetic-*`：人工构造的示例，每份都带 `"_synthetic": true`；
- `reports/R4-test-matrix.md`：不含本机数据的通用测试矩阵。

提交前跑一次 `tools/Test-PublishSet.ps1`：不在白名单、或出现真实用户路径/凭据特征，都会失败。

---

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

52 项，覆盖：越界/不可读/重解析点/相似名称/穿越、计划与配置绑定、一次性口令、并发锁、
日志失败回滚、崩溃对账、恢复占用/篡改/重试、报告脱敏、探测失败降级、只读零写入。
结果摘要见 [`examples/synthetic-test-summary.md`](examples/synthetic-test-summary.md)（通用摘要，非本机日志）。

---

## 许可

分支内附 MIT 候选文件 `LICENSE`，**等待仓库所有者确认**；确认方式为合并该 PR。
若偏好 Apache-2.0，请在合并前提出。

---

## 免责声明

本项目是软件维护工具，不是安全产品，也不构成任何合规或账号状态建议。
本地清理不改变服务端记录；文件是否存在不代表账号是否有效。
使用者需自行确认操作对象与后果。
