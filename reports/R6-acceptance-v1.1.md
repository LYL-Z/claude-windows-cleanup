# R6 — V1.1 最终验收报告

- 交付时间：2026-11-18
- 版本：`1.1.0`
- Skill 源码指纹：`3a268d04036a2be6fc2ef2256431599a4fb819a7b4868fd572df1661dabbef51`
- 机器：Win11 build 26300 / PowerShell 5.1 / **非管理员**

---

## 1. 分项结论

| 任务 | 状态 | 依据 |
|------|------|------|
| R1 独立源码复审 | **PASS** | 4 HIGH / 6 MEDIUM / 3 LOW 全部修复；1 项残余如实保留（`docs/r1-audit-v1.1.md`） |
| R2 隐私安全评估 | **PASS** | 13 目标只读评估；1 HIGH + 6 MEDIUM 发现，全部保留不处理（`reports/R2-privacy-assessment.md`） |
| R3 受保护资源 | **PASS** | 57 条根，本机 34 存在 / 0 重解析；新增 Claude Code 子路径与项目资产（`reports/R3-protected-verification.md`） |
| R4 自动化测试 | **PASS** | **52 passed / 0 failed**，覆盖任务书 15 类故障场景（`reports/R4-test-matrix.md`） |
| R5 计划复核 | **PASS** | 3 项残留未变（计划哈希与上轮一致）；新计划已生成；**0 项批准**（`reports/R5-plan.md`） |
| R6 交付 | **PASS** | 本报告 + 全部证据 |
| **实际维护（P5）** | **BLOCKED** | 等待用户逐项授权 + 一次性口令；本轮未移动/删除任何真实数据 |
| 审批真实性 | **PARTIAL** | 口令提高门槛，但本机不存在密码学用户身份 |
| TOCTOU | **UNKNOWN** | 三次复核 + 移动后校验已做；微秒级窗口无法在用户态消除 |

---

## 2. V1.0 → V1.1 修了什么

| 编号 | 级别 | V1.0 缺陷 | V1.1 修复 | 验证 |
|------|------|-----------|-----------|------|
| R1-01 | HIGH | 移动成功、日志失败 → 条目悬空 | 移动+落盘原子化，失败自动搬回；搬不回写应急记录并退出 15 | C06 |
| R1-02 | HIGH | 崩溃窗口无法对账 | 先写 `planned_dest`；`restore -Reconcile` 可恢复 | C13 |
| R1-03 | HIGH | 无并发控制 | 独占锁 + 陈旧锁接管 + `finally` 释放 | C03 |
| R1-04 | HIGH | 改宽配置后旧计划仍有效 | 计划绑定 config/protection/skill 三重哈希，缺失即拒绝 | C01、verify |
| R1-05 | MEDIUM | 审批可被读计划者伪造 | 一次性口令（计划只存 SHA-256） | B07b/B07c |
| R1-06 | MEDIUM | 隔离目录可被换成联接点 | 根与全部祖先逐次检查 | C04/C05 |
| R1-07 | MEDIUM | 验证与移动之间的窗口 | 移动前第三次复核 + 移动后指纹 | C09 |
| R1-08 | MEDIUM | 探测失败当成"未安装" | 任一关键探测失败 → `UNKNOWN`/0 可执行 | C08 |
| R1-09 | MEDIUM | 恢复失败改写状态 → 无法重试 | 保留状态，记 `restore_error`，可重试 | C11/C12 |
| R1-10 | MEDIUM | 报告可能泄露敏感值 | 全局 `Hide-CwcSensitive` 脱敏 | C07 |
| R1-11 | LOW | 变量名大小写碰撞导致自递归 | 改名 `$journalWriter` | 全量回归 |
| R1-12 | LOW | PS 5.1 `Remove-Item` 删 junction 抛 NRE | 测试改用 `[IO.Directory]::Delete` | A13/C04/C05 |
| R1-13 | LOW | `-QuarantineRoot` 可指向受保护/范围内目录 | 显式拒绝 | 代码审查 |

另：V1.0 的 4 项 HIGH（不可读判空、无路径边界、服务误判、闸门只在文档）在 V1.0 已修复，本轮回归确认无退化（A03/A14、B10、C14）。

---

## 3. R2 隐私评估要点

| 事实 | 数值 |
|------|------|
| 检查目标 | 13 |
| 存在 | 11（含 `.claude` 29 MB、Desktop 用户数据 455 MB、Chrome 5.28 GB） |
| 不存在 | 2（`.credentials.json`、`%APPDATA%\Anthropic`） |
| 风险发现 | 7（1 HIGH 明文会话记录 + 6 MEDIUM） |
| 读取内容 | **否**（只统计元数据） |
| 处理动作 | **无**（全部保留） |

明确不主张：本地文件存在 ≠ 账号有效；本地清理 ≠ 服务端记录消除；不提供指纹/关联规避。

---

## 4. 受保护资源

- 57 条根（V1.0 为 24+12 模式），本机 34 存在、23 不存在、**0 重解析点**。
- 新增：Claude Code 全部子目录与 `.credentials.json`、`CLAUDE.md`/`CLAUDE.local.md`/`.mcp.json`/`settings.local.json` 模式、
  浏览器凭据文件名模式、IDE/代理目录。
- 局限：只核验存在性，不做内容完整性与备份。

---

## 5. 本轮计划（未批准）

| 项 | 值 |
|----|-----|
| 计划 ID | `plan-20261118-065616-b6c5ef1f` |
| 计划哈希 | `8af7824cf4ef3634f26ce15ac9bbf2621c2483e6368ea2d0fc8ce6b454f9a1d3` |
| 条目 | 3（cwc-0001/0002 日志、cwc-0003 空开始菜单目录） |
| 默认选中 | **0** |
| 审批 | **未生成** |
| 干跑 | 已执行：零文件修改、零日志、未建隔离目录 |

---

## 6. 残余风险（不修，如实交付）

| 风险 | 判定 | 说明 |
|------|------|------|
| 审批不可密码学证明 | PARTIAL | 本机无用户身份根；口令只挡住"仅有文件访问权"的伪造 |
| 微秒级 TOCTOU | UNKNOWN | Windows 无按句柄移动 API；已用三次复核 + 移动后校验缩小窗口 |
| 隔离区占磁盘 | 已知 | 默认 `%LOCALAPPDATA%\ClaudeCleanup`，不自动清理 |
| 测试通过 ≠ 无缺陷 | 已知 | 52 项覆盖已知故障面，不是形式化证明 |
| 保护范围只到存在性 | 已知 | 内容级校验需读取用户数据，与红线冲突 |
| 用户可能批准错误项 | 已知 | 工具保证"批准项必须可执行"，不替人判断 |

---

## 7. 证据清单

| 文件 | 内容 |
|------|------|
| `docs/r1-audit-v1.1.md` | 第二轮独立复审（缺陷/复现/影响/修复） |
| `reports/R2-privacy-assessment.md` | 隐私评估结论与边界 |
| `reports/privacy-20261118-061653.json` / `.md` | 隐私评估原始报告 |
| `reports/R3-protected-verification.md` | 受保护资源核验 |
| `reports/R4-test-matrix.md` | 52 项矩阵与 15 场景映射 |
| `reports/test-report-v11-20261118-061848.txt` | 测试原始输出（52/0） |
| `reports/R5-plan.md` | 计划复核与授权方式 |
| `reports/baseline-20261118-061848.json` | 维护前基线 |
| `reports/inspection-20261118-061848.json` | 只读检查原始报告 |
| `reports/verify-20261118-061925.json` | 维护前核对（PASS） |
| `manifests/plan-20261118-065616-b6c5ef1f.json` + `.sha256` | 计划与文件哈希 |
| `manifests/approval-template-20261118-061919.json` | 审批模板（空） |
| `docs/reference-audit.md` | 参考仓库独立审计（第一轮） |

---

## 8. 最终判定

**V1.1 开发与测试：PASS。**
**真实维护：BLOCKED（APPROVAL_REQUIRED）。**

要进入 P5，需要你：

1. 在终端查看 `plan.ps1` 打印的一次性口令（本报告与任何文件都没有保存它）；
2. 在审批模板里填写 `decision=APPROVE`、`approved_ids`（只填你确认的）、`approved_by`、`approved_at`、`confirmation_nonce`；
3. 先干跑，再 `-Execute`。

在你完成上述步骤之前，本 Skill 不会移动任何真实数据。
