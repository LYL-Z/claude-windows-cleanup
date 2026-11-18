# examples/ — 全部为 SYNTHETIC 合成数据

本目录下的每一份 `synthetic-*` 文件都是**人工构造的示例**，用于展示输出结构，不是真实电脑的运行结果。

| 文件 | 模拟的对象 |
|------|-----------|
| `synthetic-baseline.json` | `preflight.ps1` 的环境基线输出 |
| `synthetic-inspection.json` | `inspect.ps1` 的只读检查输出 |
| `synthetic-privacy.json` | `privacy-audit.ps1` 的隐私评估输出 |
| `synthetic-plan.md` | `plan.ps1` 生成的人读版计划 |
| `synthetic-test-summary.md` | 测试结果摘要（真实运行结果的通用摘要，非本机数据） |

约束：

- 主机名、用户名、路径全部使用 `<EXAMPLE-*>` 或 `C:\Users\<user>` 占位；
- 不包含任何真实文件大小、系统版本、时间戳、哈希或指纹；
- 文件内带 `"_synthetic": true` 与 `"_notice"` 字段，防止被误当作真实报告引用。

真实运行数据（基线、检查、隐私、验证、计划、隔离日志）由 `.gitignore` 拦截，**不会**进入本仓库。
