# run-tests.ps1 — 无外部依赖的安全门禁测试
# 全部在 %TEMP% 沙盒内运行，不改真实机器状态；通过后才允许进入真实维护准备。
# 退出码：0=全部通过；1=存在失败

[CmdletBinding()]
param([switch]$KeepSandbox)

$ErrorActionPreference = 'Continue'
$script:SkillRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:SkillRoot 'scripts\lib\Core.ps1')
. (Join-Path $script:SkillRoot 'scripts\lib\Plan.ps1')

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()
$script:DeniedDirs = @()
$script:PreDigest = @{}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    } catch {
        $script:Fail++
        $script:Failures += ('{0} :: {1}' -f $Name, $_.Exception.Message)
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("        {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
        if (-not [string]::IsNullOrWhiteSpace($_.ScriptStackTrace)) { Write-Host ("        stack: {0}" -f ($_.ScriptStackTrace -replace "`r?`n", " <- ")) -ForegroundColor DarkGray }
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw ('{0} (expected={1} actual={2})' -f $Message, $Expected, $Actual) }
}

function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$Message)
    if ($Text -notmatch $Pattern) { throw ('{0} (pattern={1} text={2})' -f $Message, $Pattern, $Text) }
}

# ── 沙盒 ────────────────────────────────────────────────────────────────────
$script:Sandbox = Join-Path $env:TEMP ('cwc-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$script:OriginalEnv = @{}
foreach ($k in @('LOCALAPPDATA', 'APPDATA', 'ProgramData', 'USERPROFILE')) {
    $script:OriginalEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
}

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path
}

function New-File {
    param([string]$Path, [string]$Content = 'x')
    New-Dir -Path ([System.IO.Path]::GetDirectoryName($Path)) | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content)
    return $Path
}

function Initialize-Sandbox {
    $sb = $script:Sandbox
    $local = New-Dir (Join-Path $sb 'local')
    $roaming = New-Dir (Join-Path $sb 'roaming')
    $pd = New-Dir (Join-Path $sb 'programdata')
    $up = New-Dir (Join-Path $sb 'user')

    $env:LOCALAPPDATA = $local
    $env:APPDATA = $roaming
    $env:ProgramData = $pd
    $env:USERPROFILE = $up

    # 允许范围（真实残留形态）
    New-File (Join-Path $local 'AnthropicClaude\app-1.0.0\claude.exe') 'MZ' | Out-Null
    New-File (Join-Path $local 'AnthropicClaude\Update.exe') 'MZ' | Out-Null
    New-File (Join-Path $local 'Claude\logs\app.log') 'log' | Out-Null
    New-File (Join-Path $pd 'Claude\Logs\main.log') 'log' | Out-Null
    New-Dir (Join-Path $roaming 'Microsoft\Windows\Start Menu\Programs\Anthropic') | Out-Null

    # 受保护资源
    New-File (Join-Path $roaming 'Claude\Network\Cookies') 'not-a-real-cookie' | Out-Null
    New-File (Join-Path $roaming 'Claude\Local State') '{}' | Out-Null
    New-File (Join-Path $local 'Claude\claude_desktop_config.json') '{}' | Out-Null
    New-File (Join-Path $up '.claude\config.json') '{}' | Out-Null
    New-File (Join-Path $up '.claude\projects\demo\a.md') 'x' | Out-Null
    New-File (Join-Path $local 'Google\Chrome\User Data\Default\Login Data') 'x' | Out-Null
    New-File (Join-Path $local 'Programs\DeepSeek Harness\app.exe') 'MZ' | Out-Null
    New-File (Join-Path $up 'Documents\secret.docx') 'x' | Out-Null
    New-File (Join-Path $sb 'projects\myrepo\.git\config') 'x' | Out-Null

    # 相似名称陷阱（不属于 Anthropic）
    New-File (Join-Path $local 'Clawd\claude.exe') 'MZ' | Out-Null

    # 允许目录内的受保护模式
    New-File (Join-Path $local 'AnthropicClaude\.git\config') 'x' | Out-Null

    $evidenceClean = [ordered]@{
        install_signals = [ordered]@{
            uninstall_entries = @(); appx = @(); processes = @(); services = @(); tasks = @()
        }
    }
    $evidenceInstalled = [ordered]@{
        install_signals = [ordered]@{
            uninstall_entries = @([ordered]@{ hive = 'HKCU'; key = 'test'; display_name = 'Claude'; publisher = 'Anthropic PBC'; version = '1.0'; install_location = ''; uninstall_string = '' })
            appx = @(); processes = @(); services = @(); tasks = @()
        }
    }
    $script:EvidenceClean = Join-Path $sb 'evidence-clean.json'
    $script:EvidenceInstalled = Join-Path $sb 'evidence-installed.json'
    Write-CwcJsonAtomic -Path $script:EvidenceClean -Object $evidenceClean | Out-Null
    Write-CwcJsonAtomic -Path $script:EvidenceInstalled -Object $evidenceInstalled | Out-Null
}

function Remove-Sandbox {
    foreach ($k in $script:OriginalEnv.Keys) {
        [Environment]::SetEnvironmentVariable($k, $script:OriginalEnv[$k], 'Process')
    }
    if ($KeepSandbox) {
        Write-Host ("沙盒保留：{0}" -f $script:Sandbox) -ForegroundColor Yellow
        return
    }
    $me = "$env:USERDOMAIN\$env:USERNAME"
    foreach ($p in @($script:DeniedDirs)) {
        if ($p -and (Test-Path -LiteralPath $p)) { & icacls.exe $p /remove:d $me 2>&1 | Out-Null }
    }
    try { Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction Stop }
    catch { Write-Host ("沙盒清理失败：{0}" -f $_.Exception.Message) -ForegroundColor Yellow }
}

function Invoke-CwcScript {
    param([string]$Script, [string[]]$Arguments = @())
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $path = Join-Path (Join-Path $script:SkillRoot 'scripts') $Script
    $clean = @($Arguments | Where-Object { $null -ne $_ -and ([string]$_).Length -gt 0 })
    $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $path @clean 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = (($out | Out-String).Trim()) }
}

function Remove-JunctionSafe {
    # PS 5.1 的 Remove-Item 对目录联接点会抛 NullReferenceException（实测），
    # 用 .NET Delete(recursive=false) 只删链接本身。
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) { [System.IO.Directory]::Delete($Path, $false) }
    } catch { }
}

function Get-Digest {
    param([string]$Path)
    return (Get-TreeFingerprint -Path $Path).Digest
}

function Get-NewestFile {
    param([string]$Dir, [string]$Pattern)
    return (Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Get-JournalFromOutput {
    param([string]$Text)
    if ($Text -match '(?m)^\s*日志\s*:\s*(.+?)\s*$') { return $Matches[1].Trim() }
    return $null
}

function Get-NonceFromOutput {
    param([string]$Text)
    if ($Text -match '口令[^:：]*[:：]\s*([0-9A-Fa-f]{4}-[0-9A-Fa-f]{4})') { return $Matches[1] }
    return $null
}

function New-ApprovalFile {
    param(
        [string]$Path,
        [string]$PlanHash,
        [string[]]$Ids,
        [string]$Nonce,
        [string]$Decision = 'APPROVE'
    )
    $doc = [ordered]@{
        schema_version     = 2
        plan_sha256        = $PlanHash
        decision           = $Decision
        approved_ids       = @($Ids)
        approved_by        = 'tester'
        approved_at        = '2026-01-01T00:00:00Z'
        confirmation_nonce = $Nonce
    }
    Write-CwcJsonAtomic -Path $Path -Object $doc | Out-Null
    return $Path
}

# ── 初始化 ──────────────────────────────────────────────────────────────────
Initialize-Sandbox
# 清掉上一次异常退出可能留下的锁，否则后续用例会被自己的残留挡住
foreach ($lockName in @('.quarantine.lock', '.restore.lock')) {
    $lockFile = Join-Path (Join-Path $script:SkillRoot 'manifests') $lockName
    if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
}
$config = Read-CwcJson -Path (Join-Path $script:SkillRoot 'config\scope.json')
$protection = Read-CwcJson -Path (Join-Path $script:SkillRoot 'config\protected-resources.json')
$local = $env:LOCALAPPDATA
$roaming = $env:APPDATA
$pd = $env:ProgramData
$up = $env:USERPROFILE

Write-Host '=================================================================='
Write-Host ' claude-windows-cleanup / P3 safety-gate tests'
Write-Host (' sandbox: {0}' -f $script:Sandbox)
Write-Host '=================================================================='

try {
    Write-Host ''
    Write-Host '[A] 路径守卫（进程内）' -ForegroundColor Cyan

    Test-Case 'A01 允许的安装目录 -> ALLOW' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'AnthropicClaude') -Config $config -Protection $protection
        Assert-Equal 'ALLOW' $r.Decision '安装目录应被允许'
        Assert-Equal 'install_dir' $r.KindHint 'kind 应为 install_dir'
    }

    Test-Case 'A02 受保护父目录下的 logs 子目录 -> ALLOW（最具体规则胜出）' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'Claude\logs') -Config $config -Protection $protection
        Assert-Equal 'ALLOW' $r.Decision 'logs 子目录应被允许'
    }

    Test-Case 'A03 系统目录 -> 拒绝（PROTECTED）' {
        $r = Test-CwcItemSafety -Path 'C:\Windows\System32' -Config $config -Protection $protection
        Assert-False ($r.Decision -eq 'ALLOW') '系统目录必须拒绝'
        Assert-Match 'protected_root|outside_scope' $r.Code '应给出受保护/越界原因'
    }

    Test-Case 'A04 个人文档 -> 拒绝（PROTECTED）' {
        $r = Test-CwcItemSafety -Path (Join-Path $up 'Documents') -Config $config -Protection $protection
        Assert-False ($r.Decision -eq 'ALLOW') '个人文档必须拒绝'
    }

    Test-Case 'A05 其他 AI 工具目录 -> 拒绝' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'Programs\DeepSeek Harness') -Config $config -Protection $protection
        Assert-False ($r.Decision -eq 'ALLOW') '其他 AI 工具必须拒绝'
    }

    Test-Case 'A06 浏览器共享数据 -> 拒绝' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'Google\Chrome\User Data') -Config $config -Protection $protection
        Assert-False ($r.Decision -eq 'ALLOW') '浏览器数据必须拒绝'
    }

    Test-Case 'A07 相似名称 Clawd\claude.exe -> BLOCKED' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'Clawd\claude.exe') -Config $config -Protection $protection
        Assert-Equal 'BLOCKED' $r.Decision '仅名字相似不得进入范围'
    }

    Test-Case 'A08 路径穿越 ..\..\Windows -> BLOCKED' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'AnthropicClaude\..\..\Windows') -Config $config -Protection $protection
        Assert-Equal 'BLOCKED' $r.Decision '穿越后应越界'
    }

    Test-Case 'A09 通配符路径 -> BLOCKED' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'AnthropicClaude\*') -Config $config -Protection $protection
        Assert-Equal 'BLOCKED' $r.Decision '通配符必须拒绝'
        Assert-Equal 'wildcard_path' $r.Code '应识别为通配符'
    }

    Test-Case 'A10 UNC 路径 -> BLOCKED' {
        $r = Test-CwcItemSafety -Path '\\server\share\claude' -Config $config -Protection $protection
        Assert-Equal 'BLOCKED' $r.Decision 'UNC 必须拒绝'
    }

    Test-Case 'A11 相对路径 -> BLOCKED' {
        $r = Test-CwcItemSafety -Path 'AnthropicClaude\app' -Config $config -Protection $protection
        Assert-Equal 'BLOCKED' $r.Decision '相对路径必须拒绝'
    }

    Test-Case 'A12 卷根 -> BLOCKED' {
        $r = Test-CwcItemSafety -Path 'C:\' -Config $config -Protection $protection
        Assert-Equal 'BLOCKED' $r.Decision '卷根必须拒绝'
        Assert-Equal 'volume_root' $r.Code '应识别为卷根'
    }

    Test-Case 'A13 目录联接点 -> BLOCKED(reparse)' {
        $real = New-Dir (Join-Path $script:Sandbox 'junctarget')
        $junc = Join-Path $local 'AnthropicClaude\link'
        try {
            New-Item -ItemType Junction -Path $junc -Target $real -ErrorAction Stop | Out-Null
            $r = Test-CwcItemSafety -Path $junc -Config $config -Protection $protection
            Assert-Equal 'BLOCKED' $r.Decision '联接点必须拒绝'
            Assert-Match 'reparse' $r.Code '应识别为重解析点'
        } finally {
            # 必须移除：否则安装目录的子树里长期带一个重解析点，会污染后续用例
            Remove-JunctionSafe -Path $junc
        }
    }

    Test-Case 'A14 权限不足目录 -> BLOCKED(unreadable)' {
        $denied = New-Dir (Join-Path $local 'AnthropicClaude\denied')
        New-File (Join-Path $denied 'a.txt') 'x' | Out-Null
        $script:DeniedDirs += $denied
        $me = "$env:USERDOMAIN\$env:USERNAME"
        & icacls.exe $denied /deny "${me}:(OI)(CI)(RX)" 2>&1 | Out-Null
        $r = Test-CwcItemSafety -Path $denied -Config $config -Protection $protection
        & icacls.exe $denied /remove:d $me 2>&1 | Out-Null
        Assert-Equal 'BLOCKED' $r.Decision '不可读不得当作不存在'
        Assert-Match 'unreadable|not_found' $r.Code '应因不可读被拒'
    }

    Test-Case 'A15 允许目录内的 .git -> PROTECTED' {
        $r = Test-CwcItemSafety -Path (Join-Path $local 'AnthropicClaude\.git') -Config $config -Protection $protection
        Assert-Equal 'PROTECTED' $r.Decision '仓库元数据必须受保护'
    }

    Test-Case 'A16 Claude Code 的 .claude -> PROTECTED' {
        $r = Test-CwcItemSafety -Path (Join-Path $up '.claude') -Config $config -Protection $protection
        Assert-Equal 'PROTECTED' $r.Decision '.claude 必须受保护'
    }

    Test-Case 'A17 Claude Desktop 用户数据 %APPDATA%\Claude -> PROTECTED' {
        $r = Test-CwcItemSafety -Path (Join-Path $roaming 'Claude') -Config $config -Protection $protection
        Assert-Equal 'PROTECTED' $r.Decision '用户数据必须受保护'
    }

    Test-Case 'A18 计划哈希：稳定 + 对改动敏感' {
        $items = @(
            [pscustomobject]@{ id='cwc-0001'; kind='install_dir'; path='C:\A'; status='VERIFIED'; action='QUARANTINE'; bytes=1; last_write_utc='2026-01-01T00:00:00Z'; digest='aa' },
            [pscustomobject]@{ id='cwc-0002'; kind='logs'; path='C:\B'; status='BLOCKED'; action='NONE'; bytes=2; last_write_utc='2026-01-01T00:00:00Z'; digest='bb' }
        )
        $h1 = Get-PlanSha256 -Items $items
        $h2 = Get-PlanSha256 -Items ($items | Sort-Object { $_.id } -Descending)
        Assert-Equal $h1 $h2 '顺序不同不应改变哈希'
        $items[0].path = 'C:\A2'
        $h3 = Get-PlanSha256 -Items $items
        Assert-False ($h1 -eq $h3) '任意字段改动必须改变哈希'
    }

    Write-Host ''
    Write-Host '[B] 端到端（子进程）' -ForegroundColor Cyan

    $script:Inspection = Join-Path $script:Sandbox 'inspection.json'
    $script:InspectionInstalled = Join-Path $script:Sandbox 'inspection-installed.json'
    $script:PlanPath = $null
    $script:ApprovalPath = $null
    $script:JournalPath = $null

    Test-Case 'B01 inspect：已卸载 -> UNINSTALLED_CONFIRMED 且 4 项 VERIFIED' {
        $r = Invoke-CwcScript -Script 'inspect.ps1' -Arguments @('-EvidencePath', $script:EvidenceClean, '-OutputPath', $script:Inspection)
        Assert-Equal 0 $r.Code ('inspect 退出码' + "`n" + $r.Output)
        $doc = Read-CwcJson -Path $script:Inspection
        Assert-Equal 'UNINSTALLED_CONFIRMED' $doc.install_state '安装状态'
        Assert-Equal 4 $doc.summary.verified 'VERIFIED 数量'
        Assert-Equal 0 $doc.summary.blocked '不应有 BLOCKED'
        Assert-Equal 4 $doc.summary.actionable '可执行候选'
        Assert-True (@($doc.protected_observed).Count -ge 3) '应记录受保护资源'
    }

    Test-Case 'B02 inspect：安装信号存在 -> INSTALLED 且 0 项可执行' {
        $r = Invoke-CwcScript -Script 'inspect.ps1' -Arguments @('-EvidencePath', $script:EvidenceInstalled, '-OutputPath', $script:InspectionInstalled)
        Assert-Equal 0 $r.Code 'inspect 退出码'
        $doc = Read-CwcJson -Path $script:InspectionInstalled
        Assert-Equal 'INSTALLED' $doc.install_state '安装状态'
        Assert-Equal 0 $doc.summary.actionable '已安装时不得给出可执行项'
        Assert-True (@($doc.items | Where-Object { $_.status -eq 'UNKNOWN' }).Count -ge 1) '应降级为 UNKNOWN'
    }

    Test-Case 'B03 plan：生成哈希、sidecar、空审批模板，条目全部 selected=false' {
        $r = Invoke-CwcScript -Script 'plan.ps1' -Arguments @('-InspectionPath', $script:Inspection)
        Assert-Equal 0 $r.Code ('plan 退出码' + "`n" + $r.Output)
        $planFile = Get-NewestFile -Dir (Join-Path $script:SkillRoot 'manifests') -Pattern 'plan-*.json'
        Assert-True ($null -ne $planFile) '应生成计划文件'
        $script:PlanPath = $planFile.FullName
        $script:PlanOutput = $r.Output
        $script:Nonce = Get-NonceFromOutput -Text $r.Output
        Assert-True (-not [string]::IsNullOrWhiteSpace($script:Nonce)) '计划应打印一次性口令'
        $plan = Read-CwcJson -Path $script:PlanPath
        Assert-Equal (Get-PlanSha256 -Items @($plan.items)) $plan.plan_sha256 'plan_sha256 必须与 items 一致'
        $sidecar = [System.IO.File]::ReadAllText(($script:PlanPath + '.sha256')).Trim()
        Assert-Equal $sidecar (Get-FileSha256 -Path $script:PlanPath) 'sidecar 必须绑定计划文件'
        Assert-Equal 0 @($plan.items | Where-Object { $_.selected }).Count '默认不得预选'
        $tpl = Get-NewestFile -Dir (Join-Path $script:SkillRoot 'manifests') -Pattern 'approval-template-*.json'
        Assert-True ($null -ne $tpl) '应生成审批模板'
        $tplDoc = Read-CwcJson -Path $tpl.FullName
        Assert-Equal 0 @($tplDoc.approved_ids).Count '审批模板默认不得含任何 id'
        Assert-Equal $plan.plan_sha256 $tplDoc.plan_sha256 '模板必须绑定计划哈希'
    }

    Test-Case 'B04 validate：无审批 -> 拒绝(2)' {
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath)
        Assert-Equal 2 $r.Code '无审批必须拒绝'
    }

    Test-Case 'B05 validate：审批哈希被篡改 -> 拒绝(2)' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $ids = @($plan.items | Where-Object { $_.status -eq 'VERIFIED' } | ForEach-Object { $_.id })
        $bad = [ordered]@{ schema_version = 1; plan_sha256 = ('0' * 64); decision = 'APPROVE'; approved_ids = $ids; approved_by = 'tester'; approved_at = '2026-01-01T00:00:00Z' }
        $p = Join-Path $script:Sandbox 'approval-badhash.json'
        Write-CwcJsonAtomic -Path $p -Object $bad | Out-Null
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $p)
        Assert-Equal 2 $r.Code '哈希不符必须拒绝'
        Assert-Match 'approval_plan_hash_mismatch' $r.Output '应报哈希不匹配'
    }

    Test-Case 'B06 validate：审批含不存在 id -> 拒绝(2)' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $bad = [ordered]@{ schema_version = 1; plan_sha256 = $plan.plan_sha256; decision = 'APPROVE'; approved_ids = @('cwc-9999'); approved_by = 'tester'; approved_at = '2026-01-01T00:00:00Z' }
        $p = Join-Path $script:Sandbox 'approval-unknown.json'
        Write-CwcJsonAtomic -Path $p -Object $bad | Out-Null
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $p)
        Assert-Equal 2 $r.Code '未知 id 必须拒绝'
    }

    Test-Case 'B07 validate：合法审批（含口令）-> 通过(0)' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $ids = @($plan.items | Where-Object { $_.status -eq 'VERIFIED' } | ForEach-Object { $_.id })
        Assert-True (-not [string]::IsNullOrWhiteSpace($script:Nonce)) '缺少口令，无法构造合法审批'
        $script:ApprovalPath = Join-Path $script:Sandbox 'approval-ok.json'
        $null = New-ApprovalFile -Path $script:ApprovalPath -PlanHash $plan.plan_sha256 -Ids $ids -Nonce $script:Nonce
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath)
        Assert-Equal 0 $r.Code ('合法审批应通过' + "`n" + $r.Output)
    }

    Test-Case 'B07b validate：口令错误 -> 拒绝(2)' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $ids = @($plan.items | Where-Object { $_.status -eq 'VERIFIED' } | ForEach-Object { $_.id })
        $p = Join-Path $script:Sandbox 'approval-badnonce.json'
        $null = New-ApprovalFile -Path $p -PlanHash $plan.plan_sha256 -Ids $ids -Nonce '0000-0000'
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $p)
        Assert-Equal 2 $r.Code '口令错误必须拒绝'
        Assert-Match 'approval_nonce' $r.Output '应报口令问题'
    }

    Test-Case 'B07c validate：口令缺失 -> 拒绝(2)' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $ids = @($plan.items | Where-Object { $_.status -eq 'VERIFIED' } | ForEach-Object { $_.id })
        $p = Join-Path $script:Sandbox 'approval-nononce.json'
        $null = New-ApprovalFile -Path $p -PlanHash $plan.plan_sha256 -Ids $ids -Nonce ''
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $p)
        Assert-Equal 2 $r.Code '口令缺失必须拒绝'
    }

    Test-Case 'B08 DryRun：零文件修改、零日志' {
        $installDir = Join-Path $local 'AnthropicClaude'
        $before = Get-Digest -Path $installDir
        $journalBefore = @(Get-ChildItem -LiteralPath (Join-Path $script:SkillRoot 'manifests') -Filter 'journal-*.json' -ErrorAction SilentlyContinue).Count
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath)
        Assert-Equal 0 $r.Code 'DryRun 退出码'
        Assert-Match 'DRY-RUN' $r.Output '应标注 DryRun'
        Assert-Equal $before (Get-Digest -Path $installDir) 'DryRun 不得改动文件'
        $journalAfter = @(Get-ChildItem -LiteralPath (Join-Path $script:SkillRoot 'manifests') -Filter 'journal-*.json' -ErrorAction SilentlyContinue).Count
        Assert-Equal $journalBefore $journalAfter 'DryRun 不得写日志'
    }

    Test-Case 'B09 未授权执行 -> 拒绝(2) 且无任何移动' {
        $installDir = Join-Path $local 'AnthropicClaude'
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Execute')
        Assert-Equal 2 $r.Code '未授权必须拒绝'
        Assert-True (Test-Path -LiteralPath $installDir) '未授权不得移动'
    }

    Test-Case 'B10 授权执行 -> 隔离成功、原始路径消失、日志记录 moved' {
        $plan = Read-CwcJson -Path $script:PlanPath
        foreach ($it in @($plan.items | Where-Object { $_.status -eq 'VERIFIED' })) {
            $script:PreDigest[[string]$it.normalized_path] = Get-Digest -Path ([string]$it.normalized_path)
        }
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath, '-Execute')
        Assert-Equal 0 $r.Code ('执行应成功' + "`n" + $r.Output)
        foreach ($p in @($script:PreDigest.Keys)) { Assert-False (Test-Path -LiteralPath $p) ('应已移走：' + $p) }
        $journalFromOutput = Get-JournalFromOutput -Text $r.Output
        Assert-True (-not [string]::IsNullOrWhiteSpace($journalFromOutput)) '输出里应给出日志路径'
        Assert-True (Test-Path -LiteralPath $journalFromOutput) '日志文件应存在'
        $script:JournalPath = $journalFromOutput
        $j = Read-CwcJson -Path $script:JournalPath
        Assert-Equal 'completed' $j.result '日志结果'
        Assert-Equal 4 @($j.entries | Where-Object { $_.state -eq 'moved' }).Count '应记录 4 项 moved'
        foreach ($e in @($j.entries)) { Assert-True (Test-Path -LiteralPath ([string]$e.moved_to)) '隔离目标必须存在' }
    }

    Test-Case 'B11 verify：隔离后一致性检查 -> PASS/PARTIAL' {
        $baseline = Join-Path $script:Sandbox 'baseline.json'
        $r0 = Invoke-CwcScript -Script 'preflight.ps1' -Arguments @('-OutputPath', $baseline)
        Assert-Equal 0 $r0.Code 'preflight 退出码'
        $r = Invoke-CwcScript -Script 'verify.ps1' -Arguments @('-Baseline', $baseline, '-InspectionPath', $script:Inspection, '-Journal', $script:JournalPath)
        Assert-True (@(0, 4) -contains $r.Code) ('verify 应 PASS 或 PARTIAL' + "`n" + $r.Output)
        Assert-Match 'PASS|PARTIAL' $r.Output '应有判定'
    }

    Test-Case 'B12 幂等：同一授权二次执行 -> 拒绝(2) 且不重复移动' {
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath, '-Execute')
        Assert-Equal 2 $r.Code '二次执行必须拒绝'
        $j = Read-CwcJson -Path $script:JournalPath
        Assert-Equal 4 @($j.entries | Where-Object { $_.state -eq 'moved' }).Count '不得新增移动'
    }

    Test-Case 'B13 restore：原样搬回且指纹一致' {
        $r = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $script:JournalPath, '-Execute')
        Assert-Equal 0 $r.Code ('恢复应成功' + "`n" + $r.Output)
        foreach ($p in @($script:PreDigest.Keys)) {
            Assert-True (Test-Path -LiteralPath $p) ('应已恢复：' + $p)
            Assert-Equal $script:PreDigest[$p] (Get-Digest -Path $p) ('恢复后指纹必须一致：' + $p)
        }
        $j = Read-CwcJson -Path $script:JournalPath
        Assert-Equal 'completed' $j.restore_result '恢复结果'
    }

    Test-Case 'B14 跨卷隔离 -> 拒绝(2)' {
        $other = $null
        foreach ($d in @('D:\', 'E:\', 'F:\')) {
            if ((Test-Path -LiteralPath $d) -and ([System.IO.Path]::GetPathRoot($d) -ne [System.IO.Path]::GetPathRoot($local))) { $other = $d; break }
        }
        if (-not $other) { throw '无第二个卷，无法验证跨卷拒绝' }
        $qRoot = Join-Path $other ('cwc-crossvol-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath, '-Execute', '-QuarantineRoot', $qRoot)
        Assert-Equal 2 $r.Code ('跨卷必须拒绝' + "`n" + $r.Output)
        Assert-Match '跨卷' $r.Output '应说明跨卷'
        if (Test-Path -LiteralPath $qRoot) { Remove-Item -LiteralPath $qRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Test-Case 'B15 中途异常：第二项路径消失 -> 停止(5) 且日志如实记录' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $dirItem = @($plan.items | Where-Object { $_.kind -eq 'install_dir' })[0]
        $nestedPath = Join-Path ([string]$dirItem.path) 'app-1.0.0\claude.exe'
        $nestedFp = Get-TreeFingerprint -Path $nestedPath
        $items = @(
            [ordered]@{
                id = 'cwc-0001'; root_id = [string]$dirItem.root_id; kind = 'install_dir'; fs_kind = 'directory'
                path = [string]$dirItem.path; normalized_path = [string]$dirItem.normalized_path; status = 'VERIFIED'
                status_reason = 'test'; proposed_action = 'QUARANTINE'; risk = 'LOW'; bytes = [long]$dirItem.bytes
                file_count = [int]$dirItem.file_count; digest = [string]$dirItem.digest; last_write_utc = [string]$dirItem.last_write_utc
                restorable = $true; approval_required = $true; selected = $false
            },
            [ordered]@{
                id = 'cwc-0002'; root_id = 'nested'; kind = 'install_dir'; fs_kind = 'file'
                path = $nestedPath; normalized_path = $nestedPath; status = 'VERIFIED'
                status_reason = 'test'; proposed_action = 'QUARANTINE'; risk = 'LOW'; bytes = [long]$nestedFp.Bytes
                file_count = 1; digest = [string]$nestedFp.Digest; last_write_utc = '2026-01-01T00:00:00Z'
                restorable = $true; approval_required = $true; selected = $false
            }
        )
        $hash = Get-PlanSha256 -Items $items
        $realPlan = Read-CwcJson -Path $script:PlanPath
        $doc = [ordered]@{
            schema_version = 2; skill = 'claude-windows-cleanup'; plan_id = 'plan-test-nested'; created_at = '2026-01-01T00:00:00Z'
            source_inspection = ''; inspection_sha256 = ''; install_state = 'UNINSTALLED_CONFIRMED'
            config_sha256 = [string]$realPlan.config_sha256
            protection_sha256 = [string]$realPlan.protection_sha256
            skill_fingerprint = [string]$realPlan.skill_fingerprint
            execution_policy = [ordered]@{ mode = 'QUARANTINE_ONLY'; permanent_delete = $false }
            counts = [ordered]@{ total = 2 }; items = $items; plan_sha256 = $hash
            approval_nonce_sha256 = (Get-TextSha256 -Text 'TEST-NONCE')
        }
        $p = Join-Path $script:Sandbox 'plan-nested.json'
        Write-CwcJsonAtomic -Path $p -Object $doc | Out-Null
        [System.IO.File]::WriteAllText(($p + '.sha256'), (Get-FileSha256 -Path $p))
        $ap = Join-Path $script:Sandbox 'approval-nested.json'
        $null = New-ApprovalFile -Path $ap -PlanHash $hash -Ids @('cwc-0001', 'cwc-0002') -Nonce 'TEST-NONCE'
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $p, '-Approval', $ap, '-Execute')
        Assert-Equal 5 $r.Code ('中途失败应返回 5' + "`n" + $r.Output)
        $jf = Get-JournalFromOutput -Text $r.Output
        Assert-True (-not [string]::IsNullOrWhiteSpace($jf)) '输出里应给出日志路径'
        $j = Read-CwcJson -Path $jf
        Assert-Equal 'failed' $j.result '日志结果应为 failed'
        Assert-Equal 1 @($j.entries | Where-Object { $_.state -eq 'moved' }).Count '应只有第一项被移动'
        Assert-Equal 1 @($j.entries | Where-Object { $_.state -eq 'failed' }).Count '第二项应记录失败'
        $rr = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $jf, '-Execute')
        Assert-Equal 0 $rr.Code '应能恢复第一项'
    }

    Test-Case 'B16 隔离根不可用 -> 拒绝(2) 且零移动' {
        $blocker = New-File (Join-Path $script:Sandbox 'not-a-dir.txt') 'x'
        $badRoot = Join-Path $blocker 'q'
        $installDir = Join-Path $local 'AnthropicClaude'
        $before = Get-Digest -Path $installDir
        $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath, '-Execute', '-QuarantineRoot', $badRoot)
        Assert-Equal 2 $r.Code '隔离根不可用应拒绝'
        Assert-Equal $before (Get-Digest -Path $installDir) '不得移动任何东西'
    }

    Test-Case 'B17 计划篡改：改路径 -> 完整性校验失败(2)' {
        $copy = Join-Path $script:Sandbox 'plan-tampered.json'
        $plan = Read-CwcJson -Path $script:PlanPath
        $plan.items[0].path = 'C:\Windows\System32'
        Write-CwcJsonAtomic -Path $copy -Object $plan | Out-Null
        [System.IO.File]::WriteAllText(($copy + '.sha256'), (Get-FileSha256 -Path $copy))
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $copy, '-IntegrityOnly')
        Assert-Equal 2 $r.Code '篡改必须被拒'
        Assert-Match 'plan_items_hash_mismatch' $r.Output '应报哈希不一致'
    }

    Test-Case 'B18 状态变化：扫描后修改文件 -> 拒绝(2)' {
        $target = Join-Path $local 'AnthropicClaude\app-1.0.0\claude.exe'
        Add-Content -LiteralPath $target -Value 'CHANGED'
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath)
        Assert-Equal 2 $r.Code '状态变化必须拒绝'
        Assert-Match 'state_changed' $r.Output '应报状态变化'
    }

    Write-Host ''
    Write-Host '[C] V1.1 故障注入与加固（R4）' -ForegroundColor Cyan

    Test-Case 'C01 计划完整性：配置绑定被改 -> 拒绝(2)' {
        $copy = Join-Path $script:Sandbox 'plan-config-tampered.json'
        $plan = Read-CwcJson -Path $script:PlanPath
        $plan.config_sha256 = ('0' * 64)
        Write-CwcJsonAtomic -Path $copy -Object $plan | Out-Null
        [System.IO.File]::WriteAllText(($copy + '.sha256'), (Get-FileSha256 -Path $copy))
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $copy, '-IntegrityOnly')
        Assert-Equal 2 $r.Code '配置绑定不符必须拒绝'
        Assert-Match 'config_binding_mismatch' $r.Output '应报配置绑定不符'
    }

    Test-Case 'C02 计划完整性：文件字节被改 -> 拒绝(2)' {
        $copy = Join-Path $script:Sandbox 'plan-bytes-tampered.json'
        Copy-Item -LiteralPath $script:PlanPath -Destination $copy -Force
        Copy-Item -LiteralPath ($script:PlanPath + '.sha256') -Destination ($copy + '.sha256') -Force
        [System.IO.File]::AppendAllText($copy, "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $r = Invoke-CwcScript -Script 'validate-plan.ps1' -Arguments @('-Plan', $copy, '-IntegrityOnly')
        Assert-Equal 2 $r.Code '文件字节变化必须被拒'
        Assert-Match 'plan_file_hash_mismatch' $r.Output '应报文件哈希不符'
    }

    Test-Case 'C03 并发：存在活锁 -> 拒绝(2)' {
        $lock = Join-Path (Join-Path $script:SkillRoot 'manifests') '.quarantine.lock'
        Write-CwcJsonAtomic -Path $lock -Object ([ordered]@{ pid = $PID; host = $env:COMPUTERNAME; started_at = '2026-01-01T00:00:00Z' }) | Out-Null
        try {
            $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $script:ApprovalPath, '-Execute')
            Assert-Equal 2 $r.Code '活锁存在时必须拒绝'
            Assert-Match '另一个执行进程' $r.Output '应说明并发'
        } finally {
            if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force }
        }
    }

    Test-Case 'C04 隔离根为联接点 -> 拒绝(2)' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $sc = @($plan.items | Where-Object { $_.kind -eq 'shortcut_dir' })[0]
        $apSingle = Join-Path $script:Sandbox 'approval-single-c04.json'
        $null = New-ApprovalFile -Path $apSingle -PlanHash $plan.plan_sha256 -Ids @([string]$sc.id) -Nonce $script:Nonce
        $realRoot = New-Dir (Join-Path $script:Sandbox 'qreal')
        $juncRoot = Join-Path $script:Sandbox 'qjunction'
        New-Item -ItemType Junction -Path $juncRoot -Target $realRoot -ErrorAction Stop | Out-Null
        try {
            $r = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $apSingle, '-Execute', '-QuarantineRoot', $juncRoot)
            Assert-Equal 2 $r.Code '隔离根是联接点必须拒绝'
            Assert-Match '不可信|reparse' $r.Output '应报重解析点'
        } finally {
            Remove-JunctionSafe -Path $juncRoot
        }
    }

    Test-Case 'C05 隔离目录祖先含联接点 -> 判定不安全' {
        $real = New-Dir (Join-Path $script:Sandbox 'ancestor-real')
        $junc = Join-Path $script:Sandbox 'ancestor-junction'
        New-Item -ItemType Junction -Path $junc -Target $real -ErrorAction Stop | Out-Null
        try {
            $child = New-Dir (Join-Path $junc 'run')
            $r = Test-CwcQuarantineDir -Path $child
            Assert-False $r.Ok '祖先含联接点必须判不安全'
            Assert-Match 'reparse_ancestor' $r.Reason '应识别祖先重解析点'
        } finally {
            Remove-JunctionSafe -Path $junc
        }
    }

    Test-Case 'C06 移动成功但日志失败 -> 自动搬回' {
        $src = New-File (Join-Path $script:Sandbox 'mv-src.txt') 'payload'
        $dst = Join-Path $script:Sandbox 'mv-dst.txt'
        $r = Invoke-CwcMoveWithJournal -Source $src -Destination $dst -SaveJournal { throw 'journal-down' }
        Assert-False $r.Ok '整体应失败'
        Assert-Equal 'journal' $r.Stage '应标记为日志阶段失败'
        Assert-True $r.Reverted '应已自动搬回'
        Assert-True (Test-Path -LiteralPath $src) '源文件应已回到原位'
        Assert-False (Test-Path -LiteralPath $dst) '目标不应残留'
    }

    Test-Case 'C07 报告脱敏：token/cookie 不入库' {
        $obj = [ordered]@{
            note = ('Bearer ' + 'abcdefghijklmnop')
            access_token = 'sk-ant-0123456789abcdef'
            nested = [ordered]@{ cookies = 'session=secret'; safe = 'ok' }
        }
        $clean = Hide-CwcSensitive -InputObject $obj
        Assert-Equal '[REDACTED]' ([string]$clean['access_token']) 'access_token 必须被屏蔽'
        Assert-Equal '[REDACTED]' ([string]$clean['nested']['cookies']) 'cookies 必须被屏蔽'
        Assert-Match '\[REDACTED\]' ([string]$clean['note']) '值里的 Bearer 必须被屏蔽'
        Assert-Equal 'ok' ([string]$clean['nested']['safe']) '普通字段不得被误伤'
    }

    Test-Case 'C08 探测失败 -> UNKNOWN 且无可执行项' {
        $ev = Join-Path $script:Sandbox 'evidence-probe-failed.json'
        Write-CwcJsonAtomic -Path $ev -Object ([ordered]@{
            install_signals = [ordered]@{
                uninstall_entries = @(); appx = @(); processes = @(); services = @(); tasks = @()
                probes = @([ordered]@{ probe = 'uninstall'; path = 'HKLM'; ok = $false })
            }
        }) | Out-Null
        $outFile = Join-Path $script:Sandbox 'inspection-probe-failed.json'
        $r = Invoke-CwcScript -Script 'inspect.ps1' -Arguments @('-EvidencePath', $ev, '-OutputPath', $outFile)
        Assert-Equal 0 $r.Code 'inspect 应正常退出'
        $doc = Read-CwcJson -Path $outFile
        Assert-Equal 'UNKNOWN' $doc.install_state '探测失败必须降级 UNKNOWN'
        Assert-Equal 0 $doc.summary.actionable 'UNKNOWN 状态不得给出可执行项'
    }

    Test-Case 'C09 目标被换成联接点 -> 执行前复核拒绝' {
        $target = New-Dir (Join-Path $local 'AnthropicClaude\swapdir')
        New-File (Join-Path $target 'a.txt') 'x' | Out-Null
        $fp = Get-TreeFingerprint -Path $target
        $item = [pscustomobject]@{
            id = 'cwc-9002'; kind = 'install_dir'; fs_kind = 'directory'; path = $target; normalized_path = $target
            status = 'VERIFIED'; proposed_action = 'QUARANTINE'; bytes = [long]$fp.Bytes; digest = [string]$fp.Digest
            last_write_utc = ''
        }
        Remove-Item -LiteralPath $target -Recurse -Force
        $real = New-Dir (Join-Path $script:Sandbox 'swap-target')
        New-Item -ItemType Junction -Path $target -Target $real -ErrorAction Stop | Out-Null
        try {
            $r = Test-LiveItemState -Item $item -Config $config -Protection $protection
            Assert-False $r.Ok '替换为联接点后必须拒绝'
            Assert-Match 'reparse' $r.Reason '应识别重解析点'
        } finally {
            Remove-JunctionSafe -Path $target
        }
    }

    Test-Case 'C10 只读检查不写入目标目录' {
        $installDir = Join-Path $local 'AnthropicClaude'
        $before = Get-Digest -Path $installDir
        $outFile = Join-Path $script:Sandbox 'inspection-nowrite.json'
        $r = Invoke-CwcScript -Script 'inspect.ps1' -Arguments @('-EvidencePath', $script:EvidenceClean, '-OutputPath', $outFile)
        Assert-Equal 0 $r.Code 'inspect 应成功'
        Assert-Equal $before (Get-Digest -Path $installDir) '只读检查不得改动目标'
    }

    Test-Case 'C11 恢复：目标被占用 -> 5 且不覆盖；解除后可重试' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $sc = @($plan.items | Where-Object { $_.kind -eq 'shortcut_dir' })[0]
        Assert-True ($null -ne $sc) '计划里应有 shortcut_dir 条目'
        $ap = Join-Path $script:Sandbox 'approval-single.json'
        $null = New-ApprovalFile -Path $ap -PlanHash $plan.plan_sha256 -Ids @([string]$sc.id) -Nonce $script:Nonce

        $rq = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $ap, '-Execute')
        Assert-Equal 0 $rq.Code ('单项隔离应成功' + "`n" + $rq.Output)
        $journal = Get-JournalFromOutput -Text $rq.Output
        Assert-True (Test-Path -LiteralPath $journal) '应产生日志'

        $occupied = [string]$sc.normalized_path
        New-File $occupied 'occupied-by-user' | Out-Null
        $rr = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $journal, '-Execute')
        Assert-Equal 5 $rr.Code '目标被占用时必须停止'
        Assert-Equal 'occupied-by-user' (Get-Content -LiteralPath $occupied -Raw) '不得覆盖占用文件'
        $j = Read-CwcJson -Path $journal
        Assert-Equal 'target_occupied' ([string]$j.entries[0].restore_error) '应记录 target_occupied'

        Remove-Item -LiteralPath $occupied -Force
        $rr2 = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $journal, '-Execute')
        Assert-Equal 0 $rr2.Code ('解除占用后应可重试' + "`n" + $rr2.Output)
        Assert-True (Test-Path -LiteralPath $occupied) '应已恢复'
    }

    Test-Case 'C12 恢复：隔离内容被篡改 -> 5；修复后可重试' {
        $plan = Read-CwcJson -Path $script:PlanPath
        $sc = @($plan.items | Where-Object { $_.kind -eq 'shortcut_dir' })[0]
        $ap = Join-Path $script:Sandbox 'approval-single.json'
        $rq = Invoke-CwcScript -Script 'quarantine.ps1' -Arguments @('-Plan', $script:PlanPath, '-Approval', $ap, '-Execute')
        Assert-Equal 0 $rq.Code '再次隔离应成功'
        $journal = Get-JournalFromOutput -Text $rq.Output
        $j = Read-CwcJson -Path $journal
        $qdir = [string]$j.entries[0].moved_to
        Assert-True (Test-Path -LiteralPath $qdir) '隔离目标应存在'

        $extra = New-File (Join-Path $qdir 'tampered.txt') 'evil'
        $rr = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $journal, '-Execute')
        Assert-Equal 5 $rr.Code '内容被篡改必须拒绝恢复'
        $j2 = Read-CwcJson -Path $journal
        Assert-Match 'quarantine_digest_mismatch' ([string]$j2.entries[0].restore_error) '应报摘要不符'

        Remove-Item -LiteralPath $extra -Force
        $rr2 = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $journal, '-Execute')
        Assert-Equal 0 $rr2.Code ('去掉篡改后应可重试' + "`n" + $rr2.Output)
    }

    Test-Case 'C13 崩溃对账：planned + planned_dest -> 可恢复' {
        $orig = Join-Path $local 'Programs\Claude'
        if (Test-Path -LiteralPath $orig) { Remove-Item -LiteralPath $orig -Recurse -Force }
        New-File (Join-Path $orig 'app\x.txt') 'payload' | Out-Null
        $fp = Get-TreeFingerprint -Path $orig
        $qrun = New-Dir (Join-Path $script:Sandbox 'manual-quarantine')
        $dest = Join-Path $qrun 'cwc-9003-Claude'
        Move-Item -LiteralPath $orig -Destination $dest

        $journal = Join-Path $script:Sandbox 'journal-crash.json'
        Write-CwcJsonAtomic -Path $journal -Object ([ordered]@{
            schema_version = 2; run_id = [guid]::NewGuid().ToString(); result = 'failed'; quarantine_run = $qrun
            entries = @([ordered]@{
                id = 'cwc-9003'; original_path = $orig; kind = 'install_dir'; bytes = [long]$fp.Bytes
                digest = [string]$fp.Digest; state = 'planned'; planned_dest = $dest; moved_to = ''
            })
        }) | Out-Null

        Assert-False (Test-Path -LiteralPath $orig) '模拟：原路径应已消失'
        $rr = Invoke-CwcScript -Script 'restore.ps1' -Arguments @('-Journal', $journal, '-Reconcile', '-Execute')
        Assert-Equal 0 $rr.Code ('崩溃残留应可对账恢复' + "`n" + $rr.Output)
        Assert-True (Test-Path -LiteralPath $orig) '应已恢复'
        Assert-Equal ([string]$fp.Digest) (Get-Digest -Path $orig) '恢复后指纹应一致'
        Remove-Item -LiteralPath $orig -Recurse -Force -ErrorAction SilentlyContinue
    }

    Test-Case 'C14 全程非管理员权限' {
        $isAdmin = [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Assert-False $isAdmin '测试必须在普通用户权限下运行'
    }

} finally {
    Remove-Sandbox
}

Write-Host ''
Write-Host '=================================================================='
Write-Host (' 结果：{0} passed / {1} failed' -f $script:Pass, $script:Fail)
Write-Host '=================================================================='
if ($script:Fail -gt 0) {
    foreach ($f in $script:Failures) { Write-Host ('  - {0}' -f $f) -ForegroundColor Red }
    exit 1
}
exit 0
