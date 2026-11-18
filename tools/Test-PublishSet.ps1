# Test-PublishSet.ps1 — 公开集合守卫
# 校验"将要提交的文件"是否全部在白名单内、是否混入真实运行数据或真实用户路径。
# 只读；退出码 0=通过，1=违规。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PublishSet.ps1

[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.git'))) {
    Write-Error "不是 git 仓库：$RepoRoot"
    exit 3
}

$allowPath = Join-Path $RepoRoot 'publish-allowlist.txt'
if (-not (Test-Path -LiteralPath $allowPath)) {
    Write-Error "缺少白名单：$allowPath"
    exit 3
}

$allow = @(
    Get-Content -LiteralPath $allowPath -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $_.StartsWith('#') }
)

$tracked = @(& git -C $RepoRoot -c core.quotepath=false ls-files)
if ($LASTEXITCODE -ne 0) { Write-Error 'git ls-files 失败'; exit 3 }

$violations = @()
$privatePatterns = @(
    'reports/baseline-*', 'reports/inspection-*', 'reports/privacy-*',
    'reports/verify-*', 'reports/plan-*', 'reports/test-report-*',
    'reports/audit.jsonl', 'manifests/*.json', 'manifests/*.lock',
    'quarantine/*'
)

foreach ($f in $tracked) {
    $matched = $false
    foreach ($p in $allow) {
        if ($f -like $p) { $matched = $true; break }
    }
    if (-not $matched) { $violations += ('not_in_allowlist: ' + $f) }

    foreach ($pp in $privatePatterns) {
        if ($f -like $pp) { $violations += ('private_runtime_data: ' + $f) }
    }
}

# 扫描已跟踪文本：不允许出现真实用户目录（占位符 <user> 除外）
$textFiles = @($tracked | Where-Object { $_ -match '\.(md|json|ps1|txt|jsonl|yml|yaml|gitignore|gitattributes)$' -or $_ -eq '.gitignore' -or $_ -eq '.gitattributes' })
foreach ($f in $textFiles) {
    # 守卫脚本自身包含检测用正则，跳过自检
    if ($f -eq 'tools/Test-PublishSet.ps1') { continue }
    $full = Join-Path $RepoRoot $f
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    # JSON 里是双反斜杠；先归一化再检测，避免漏报
    $probe = $text.Replace('\\', '\')
    if ($probe -match 'C:\\Users\\(?!<user>)') {
        $violations += ('real_user_path: ' + $f)
    }
    if ($text -match '(?i)(ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16})') {
        $violations += ('credential_like_value: ' + $f)
    }
}

Write-Output ("tracked files : {0}" -f $tracked.Count)
Write-Output ("allowlist     : {0} 条" -f $allow.Count)

if ($violations.Count -gt 0) {
    Write-Output ''
    Write-Output '违规：'
    foreach ($v in $violations) { Write-Output ("  - {0}" -f $v) }
    Write-Output ''
    Write-Output '请把文件移出仓库，或显式加入 publish-allowlist.txt（并确认不含私人数据）。'
    exit 1
}

Write-Output 'PASS: 所有已跟踪文件均在白名单内，未发现真实用户路径或凭据特征。'
exit 0
