# 参考仓库独立审计：`boyingliu01/windows-residual-cleaner`

- 审计对象：`https://github.com/boyingliu01/windows-residual-cleaner`
- 提交：`93ab08e`（`master`，2026-11-18），`VERSION 1.4.14.1`，118 commits / 14 tags
- 规模：130 文件；产品+工具 PowerShell 8,538 行；17 个管线脚本；27 个测试文件 / 819 个 `It`
- 方式：完整只读阅读 + 在 `%TEMP%` 内做定向实证（未执行其清理脚本）
- 结论：**PARTIAL**（无恶意代码；4 HIGH / 8 MEDIUM / 8 LOW）

> 本文件是 `claude-windows-cleanup` 的设计依据：每一项缺陷都对应新 Skill 的一条硬边界。

---

## 1. 无恶意代码（已验证）

| 检查 | 结果 |
|------|------|
| 网络外联 | 产品脚本 0 处 `Invoke-WebRequest` / `Invoke-RestMethod` / `WebClient` / socket |
| 凭据访问 | 无 `Get-Credential` / `ConvertTo-SecureString`；不读 Cookie/Token/浏览器库 |
| 提权 | 无 `-Verb RunAs`、无 UAC 自提升、无服务/任务持久化 |
| 混淆 | 无 Base64 解码、无 `Invoke-Expression`、无隐藏字符 |
| 二进制 | 仓库无 exe/dll，无预编译产物 |

---

## 2. HIGH（4）

### H-1 不可读目录被判「空目录 + Safe」，随后被夺权强删（实测）

`references/scripts/scan-filesystem-residuals.ps1:262-267` 的 `catch` 把枚举失败写成
`fileCount=0 / size=0 / allSubdirsEmpty=$false`，随后 `:275-278` 的 `elseif` 命中，产出
`risk='safe'`。

实测（`%TEMP%` 构造）：目录含一个可读文件 + 一个拒绝遍历的子目录，扫描输出：

```json
{ "type": "empty_directory", "file_count": 0, "size_mb": 0,
  "risk": "safe", "reason": "Minimal residual (0 files, 0MB)" }
Test-Path => True
```

`clean-residuals.ps1:826` 的 `Test-Path` 为真 → `Remove-ItemRobust`（`:842`）tier-1 失败 →
tier-2 `takeown /r` + `icacls /grant Administrators:F /T`（`:140-157`）夺权后递归删除
**从未被读取过**的内容。

### H-2 删除层没有路径白名单，`final-report.json` 是唯一信任源（实测）

`clean-residuals.ps1` 全文无根目录约束；`Test-Whitelisted`（`:239-254`）只有两条正则。
DryRun 喂入系统路径后的实测输出：

```text
[DRY-RUN] Deleting path: C:\Windows\System32
[DRY-RUN] Deleting path: C:\Users
Cleanup summary: 3 succeeded, 0 failed, 0 skipped
```

去掉 `-DryRun` 就是同一路径上的 `takeown` + 递归删除。

### H-3 「读不到」与「不存在」不可区分 → `sc delete` 合法服务（实测）

`scan-residuals.ps1:116-117` 以 `Test-FilePath` 为假判定 ghost service 并直接 `risk='safe'`；
`Test-FilePath` 首跳是 `[System.IO.File]::Exists`。实测：

```text
File.Exists through denied traverse: False   # 文件真实存在，仅父目录不可遍历
```

后果：受限目录/离线卷上的在役服务被判 ghost → Phase 1 `sc stop` → `sc delete`（`:785-804, 904-923`）。

### H-4 安全闸门只存在于 `SKILL.md`，代码不强制；`-Mode A` 可批量删除

`SKILL.md:167-180` 声明三道 Gate、`:147` 要求强制 DryRun，但 `clean-residuals.ps1` 没有任何
"本轮之前做过 DryRun"的记录；`-Mode A` 直接取全部 safe 项（`:649`），`$willDelete` 仅要求
`$Mode -ne 'D'`（`:692`）；`confirm-cleanup.ps1:229-233` 交互模式默认预选全部 Safe 项。

---

## 3. MEDIUM（8）

| # | 缺陷 | 证据 |
|---|------|------|
| M-1 | `takeown`/`icacls` 的 ACL 变更不进日志、不可回滚；`icacls /T` 会穿透联接点（实测目标文件被追加 ACE） | `clean-residuals.ps1:140-157` |
| M-2 | 写回 Machine PATH 破坏 `REG_EXPAND_SZ`；备份的"原值"已被展开（实测：raw 691 字符含 `%SystemRoot%`，`.NET` 读到 681 字符且无 `%`） | `:445,750`；`rollback-exec.ps1:756` |
| M-3 | 文件/目录删除零备份；"每项备份"只对注册表成立 | `rollback-verdicts.ps1:25-33`；`README.md:9` |
| M-4 | `create-restore-point.ps1` 会主动 `Enable-ComputerRestore`（改变系统保护配置） | `:152-166` |
| M-5 | 文档与代码矛盾：PATH 标 Danger 实际 caution；"还原点必须存在"实际只告警 | `README.md:131,135`；`scan-residuals.ps1:169` |
| M-6 | 本地 UI 服务端无鉴权，Origin 白名单信任 `localhost:5173` 端口，`HOST` 可被环境变量改写，断连即杀清理进程 | `ui/server/security.cjs:54-63`；`index.cjs:25-26,33-38,404-406` |
| M-7 | 注册表整键删除无叶子/深度护栏，白名单仅 7 条正则 + 9 个服务名 | `clean-residuals.ps1:1101`；`whitelist.json` |
| M-8 | 扫描器不识别 reparse point，把 junction 当普通目录（删除端实测保留目标，但判定无意义） | `scan-filesystem-residuals.ps1:227` |

---

## 4. LOW（8）

| # | 缺陷 | 证据 |
|---|------|------|
| L-1 | 产品代码内置 `WRC_TEST_IS_ADMIN` 环境变量后门（仅绕过友好检查，不构成提权） | `clean-residuals.ps1:271-274` |
| L-2 | WQL 字符串拼接 `Name='$($item.name)'` | `:794` |
| L-3 | CI 用 `actions/*@v7` tag 而非 SHA；`Install-Module -SkipPublisherCheck` | `ci.yml:39,149,216,65-67` |
| L-4 | DryRun 仍写 `cleanup-log.json`，并把"将删除"计为 `succeeded` | 实测 |
| L-5 | `child.kill()` 不杀进程树；300s 超时会在删除中途杀 | `index.cjs:76,126` |
| L-6 | 占位链接 `github.com/your-repo/...`；`cors` 依赖已无引用 | `App.tsx:87`；`ui/package.json:18` |
| L-7 | `MachineGuid` 落盘到本地 journal（仅本地） | `rollback-journal.ps1:621` |
| L-8 | `SKILL.md` 指示 agent 隐瞒参数/文件名，降低可审计性 | `SKILL.md:298-311` |

---

## 5. 做得好的地方（新 Skill 借鉴）

1. **回滚内核**：journal 自证（`rollback-journal.ps1:403-607`）含哈希绑定、路径越界拒绝、
   `item_id` 重算比对、机器指纹校验；24 小时窗口且拒绝未来时间戳（`rollback-recovery.ps1:616-631`）。
2. **单点决策表**：`Get-RollbackVerdict` 把"能否恢复"收敛成一张表（`rollback-verdicts.ps1:132-247`）。
3. **失败即停**：持久化失败会中止后续破坏性操作，并区分 10–15 退出码。
4. **诚实语义**：Tier-4 改名不记为删除（`clean-residuals.ps1:208-213`）。
5. **工程纪律**：819 个断言、双引擎、PSSA 0 finding、80% 覆盖率门禁。

---

## 6. 对新 Skill 的直接影响

| 参考仓库缺陷 | `claude-windows-cleanup` 的对应设计 |
|--------------|--------------------------------------|
| H-1 不可读=空 | `Test-CwcItemSafety` 第 5 步：不可读 → `BLOCKED(unreadable)`，永不 `VERIFIED` |
| H-2 无路径边界 | 默认拒绝 + 6 个规范根 + 最长前缀规则 |
| H-3 服务误判 | 完全不处理服务/任务/注册表 |
| H-4 闸门只在文档 | 计划哈希 + 审批绑定 + 执行前复核，全部在代码 |
| M-1 夺权 | 无 `takeown`/`icacls`；隔离是改名 |
| M-3 无备份 | 不删除；隔离区保留原内容 |
| M-8 联接点 | 目标/祖先/子树任一重解析点即拒绝 |

---

## 7. 判定

**PARTIAL**：无恶意代码、无外联、无提权链，回滚设计优秀；但存在可在正常使用路径上
造成不可逆误删的 HIGH 缺陷（H-1/H-2/H-3）与只写在文档里的安全闸门（H-4）。
不适合无人值守或批量模式使用；仅可在 DryRun + 逐项人工复核下谨慎使用。
