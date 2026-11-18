# CHANGELOG

## 1.1.1 — 2026-11-18（发布治理 / 隐私整改）

无功能行为变更；只做公开仓库的发布规范化。

### 变更

- **移除**已公开的真实运行数据：`reports/baseline-*`、`inspection-*`、`privacy-*`、`verify-*`、
  `plan-*.md`、`test-report-*`、`audit.jsonl`、`P4-acceptance.md`、`R2/R3/R5/R6` 验收报告。
- **新增** `examples/synthetic-*`：全部人工构造并标注 `"_synthetic": true`，替代真实报告作为示例。
- **新增** `tools/Test-PublishSet.ps1` + `publish-allowlist.txt`：提交前校验"不在白名单/含真实路径/含凭据特征"。
- **收紧** `.gitignore`：运行产物默认不入库，白名单显式放行。
- **新增** `LICENSE`（MIT 候选，待所有者确认）、`CONTRIBUTING.md`。
- **重写** README 的状态分级：开发完成 / 自动化测试 / 独立复审 / 实机验收 / 已知限制分开表述，
  移除"绝对安全""零风险"类不可证明措辞。
- **新增** SECURITY 第 7 节：公开仓库数据卫生、Git 历史说明、依赖与供应链。

### 已知问题

- 初始提交 `8f78da2` 仍含旧的真实运行报告；清除需要重写历史或重建仓库，**等待所有者授权**。
- PowerShell 7 兼容性仍未验证（维护者环境未安装）。
## 1.1.0 — 2026-11-18（第二轮独立复审）

### 新增

- `scripts/privacy-audit.ps1`：Claude Code / 浏览器 / IDE 的只读隐私评估（只看元数据：路径、大小、
  文件数、修改时间、敏感文件名是否存在；不读内容、不输出凭据）。
- `scripts/lib/Core.ps1`：`Hide-CwcSensitive`（按键名+值特征脱敏）、`Enter-CwcLock`/`Exit-CwcLock`
  （并发控制）、`Test-CwcQuarantineDir`（隔离目录及祖先重解析点检查）、
  `Invoke-CwcMoveWithJournal`（移动+落盘原子化，失败自动搬回）、`Get-CwcConfigBinding`。
- `plan.ps1`：配置/保护清单/源码指纹三重绑定 + 一次性口令（计划只存 SHA-256，口令只打印一次）。
- `restore.ps1 -Reconcile`：按 `planned_dest` 对账"崩溃时已移动但日志停在 planned"的条目；
  恢复失败不再改写状态，可重试。
- `tests/run-tests.ps1` 扩展到 **52 项**（新增并发、日志失败、崩溃对账、配置绑定、口令、
  只读零写入、脱敏、探测失败、恢复重试等）。

### 修复（R1 复审）

- HIGH：移动成功但日志写失败 → 悬空。现在自动搬回，搬不回写应急记录并以 15 退出。
- HIGH：崩溃窗口不可恢复 → `planned_dest` + `-Reconcile`。
- HIGH：无并发控制 → 独占锁。
- HIGH：配置被改宽后旧计划仍有效 → 三重哈希绑定；**缺失即拒绝**（不再 SKIP）。
- MEDIUM：审批可被读计划者伪造 → 一次性口令（残余风险如实标注 PARTIAL）。
- MEDIUM：隔离目录可被换成联接点 → 根与祖先逐次检查。
- MEDIUM：验证与移动之间的 TOCTOU → 移动前第三次复核 + 移动后指纹（残余窗口标注 UNKNOWN）。
- MEDIUM：探测失败被当成"未安装" → `install_state=UNKNOWN`。
- MEDIUM：恢复失败改写状态导致无法重试 → 保留状态 + `restore_error`。
- MEDIUM：报告可能带出敏感值 → 全链脱敏。
- LOW：变量名大小写不敏感导致 `$saveJournal` 自递归 → 改名 `$journalWriter`。
- LOW：`-QuarantineRoot` 可指向受保护/范围内目录 → 显式拒绝。

### 变更

- 计划格式 `schema_version=2`；V1.0 计划与审批不再被接受（`plan_schema_outdated`）。
- 受保护资源从 24 条根 + 12 条模式扩展到 **57 条根 + 23 条模式 + 8 类扩展名**。
- 退出码新增 `15`（持久化失败）。
- `verify.ps1` 新增 `config_integrity` 与 `planned_but_moved` 检查。

### 已知残留

- 审批真实性：PARTIAL（本机无密码学用户身份）。
- 微秒级 TOCTOU：UNKNOWN（Windows 无按句柄移动 API）。
- 隐私评估只到元数据，不做内容级完整性。

## 1.0.0 — 2026-11-18（首轮 P0–P4）
