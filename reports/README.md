# reports/ — 公开摘要 vs 本地运行数据

本目录在本地运行时会产生很多文件，但**只有两类会进入仓库**：

| 进入仓库 | 说明 |
|----------|------|
| `README.md`（本文件） | 规则说明 |
| `R4-test-matrix.md` | 通用测试矩阵（不含本机数据） |

其余全部属于**私人运行数据**，由 `.gitignore` 拦截，只留在本地：

| 模式 | 内容 | 为什么不能公开 |
|------|------|----------------|
| `baseline-*.json` | 环境基线 | 操作系统版本、用户名、绝对路径、受保护资源清单 |
| `inspection-*.json` | 只读检查报告 | 真实目录路径、大小、摘要 |
| `privacy-*.json/.md` | 隐私评估 | 真实软件数据规模、浏览器/Claude Code 路径 |
| `verify-*.json` | 维护后验证 | 真实指纹与时间戳 |
| `plan-*.md` | 维护计划 | 计划 ID、哈希、精确时间 |
| `test-report-*.txt` | 测试原始输出 | 本机路径与运行时间 |
| `audit.jsonl` | 操作审计日志 | 本机路径与操作序列 |

需要示例时请用 `examples/synthetic-*.json`（全部标注 `"_synthetic": true`）。
`tools/Test-PublishSet.ps1` 会在提交前检查：任何未在 `publish-allowlist.txt` 中的文件都会导致失败。
