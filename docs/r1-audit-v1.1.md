# R1 — 第二轮独立源码安全复审（V1.0 → V1.1）

- 复审对象：`C:\path\to\claude-windows-cleanup` V1.0（上一轮交付）
- 方式：逐行复读全部 PowerShell + 独立构造故障场景 + 沙盒复现
- 结论：**V1.0 存在 4 项 HIGH、6 项 MEDIUM、3 项 LOW**；本轮全部修复，另有 1 项残余风险如实保留
- 不采信上一轮"36/36 通过"作为结论：本轮新增的 16 项故障注入里，有 9 项在 V1.0 上会失败

---

## 1. HIGH

### R1-01 移动成功但日志写失败 → 条目悬空，无法对账

- **V1.0 证据**：`quarantine.ps1`（旧版）先 `Move-Item`，再在同一个 `try` 外调用 `Save-Journal`。
  日志写失败时脚本直接抛出，条目已离开原路径、日志却仍停在 `planned`。
- **复现**：把日志目录设为只读（或让 `File.Replace` 失败），执行单项隔离。
- **影响**：文件被搬走但没有可用的恢复记录；用户看到"执行失败"，磁盘状态却已改变。
- **V1.1 修复**：`Core.ps1:652 Invoke-CwcMoveWithJournal` —— 移动后立即落盘；落盘失败则**立即搬回**；
  搬不回则写 `%TEMP%\cwc-emergency-*.json` 并以 **15** 退出。`quarantine.ps1:225` 使用该封装。
- **验证**：C06（注入失败脚本块 → `Reverted=$true`，源文件回到原位）；B10/B12/B15 正常路径不受影响。

### R1-02 崩溃窗口不可恢复：`planned` 记录里没有目标路径

- **V1.0 证据**：旧日志条目只有 `original_path`，`moved_to` 在移动**之后**才写；
  进程若在 `Move-Item` 与 `Save-Journal` 之间被杀，恢复端无从知道东西去了哪里。
- **影响**：崩溃一次就可能永久失去对账能力；`restore.ps1` 只认 `moved` 状态。
- **V1.1 修复**：移动**之前**把 `planned_dest` 写进条目（`quarantine.ps1:164`）；
  `restore.ps1:34-43` 新增 `-Reconcile`：`planned + planned_dest 存在 + 原路径消失` → 视为可恢复，
  并在日志里标记 `reconciled=true`。
- **验证**：C13（手工构造崩溃日志 → `-Reconcile -Execute` 恢复成功，指纹一致）。

### R1-03 缺少并发控制：两个进程可同时操作同一计划

- **V1.0 证据**：全仓无锁。两个 `quarantine.ps1` 同时启动时，验证都通过，随后各移动一部分条目。
- **影响**：日志与移动顺序错乱；恢复端看到两份互不一致的 journal。
- **V1.1 修复**：`Core.ps1:579 Enter-CwcLock`（`CreateNew` 独占 + 持有进程存活检测 + 陈旧锁接管一次），
  `quarantine.ps1:68`、`restore.ps1` 均在入口取锁，`finally` 释放。
- **验证**：C03（预置活锁 → 退出码 2 并说明并发）。

### R1-04 配置被改宽后，旧计划仍然有效

- **V1.0 证据**：计划只绑定 `items` 哈希；`config/scope.json` 的 `allowed_item_roots` 不在绑定范围内。
  改了白名单（或换掉 `protected-resources.json`）后，旧计划仍可通过校验。
- **影响**：这是"改配置绕过边界"的直通车，也是供应链/误编辑的放大器。
- **V1.1 修复**：计划写入 `config_sha256` / `protection_sha256` / `skill_fingerprint`
  （`Core.ps1:688 Get-CwcConfigBinding`，`plan.ps1`），`Plan.ps1:30 Test-PlanIntegrity` 逐项比对；
  任一不符 → `config_binding_mismatch` / `skill_binding_mismatch` → 退出码 2。
- **验证**：C01（改 `config_sha256` → 拒绝）、`verify.ps1` 的 `config_integrity` 检查。

---

## 2. MEDIUM

### R1-05 审批可被任何能读计划的人伪造（残余 PARTIAL）

- **V1.0 证据**：审批 = `plan_sha256 + APPROVE + ids + 人名`。能读计划文件的人可以照抄哈希写出"合法"审批。
- **V1.1 缓解**：计划只存 `approval_nonce_sha256`，口令原文**只打印一次、不落盘**；
  审批必须给出原文（`Plan.ps1:100 Test-ApprovalBinding`）。这挡住了"只有文件访问权"的伪造路径。
- **仍然不成立的场景**：拥有完整控制台历史 / 进程内存 / 同一会话上下文的攻击者仍可伪造。
  **本机不存在密码学意义上的"用户身份"**，任何本地方案都无法证明"这是人点的头"。
- **结论**：标注 **PARTIAL**，不宣称"审批不可伪造"。

### R1-06 隔离目录可被替换成目录联接点

- **V1.0 证据**：只在启动时检查一次 `qRoot`，且 `runDir` 创建后不再复核。
- **影响**：本地写权限者可把 `runDir` 换成指向别处的 junction，让"隔离"写进非预期位置。
- **V1.1 修复**：`Core.ps1:627 Test-CwcQuarantineDir` 检查"存在 + 普通目录 + 自身与全部祖先非重解析点"；
  `quarantine.ps1:120`（创建后）与 `:205`（每次移动前）各查一次。
- **验证**：C04（隔离根是 junction → 2）、C05（祖先含 junction → 判定不安全）。

### R1-07 TOCTOU：验证与 `Move-Item` 之间仍有时间窗（残余 UNKNOWN）

- **V1.0 证据**：`Test-CwcItemSafety` 与 `Test-LiveItemState` 各算一次指纹，之后才移动。
- **V1.1 改善**：移动前**再次**执行 `Test-CwcItemSafety` + `Test-LiveItemState`（`quarantine.ps1:205-220`），
  并在移动后校验目标指纹；不匹配立即搬回。
- **残余风险**：Windows 没有"按句柄移动"的公开 API（`MoveFileEx` 按路径解析），
  两次调用之间的微秒级窗口无法在用户态彻底消除。**标注 UNKNOWN，不宣称零 TOCTOU。**
- **验证**：C09（目标在审批后被换成 junction → 执行前复核拒绝）。

### R1-08 关键探测失败被当成"未安装"

- **V1.0 证据**：`inspect.ps1` 收集了 `probes`（`ok=true/false`）却从未使用；
  注册表读失败 → 0 个卸载项 → 直接判 `UNINSTALLED_CONFIRMED`。
- **影响**：权限受限/注册表被锁时，会把"读不到"当成"已卸载"，与参考仓库 H-3 同型。
- **V1.1 修复**：`inspect.ps1:157-173`：任一关键探测失败 → `install_state=UNKNOWN`，
  所有条目降级 `UNKNOWN`、`actionable=0`。
- **验证**：C08（证据文件注入失败探测 → UNKNOWN、0 可执行项）。

### R1-09 恢复失败会改写条目状态，导致无法重试

- **V1.0 证据**：`restore.ps1` 失败分支执行 `$e.state = 'restore_failed'`，
  而可恢复集合只筛 `moved/moved_unverified` → 第二次恢复永远跳过该条目。
- **影响**：目标被占用/内容被篡改后，用户只能手工搬，工具失去重试能力。
- **V1.1 修复**：失败不再改写 `state`，改记 `restore_error`/`restore_failed_at`；
  可恢复集合纳入 `restore_failed`（`restore.ps1:33`）。
- **验证**：C11（占用 → 5 → 解除 → 重试成功）、C12（篡改 → 5 → 修复 → 重试成功）。

### R1-10 报告可能带出敏感值

- **V1.0 证据**：`inspect` 把 `uninstall_string` 等原样写入报告；计划/journal/verify 无脱敏层。
- **V1.1 修复**：`Core.ps1:521 Hide-CwcSensitive` —— 按键名（token/cookie/secret/…）与值特征
  （Bearer、`sk-`、`ghp_`、JWT、AKIA）双向屏蔽；`plan.ps1`/`inspect.ps1`/`verify.ps1`/`restore.ps1`/`quarantine.ps1` 全部经过该层。
- **验证**：C07（构造 token/cookie → `[REDACTED]`，普通字段不受影响）。

---

## 3. LOW

| ID | 问题 | 处理 |
|----|------|------|
| R1-11 | 变量名大小写不敏感：库函数参数 `$SaveJournal` 与脚本块 `$saveJournal` 同名 → 自我递归，表现为"日志永远写失败"（本轮开发中实测踩到） | 改名 `$journalWriter`；在 `CHANGELOG` 记录为 PS 陷阱 |
| R1-12 | PS 5.1 的 `Remove-Item` 对目录联接点会抛 `NullReferenceException`（测试清理时实测） | 测试改用 `[IO.Directory]::Delete(path,$false)`；产品只用 `Move-Item`，不受影响 |
| R1-13 | `-QuarantineRoot` 可指向受保护目录或允许清理范围内 | `quarantine.ps1:84-90` 显式拒绝（范围内/受保护目录） |

---

## 4. V1.0 中复核为仍然成立的部分（无回归）

- 默认拒绝 + 最长前缀规则（A01/A02/A03）。
- 不可读 → BLOCKED，不当作不存在（A14）。
- 目标/祖先/子树重解析点拒绝（A13/C09）。
- 通配符/UNC/相对路径/卷根/穿越拒绝（A08-A12）。
- 计划 items 哈希 + sidecar + 审批绑定（B03/B05/B17）。
- DryRun 零写入（B08/C10）、未授权拒绝（B09）、失败即停（B15）。
- 不做 takeown/ACL/注册表/环境变量/网络（代码检索 + 全流程非管理员 C14）。

---

## 5. 残余风险清单（不修，如实交付）

| 风险 | 级别 | 说明 |
|------|------|------|
| 无文件 ID 级 TOCTOU 防护 | UNKNOWN | 用户态无按句柄移动 API；只能缩小窗口 |
| 审批不可密码学证明 | PARTIAL | 本机无用户身份根；口令只提高门槛 |
| 隔离区会占磁盘 | 已知 | 需人工清理；工具不自动删 |
| 测试通过 ≠ 无缺陷 | 已知 | 52 项覆盖已知故障面，不构成形式化证明 |
| 保护范围只到"存在性" | 已知 | 34 项受保护资源只核验存在/非重解析，未做内容完整性（内容级校验会读取用户数据，与红线冲突） |

---

## 6. 复现方式

```powershell
cd C:\path\to\claude-windows-cleanup
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

全部在 `%TEMP%` 沙盒内；C 组 16 项即本轮新增的故障注入。结果：**52 passed / 0 failed**。
