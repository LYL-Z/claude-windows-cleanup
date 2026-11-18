# privacy-audit.ps1 — Claude 相关本地数据的只读隐私安全评估（R2）
# 只读元数据：路径、大小、文件数、修改时间、敏感文件名是否存在。
# 绝不读取文件内容，绝不输出 Token/Cookie/凭据原文，绝不修改任何东西。
# 输出：reports/privacy-<ts>.json + reports/privacy-<ts>.md

[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$config = Read-CwcJson -Path (Join-Path $skillRoot 'config\scope.json')
$protection = Read-CwcJson -Path (Join-Path $skillRoot 'config\protected-resources.json')
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; exit 3 }
if ($null -eq $config.privacy_audit) { Write-Error '配置缺少 privacy_audit'; exit 3 }

function Measure-CwcTree {
    <# 只统计条目数与字节数，不做哈希、不读内容、不进入重解析点。 #>
    param([string]$Path, [int]$MaxEntries = 20000, [long]$MaxBytes = 5368709120)

    $result = [pscustomobject]@{ Ok = $false; Count = 0; Bytes = [long]0; Reparse = $false; Reason = '' }
    if (-not (Test-Path -LiteralPath $Path)) { $result.Reason = 'not_found'; return $result }
    if (Test-ReparseItem -Path $Path) { $result.Reparse = $true; $result.Reason = 'reparse'; return $result }

    $isDir = $false
    try { $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer } catch { $result.Reason = 'unreadable'; return $result }
    if (-not $isDir) {
        try { $fi = [System.IO.FileInfo]::new($Path); $result.Count = 1; $result.Bytes = [long]$fi.Length; $result.Ok = $true }
        catch { $result.Reason = 'unreadable' }
        return $result
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    $count = 0; $bytes = [long]0
    try {
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($dir)) {
                $attrs = [System.IO.File]::GetAttributes($entry)
                if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $count++
                if ($count -gt $MaxEntries) { $result.Reason = 'too_many_entries'; $result.Count = $count; $result.Bytes = $bytes; return $result }
                if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { $stack.Push($entry) }
                else {
                    $bytes += ([System.IO.FileInfo]::new($entry)).Length
                    if ($bytes -gt $MaxBytes) { $result.Reason = 'too_large'; $result.Count = $count; $result.Bytes = $bytes; return $result }
                }
            }
        }
    } catch {
        $result.Reason = 'unreadable'; $result.Count = $count; $result.Bytes = $bytes; return $result
    }
    $result.Ok = $true; $result.Count = $count; $result.Bytes = $bytes
    return $result
}

function Get-CwcSensitiveHits {
    <# 只在名字层面判断存在性，绝不打开文件。 #>
    param([string]$Path, [string[]]$Names, [int]$MaxEntries = 20000)

    $hits = @()
    if (-not (Test-Path -LiteralPath $Path)) { return , $hits }
    $isDir = $false
    try { $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer } catch { return , $hits }

    if (-not $isDir) {
        if ($Names -contains ([System.IO.Path]::GetFileName($Path))) { $hits += [System.IO.Path]::GetFileName($Path) }
        return , $hits
    }

    # 只看目标目录的第一层：既不递归进用户项目，也避免为了"存在性"去遍历上万个文件。
    $lower = @($Names | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -File -Force -ErrorAction SilentlyContinue)) {
        $n = $f.Name.ToLowerInvariant()
        if ($lower -contains $n) {
            if ($hits.Count -lt 50) { $hits += $f.FullName }
        }
    }
    return , $hits
}

Write-Output '=== claude-windows-cleanup / privacy-audit (read-only) ==='

$now = Get-CwcTimestamp
$targets = @()
$findings = @()
$sensitiveMap = $config.privacy_audit.sensitive_names_by_target

foreach ($t in @($config.privacy_audit.targets)) {
    if ($null -eq $t) { continue }
    $expanded = Expand-CwcPath -Template ([string]$t.path)
    $norm = Get-NormalizedPath -Path $expanded
    $exists = if ($norm) { Test-Path -LiteralPath $norm } else { $false }
    $measure = if ($exists) { Measure-CwcTree -Path $norm } else { $null }
    $reparse = if ($exists) { Test-ReparseItem -Path $norm } else { $false }
    $sensitiveNames = @()
    foreach ($key in @($sensitiveMap.PSObject.Properties.Name)) {
        if ($key -eq 'default') { continue }
        if ([string]$t.id -like ($key + '*')) { $sensitiveNames = @($sensitiveMap.$key); break }
    }
    if ($sensitiveNames.Count -eq 0 -and $null -ne $sensitiveMap.default) { $sensitiveNames = @($sensitiveMap.default) }
    $hits = if ($exists -and $sensitiveNames.Count -gt 0) { Get-CwcSensitiveHits -Path $norm -Names $sensitiveNames } else { @() }

    $status = 'ABSENT'
    if ($exists) {
        if ($reparse) { $status = 'BLOCKED' }
        elseif ($null -ne $measure -and -not $measure.Ok -and $measure.Reason -eq 'unreadable') { $status = 'UNKNOWN' }
        elseif ($reparse) { $status = 'BLOCKED' }
        else { $status = 'PRESENT' }
    }

    $targets += [pscustomobject]@{
        id              = [string]$t.id
        label           = [string]$t.label
        path            = $norm
        sensitivity     = [string]$t.sensitivity
        exists          = $exists
        status          = $status
        is_reparse      = $reparse
        file_count      = if ($measure) { [int]$measure.Count } else { 0 }
        bytes           = if ($measure) { [long]$measure.Bytes } else { [long]0 }
        bytes_human     = Format-CwcBytes -Bytes $(if ($measure) { [long]$measure.Bytes } else { [long]0 })
        last_write_utc  = if ($exists) { try { (Get-Item -LiteralPath $norm -Force).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { '' } } else { '' }
        sensitive_hits  = @($hits)
        truncated       = ($null -ne $measure -and -not $measure.Ok)
        content_read    = $false
        note            = [string]$t.note
    }
}

# 运行中的相关进程（只列名字/数量，不取命令行）
$procNames = @('claude', 'chrome', 'msedge', 'code', 'cursor', 'trae', 'workbuddy')
$running = @()
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($procNames -contains $p.ProcessName.ToLowerInvariant()) {
        $running += [pscustomobject]@{ name = $p.ProcessName; id = $p.Id }
    }
}
$runningSummary = @($running | Group-Object name | ForEach-Object { [pscustomobject]@{ name = $_.Name; count = $_.Count } })

# 浏览器扩展数量（只看目录数，不读 manifest）
$extTargets = @($targets | Where-Object { $_.id -match 'extensions' })
$extensionInfo = @()
foreach ($e in $extTargets) {
    if (-not $e.exists) { continue }
    $n = -1
    try { $n = @(Get-ChildItem -LiteralPath $e.path -Directory -Force -ErrorAction Stop).Count } catch { $n = -1 }
    $extensionInfo += [pscustomobject]@{ path = $e.path; folder_count = $n; identified = $false }
}

# 风险发现（只做事实陈述，不夸大）
foreach ($t in $targets) {
    if ($t.status -ne 'PRESENT') { continue }
    if ($t.sensitive_hits.Count -gt 0) {
        $findings += [pscustomobject]@{
            id = 'sensitive-files-' + $t.id
            severity = if (@($t.sensitive_hits | Where-Object { (Split-Path -Leaf $_) -ieq '.credentials.json' }).Count -gt 0) { 'CRITICAL' } else { 'MEDIUM' }
            statement = ('{0} 下存在 {1} 个敏感文件名（仅名称，未读取内容）' -f $t.label, $t.sensitive_hits.Count)
            evidence = @($t.sensitive_hits | ForEach-Object { Split-Path -Leaf $_ } | Select-Object -Unique)
        }
    }
    if ($t.id -eq 'claude_code_projects' -and $t.exists) {
        $findings += [pscustomobject]@{
            id = 'plaintext-session-records'
            severity = 'HIGH'
            statement = '本地存在项目会话记录目录；官方文档说明其中可能含代码片段、命令输出与配置，属明文风险'
            evidence = @($t.path)
        }
    }
    if ($t.id -eq 'chrome_user_data' -and $t.exists) {
        $findings += [pscustomobject]@{
            id = 'browser-shared-data'
            severity = 'MEDIUM'
            statement = 'Chrome 用户数据目录存在，内含与所有网站共享的 Cookie/本地存储；本 Skill 不读取、不清理'
            evidence = @($t.path)
        }
    }
}
foreach ($t in $targets) {
    if ($t.status -eq 'UNKNOWN') {
        $findings += [pscustomobject]@{ id = 'unreadable-' + $t.id; severity = 'MEDIUM'; statement = ('无法读取：{0}' -f $t.label); evidence = @($t.path) }
    }
    if ($t.is_reparse) {
        $findings += [pscustomobject]@{ id = 'reparse-' + $t.id; severity = 'MEDIUM'; statement = ('路径是重解析点，评估不完整：{0}' -f $t.label); evidence = @($t.path) }
    }
}

$logoutGuidance = @(
    '浏览器：在 claude.ai 右上角账户菜单执行"退出登录"。是否进一步清除该站点数据由你决定（Chrome 设置 → 隐私和安全 → 网站设置 → 查看权限和数据）。',
    'Chrome 扩展：打开 chrome://extensions 查看是否存在 Claude 相关扩展；若不再使用，可在扩展页自行移除。本 Skill 不代为操作。',
    'Claude Code：使用官方登录/登出流程（CLI 的账户命令或交互式退出），本 Skill 不执行、不读取凭据文件。',
    '账号被封禁：本地文件的去留不改变服务端记录；数据导出/删除请走 Anthropic 官方渠道。',
    '本项目不做反检测、指纹伪造或账号关联规避，也不修改任何硬件/设备标识。'
)

$present = @($targets | Where-Object { $_.status -eq 'PRESENT' }).Count
$unknown = @($targets | Where-Object { $_.status -eq 'UNKNOWN' }).Count
$blocked = @($targets | Where-Object { $_.status -eq 'BLOCKED' }).Count
$verdict = if ($unknown -gt 0 -or $blocked -gt 0) { 'PARTIAL' } elseif ($present -gt 0) { 'PASS' } else { 'PASS' }

$report = [ordered]@{
    schema_version = 1
    skill          = 'claude-windows-cleanup'
    skill_version  = '1.1.0'
    generated_at   = $now
    host           = $env:COMPUTERNAME
    user           = $env:USERNAME
    mode           = 'read_only_metadata'
    content_read   = $false
    targets        = $targets
    running        = $runningSummary
    extensions     = $extensionInfo
    findings       = $findings
    guidance       = $logoutGuidance
    summary        = [ordered]@{
        targets  = $targets.Count
        present  = $present
        absent   = @($targets | Where-Object { $_.status -eq 'ABSENT' }).Count
        unknown  = $unknown
        blocked  = $blocked
        findings = $findings.Count
    }
    verdict        = $verdict
    disclaimer     = '本报告只描述本地元数据；不证明任何账号仍然有效或已失效，也不代表服务端记录。'
}

$outDir = Join-Path $skillRoot 'reports'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $outDir ('privacy-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json') }
$null = Write-CwcJsonAtomic -Path $OutputPath -Object (Hide-CwcSensitive -InputObject $report)

# 人读版
$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Claude 本地数据只读隐私评估')
$md.Add('')
$md.Add(('- 生成时间：{0}' -f $now))
$md.Add('- 模式：只读元数据（未读取任何文件内容）')
$md.Add(('- 判定：**{0}**' -f $verdict))
$md.Add('')
$md.Add('| ID | 状态 | 敏感级别 | 大小 | 文件数 | 路径 |')
$md.Add('|----|------|----------|------|--------|------|')
foreach ($t in $targets) {
    $md.Add(('| {0} | {1} | {2} | {3} | {4} | `{5}` |' -f $t.id, $t.status, $t.sensitivity, $t.bytes_human, $t.file_count, $t.path))
}
$md.Add('')
$md.Add('## 风险发现')
$md.Add('')
if ($findings.Count -eq 0) { $md.Add('无。') }
foreach ($f in $findings) { $md.Add(('- **{0}**（{1}）：{2}' -f $f.severity, $f.id, $f.statement)) }
$md.Add('')
$md.Add('## 运行中的相关进程')
$md.Add('')
if ($runningSummary.Count -eq 0) { $md.Add('无。') }
foreach ($r in $runningSummary) { $md.Add(('- {0} × {1}' -f $r.name, $r.count)) }
$md.Add('')
$md.Add('## 官方退出与数据管理指引（不代为执行）')
$md.Add('')
foreach ($g in $logoutGuidance) { $md.Add(('- {0}' -f $g)) }
$md.Add('')
$md.Add('> 本报告只描述本地元数据，不证明任何账号仍然有效，也不代表 Anthropic 服务端记录的消除。')
$mdPath = Join-Path $outDir ([System.IO.Path]::GetFileNameWithoutExtension($OutputPath) + '.md')
[System.IO.File]::WriteAllLines($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("目标        : {0}（存在 {1} / 不存在 {2} / 无法判定 {3} / 阻止 {4}）" -f $targets.Count, $present, @($targets | Where-Object { $_.status -eq 'ABSENT' }).Count, $unknown, $blocked)
Write-Output ("风险发现    : {0} 条" -f $findings.Count)
Write-Output ("运行中进程  : {0}" -f ($(if ($runningSummary.Count -gt 0) { ($runningSummary | ForEach-Object { $_.name }) -join ',' } else { '无' })))
Write-Output ("判定        : {0}" -f $verdict)
Write-Output ("报告        : {0}" -f $OutputPath)
Write-Output ("人读版      : {0}" -f $mdPath)

Write-CwcAudit -SkillRoot $skillRoot -Action 'privacy_audit' -Fields @{ report = $OutputPath; verdict = $verdict; findings = $findings.Count }

exit 0
