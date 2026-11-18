# Contributing

感谢关注。这个项目**故意做得很窄**：只做 Claude Desktop 普通卸载残留的
"只隔离、不删除"维护，以及 Claude 相关本地数据的只读隐私评估。

提交前请先接受三条边界，它们不是建议，是硬约束：

1. **不扩大清理范围**：不新增"全盘清理""系统优化""注册表清理""指纹/账号"类功能。
2. **不引入危险原语**：不使用 `takeown`、`icacls`、ACL 修改、自动提权、注册表写入、
   服务/计划任务操作、联网请求。
3. **不放宽默认拒绝**：任何新路径必须走 `config/scope.json` 的规范根，且保持 fail-closed。

---

## 开发环境

- Windows 10/11
- Windows PowerShell 5.1（运行时基线）；PowerShell 7 尚未验证，欢迎补充证据
- 无需 Pester、无需联网、无需管理员

## 本地验证

```powershell
# 1) 52 项安全门禁（全部在 %TEMP% 沙盒）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1

# 2) 公开集合守卫（不能把真实运行数据带进仓库）
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PublishSet.ps1
```

两条都必须通过才能提 PR。

## 不要提交的东西

| 路径 | 原因 |
|------|------|
| `reports/baseline-*` `inspection-*` `privacy-*` `verify-*` `plan-*` `test-report-*` `audit.jsonl` | 含真实机器路径/版本/时间/哈希 |
| `manifests/*.json` | 计划与审批绑定本机路径，公开即泄露 |
| `quarantine/` | 迁移中的真实文件 |

已在 `.gitignore` 拦截；`Test-PublishSet.ps1` 会再查一遍。
需要示例就放 `examples/synthetic-*`，并带 `"_synthetic": true`。

## 代码约定

- 所有脚本必须能被 dot-source（`function Main` + `[ref]$ExitCode` + 执行守卫）。
- 破坏性入口必须 fail-closed：不确定就停，不要"尽量继续"。
- 任何写盘 JSON 先过 `Hide-CwcSensitive`。
- 新增行为必须有对应用例；**不要为了数量写无效断言**。
- 中文注释可以，但 `.ps1` 必须是 UTF-8 with BOM（PS 5.1 的 ANSI 解码陷阱）。

## 提交与 PR

- 分支命名：`fix/<topic>`、`feat/<topic>`、`release/<version>`。
- 提交信息用英文祈使句，正文写"为什么"而不是"改了什么"。
- PR 描述里请附：变更文件、隐私复查、测试结果、已知限制。
- **不要**在 PR 里合并自己的改动，也不要 force-push 已公开的历史。

## 安全披露

发现安全问题请开 Issue 描述影响面，不要附带真实凭据、Cookie、Token 或完整本机路径。
本项目的已知限制见 `SECURITY.md` 第 3、6 节——请先确认不是已声明的边界。

## 许可

合并进本仓库即表示同意以 MIT License 发布（见 `LICENSE`）。
