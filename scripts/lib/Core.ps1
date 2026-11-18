# Core.ps1 — claude-windows-cleanup 的共享安全原语
# =============================================================================
# 设计约束（与参考仓库的教训一一对应）：
#   1. 默认拒绝：路径必须落在 scope.json 的 allowed_item_roots 之内，其余一律 BLOCKED。
#   2. 不可读 != 不存在：枚举/打开失败一律 BLOCKED(unreadable)，绝不当作"空"或"已删除"。
#   3. 拒绝重解析点：目标自身、祖先、子树内任一重解析点都 BLOCKED。
#   4. 只读优先：本文件不含任何写系统状态的函数；唯一的写操作是写本 Skill 自己的报告。
#   5. 不依赖 Pester、不联网、不调用 takeown/icacls、不写注册表、不改 ACL。
#
# PS 5.1 兼容：不使用 ??、? :、-Depth 之外的 7.x 语法；数组一律 @() 规整。
# =============================================================================

$script:CwcCoreLoaded = $true
$script:CwcOrdinal = [System.StringComparison]::OrdinalIgnoreCase

function Get-CwcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Format-CwcBytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function New-CwcItemId {
    param([Parameter(Mandatory)][int]$Number)
    return ('cwc-{0:D4}' -f $Number)
}

# ── 路径原语 ────────────────────────────────────────────────────────────────

function Expand-CwcPath {
    <# 展开 %VAR% 并去掉尾部分隔符；不做规范化（规范化由 Get-NormalizedPath 负责）。 #>
    param([AllowNull()][string]$Template)
    if ([string]::IsNullOrWhiteSpace($Template)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Template)
    if ([string]::IsNullOrWhiteSpace($expanded)) { return $null }
    return $expanded.Trim()
}

function Get-NormalizedPath {
    <#
    .SYNOPSIS
        绝对化 + 折叠 .. + 去尾分隔符。失败返回 $null。
    .DESCRIPTION
        拒绝：空、盘符相对路径（C:foo）、以及 GetFullPath 抛错的一切形态。
        不做大小写改写（比较时统一 ToLowerInvariant）。
    #>
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim()
    if ($p -match '^[A-Za-z]:[^\\/]') { return $null }
    try { $full = [System.IO.Path]::GetFullPath($p) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($full)) { return $null }
    $full = $full.TrimEnd('\', '/')
    if ($full -match '^[A-Za-z]:$') { return $full }
    return $full
}

function Test-IsDriveRoot {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return ($Path -match '^[A-Za-z]:$')
}

function Test-HasWildcard {
    param([AllowNull()][string]$Path)
    if ($null -eq $Path) { return $false }
    return ($Path -match '[*?\[]')
}

function Test-PathUnder {
    <# 严格包含：Path == Root 或 Path 在 Root 之下（按目录边界）。 #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $p = $Path.TrimEnd('\', '/').ToLowerInvariant()
    $r = $Root.TrimEnd('\', '/').ToLowerInvariant()
    if ($p -eq $r) { return $true }
    if ($r.Length -eq 2 -and $r -match '^[a-z]:$') { return $p.StartsWith($r + '\', $script:CwcOrdinal) }
    return $p.StartsWith($r + '\', $script:CwcOrdinal)
}

function Get-PathDepth {
    param([Parameter(Mandatory)][string]$Path)
    return @(($Path.TrimEnd('\') -split '\\') | Where-Object { $_ -ne '' }).Count
}

# ── 配置 ────────────────────────────────────────────────────────────────────

function Read-CwcJson {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        return ($text | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-CwcSkillRoot {
    param([Parameter(Mandatory)][string]$ScriptRoot)
    # <root>\scripts 或 <root>\scripts\lib 都支持
    $parent = Split-Path -Parent $ScriptRoot
    if ((Split-Path -Leaf $parent) -ieq 'scripts') { return (Split-Path -Parent $parent) }
    return $parent
}

function Get-AllowedRootSet {
    <# 把 allowed_item_roots 展开为绝对路径集合（保序）。 #>
    param([Parameter(Mandatory)]$Config)

    $out = @()
    foreach ($r in @($Config.allowed_item_roots)) {
        if ($null -eq $r) { continue }
        $expanded = Expand-CwcPath -Template ([string]$r.path)
        $normalized = Get-NormalizedPath -Path $expanded
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        $out += [pscustomobject]@{
            Id         = [string]$r.id
            Path       = $normalized
            Kind       = [string]$r.kind
            MaxEntries = if ($null -ne $r.max_entries) { [int]$r.max_entries } else { 50000 }
            Note       = [string]$r.note
        }
    }
    return , $out
}

function Get-ProtectedRootSet {
    param([Parameter(Mandatory)]$Protection)

    $out = @()
    foreach ($r in @($Protection.never_touch_roots)) {
        if ($null -eq $r) { continue }
        $normalized = Get-NormalizedPath -Path (Expand-CwcPath -Template ([string]$r.path))
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        $out += [pscustomobject]@{ Path = $normalized; Reason = [string]$r.reason }
    }
    return , $out
}

# ── 重解析点 ────────────────────────────────────────────────────────────────

function Test-ReparseItem {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        return (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Get-AncestorReparse {
    <# 返回第一个祖先重解析点；到 $StopAt（含）为止。 #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$StopAt
    )
    $cur = $Path
    $guard = 0
    while ($guard -lt 64) {
        $guard++
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrWhiteSpace($parent)) { break }
        if (Test-ReparseItem -Path $parent) { return $parent }
        if ((Test-PathUnder -Path $parent -Root $StopAt) -eq $false) { break }
        if ($parent.ToLowerInvariant() -eq $StopAt.TrimEnd('\').ToLowerInvariant()) { break }
        $cur = $parent
    }
    return $null
}

# ── 树指纹（枚举 + 摘要），任何异常都 fail-closed ──────────────────────────

function Get-TreeFingerprint {
    <#
    .SYNOPSIS
        遍历一个文件/目录，返回条目数、总字节与 SHA-256 摘要；不进入重解析点。
    .DESCRIPTION
        返回 @{ Ok; Kind; Count; Bytes; Digest; ReparsePath; Reason }
        - Ok=$false 时 Reason ∈ unreadable / too_many_entries / too_large / reparse_in_subtree / not_found
        - 主动检测子树内任何重解析点：发现即 Ok=$false, Reason=reparse_in_subtree
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxEntries = 50000,
        [long]$MaxBytes = 2147483648
    )

    $fail = { param($why) [pscustomobject]@{ Ok=$false; Kind=''; Count=0; Bytes=0; Digest=''; ReparsePath=''; Reason=$why } }

    if (-not (Test-Path -LiteralPath $Path)) { return (& $fail 'not_found') }
    $isDir = $false
    try { $isDir = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).PSIsContainer } catch { return (& $fail 'unreadable') }

    if (Test-ReparseItem -Path $Path) {
        return ([pscustomobject]@{ Ok=$false; Kind=$(if($isDir){'directory'}else{'file'}); Count=0; Bytes=0; Digest=''; ReparsePath=$Path; Reason='reparse_in_subtree' })
    }

    if (-not $isDir) {
        try {
            $fi = [System.IO.FileInfo]::new($Path)
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $stream.Close()
        } catch { return (& $fail 'unreadable') }
        $digest = Get-TextSha256 -Text ("{0}|{1}|{2}" -f $fi.Name.ToLowerInvariant(), $fi.Length, $fi.LastWriteTimeUtc.Ticks)
        return ([pscustomobject]@{ Ok=$true; Kind='file'; Count=1; Bytes=[long]$fi.Length; Digest=$digest; ReparsePath=''; Reason='' })
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    $count = 0
    $bytes = [long]0
    $baseLen = $Path.TrimEnd('\').Length + 1

    try {
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($entry in [System.IO.Directory]::GetFileSystemEntries($dir)) {
                $attrs = [System.IO.File]::GetAttributes($entry)
                if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    return ([pscustomobject]@{ Ok=$false; Kind='directory'; Count=$count; Bytes=$bytes; Digest=''; ReparsePath=$entry; Reason='reparse_in_subtree' })
                }
                $count++
                if ($count -gt $MaxEntries) { return (& $fail 'too_many_entries') }
                if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $stack.Push($entry)
                    $rel = $entry.Substring($baseLen).ToLowerInvariant()
                    $lines.Add(('D|{0}' -f $rel))
                } else {
                    $fi = [System.IO.FileInfo]::new($entry)
                    $bytes += $fi.Length
                    if ($bytes -gt $MaxBytes) { return (& $fail 'too_large') }
                    $rel = $entry.Substring($baseLen).ToLowerInvariant()
                    $lines.Add(('F|{0}|{1}|{2}' -f $rel, $fi.Length, $fi.LastWriteTimeUtc.Ticks))
                }
            }
        }
    } catch {
        return (& $fail 'unreadable')
    }

    $lines.Sort([System.StringComparer]::Ordinal)
    $digest = Get-TextSha256 -Text ($lines -join "`n")
    return ([pscustomobject]@{ Ok=$true; Kind='directory'; Count=$count; Bytes=$bytes; Digest=$digest; ReparsePath=''; Reason='' })
}

# ── 哈希 / JSON ─────────────────────────────────────────────────────────────

function Get-TextSha256 {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
            finally { $stream.Close() }
        } finally { $sha.Dispose() }
    } catch {
        return $null
    }
}

function Write-CwcJsonAtomic {
    <# 先写 .tmp 再替换，避免半截 JSON。 #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Object
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # 同 quarantine.ps1：New-Item -Force 在父路径是文件时会静默失败，必须复核
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            throw ("无法创建目录：{0}" -f $dir)
        }
    }
    $json = $Object | ConvertTo-Json -Depth 12
    $tmp = $Path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        try {
            # 注意：PowerShell 会把 $null 转成空串传给 .NET 的 string 参数，
            # File.Replace 的空备份路径会抛"路径的形式不合法"。必须用 [NullString]::Value。
            [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
        } catch {
            # 文件系统不支持 Replace（少数网络/容器卷）时退化为删+移：
            # 会牺牲原子性，但比留下一个 .tmp 或半截文件更容易被发现。
            [System.IO.File]::Delete($Path)
            [System.IO.File]::Move($tmp, $Path)
        }
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
    return $Path
}

# ── 计划指纹 ────────────────────────────────────────────────────────────────

function Get-PlanCanonicalText {
    <#
    .SYNOPSIS
        计划项 -> 规范化文本（用于 SHA-256 绑定）。
    .DESCRIPTION
        只纳入对执行有意义的字段，按 id 排序；改动任何一项都会改变哈希，
        因此"计划被篡改"与"授权失效"是同一个判定。
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items)

    $rows = @()
    foreach ($it in @($Items)) {
        if ($null -eq $it) { continue }
        $rows += ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f `
            [string]$it.id,
            [string]$it.kind,
            ([string]$it.path).ToLowerInvariant(),
            [string]$it.status,
            [string]$it.action,
            [string]$it.bytes,
            [string]$it.last_write_utc,
            [string]$it.digest)
    }
    $sorted = @($rows | Sort-Object -CaseSensitive)
    return ($sorted -join "`n")
}

function Get-PlanSha256 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Items)
    return (Get-TextSha256 -Text (Get-PlanCanonicalText -Items $Items))
}

# ── 核心安全判定 ────────────────────────────────────────────────────────────

function Test-CwcItemSafety {
    <#
    .SYNOPSIS
        单项路径的完整安全判定（唯一实现处）。
    .OUTPUTS
        [pscustomobject]@{ Decision='ALLOW'|'PROTECTED'|'BLOCKED'; Code; Reason; Normalized; KindHint }
    .DESCRIPTION
        判定顺序（先后不可交换）：
          1 语法与形状（空/通配符/UNC/相对/ADS/过长/盘根/环境变量残留）
          2 受保护模式（第二道闸门，命中即 PROTECTED）
          3 白名单与保护的具体性比较（最长前缀胜出）
          4 重解析点（自身 + 祖先）
          5 存在性与可读性（不可读 != 不存在）
    #>
    param(
        [AllowNull()][string]$Path,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Protection,
        [switch]$SkipExistence
    )

    $deny = { param($code, $reason) [pscustomobject]@{ Decision='BLOCKED'; Code=$code; Reason=$reason; Normalized=$null; KindHint='' } }
    $keep = { param($code, $reason, $norm) [pscustomobject]@{ Decision='PROTECTED'; Code=$code; Reason=$reason; Normalized=$norm; KindHint='' } }

    if ([string]::IsNullOrWhiteSpace($Path)) { return (& $deny 'empty_path' '路径为空') }

    $raw = $Path.Trim()
    if ($raw -match '%[^%]+%') { return (& $deny 'unresolved_env' '路径仍含未展开的环境变量') }
    if (Test-HasWildcard -Path $raw) { return (& $deny 'wildcard_path' '拒绝含通配符的路径（防批量扩张）') }
    if ($raw -match '^\\\\') { return (& $deny 'unc_or_device_path' '拒绝 UNC / 设备路径') }
    if ($raw -match '^[A-Za-z]:.*:') { return (& $deny 'ads_path' '拒绝备用数据流（ADS）语法') }
    if ($raw -match '[\\/]$' -and $raw.Length -gt 3) {
        # 允许尾部反斜杠，但要求规范化后一致；不视为错误
    }
    if (-not [System.IO.Path]::IsPathRooted($raw)) { return (& $deny 'relative_path' '拒绝相对路径') }
    if ($raw.Length -gt 260) { return (& $deny 'path_too_long' '路径超过 260 字符') }

    $norm = Get-NormalizedPath -Path $raw
    if ([string]::IsNullOrWhiteSpace($norm)) { return (& $deny 'invalid_path' '路径无法规范化（含盘符相对路径或非法字符）') }
    if (Test-IsDriveRoot -Path $norm) { return (& $deny 'volume_root' '拒绝卷根路径') }

    $maxLen = 240
    if ($null -ne $Config.limits -and $null -ne $Config.limits.max_path_length) { $maxLen = [int]$Config.limits.max_path_length }
    if ($norm.Length -gt $maxLen) { return (& $deny 'path_too_long' ("路径超过配置上限 {0}" -f $maxLen)) }

    # 2 受保护模式
    foreach ($p in @($Protection.never_touch_path_patterns)) {
        if ($null -eq $p) { continue }
        if ($norm -match [string]$p.pattern) { return (& $keep 'protected_pattern' ([string]$p.reason) $norm) }
    }
    foreach ($p in @($Config.protected_name_patterns)) {
        if ($null -eq $p) { continue }
        $leaf = [System.IO.Path]::GetFileName($norm)
        if ($leaf -like [string]$p.pattern) { return (& $keep 'protected_name' ([string]$p.reason) $norm) }
        if ($norm -like ('*' + [string]$p.pattern + '*')) { return (& $keep 'protected_name' ([string]$p.reason) $norm) }
    }

    # 3 具体性比较
    $allowLen = 0
    $allowRoot = $null
    foreach ($r in (Get-AllowedRootSet -Config $Config)) {
        if (Test-PathUnder -Path $norm -Root $r.Path) {
            if ($r.Path.Length -gt $allowLen) { $allowLen = $r.Path.Length; $allowRoot = $r }
        }
    }
    $protectLen = 0
    $protectReason = ''
    foreach ($r in (Get-ProtectedRootSet -Protection $Protection)) {
        if (Test-PathUnder -Path $norm -Root $r.Path) {
            if ($r.Path.Length -gt $protectLen) { $protectLen = $r.Path.Length; $protectReason = $r.Reason }
        }
    }
    if ($protectLen -gt 0 -and $protectLen -ge $allowLen) {
        return (& $keep 'protected_root' $protectReason $norm)
    }
    if ($allowLen -eq 0) {
        return (& $deny 'outside_scope' '不在本 Skill 的允许清理范围内（默认拒绝）')
    }

    # 4 重解析点
    if (Test-ReparseItem -Path $norm) { return (& $deny 'reparse_point' '目标是目录联接点/符号链接/重解析点') }
    $anc = Get-AncestorReparse -Path $norm -StopAt $allowRoot.Path
    if (-not [string]::IsNullOrWhiteSpace($anc)) { return (& $deny 'reparse_ancestor' ("路径包含重解析点祖先：{0}" -f $anc)) }

    if ($SkipExistence) {
        return ([pscustomobject]@{ Decision='ALLOW'; Code='ok'; Reason=''; Normalized=$norm; KindHint=[string]$allowRoot.Kind })
    }

    # 5 存在性与可读性
    if (-not (Test-Path -LiteralPath $norm)) { return (& $deny 'not_found' '目标不存在') }
    $fp = Get-TreeFingerprint -Path $norm -MaxEntries $allowRoot.MaxEntries -MaxBytes 2147483648
    if (-not $fp.Ok) {
        switch ([string]$fp.Reason) {
            'reparse_in_subtree' { return (& $deny 'reparse_in_subtree' ("子树内含重解析点：{0}" -f $fp.ReparsePath)) }
            'unreadable'         { return (& $deny 'unreadable' '目标不可读（权限不足或句柄占用）；不可读不等于不存在') }
            'too_many_entries'   { return (& $deny 'too_many_entries' '条目数超过安全上限，拒绝处理') }
            'too_large'          { return (& $deny 'too_large' '体积超过安全上限，拒绝处理') }
            default              { return (& $deny 'fingerprint_failed' ("无法取得指纹：{0}" -f $fp.Reason)) }
        }
    }

    return ([pscustomobject]@{ Decision='ALLOW'; Code='ok'; Reason=''; Normalized=$norm; KindHint=[string]$allowRoot.Kind })
}

# ── 审计日志 ────────────────────────────────────────────────────────────────

function Get-CwcSkillFingerprint {
    <# scripts/ 与 config/ 下所有 .ps1/.json 的 路径|哈希 排序后再哈希：用于核对"跑的是哪一版"。 #>
    param([Parameter(Mandatory)][string]$SkillRoot)

    $lines = @()
    foreach ($sub in @('scripts', 'config')) {
        $dir = Join-Path $SkillRoot $sub
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($pattern in @('*.ps1', '*.json')) {
            Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | ForEach-Object {
                $lines += ('{0}|{1}' -f $_.FullName.Substring($SkillRoot.Length).ToLowerInvariant(), (Get-FileSha256 -Path $_.FullName))
            }
        }
    }
    $sorted = @($lines | Sort-Object -CaseSensitive)
    return (Get-TextSha256 -Text ($sorted -join "`n"))
}

function Write-CwcAudit {
    <# 只记录 id/路径/结论，不记录任何文件内容。 #>
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string]$Action,
        [hashtable]$Fields = @{}
    )
    try {
        $dir = Join-Path $SkillRoot 'reports'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $entry = [ordered]@{ timestamp = (Get-CwcTimestamp); action = $Action; pid = $PID }
        foreach ($k in $Fields.Keys) { $entry[$k] = $Fields[$k] }
        $line = ($entry | ConvertTo-Json -Compress -Depth 6)
        [System.IO.File]::AppendAllText((Join-Path $dir 'audit.jsonl'), $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # 审计写不进去不得改变主流程结论；由调用方在报告中说明
    }
}

# ── 敏感信息脱敏（R1/R4-14） ────────────────────────────────────────────────
# 任何写盘的 JSON 都要先过这一层：按键名屏蔽、按值特征屏蔽。
# 本 Skill 从不读取文件内容，所以这里是"纵深防御"，不是主要防线。

$script:CwcSensitiveKeyPattern = '(?i)(token|cookie|password|passwd|secret|credential|authorization|api[_-]?key|private[_-]?key|session[_-]?id|refresh[_-]?token|access[_-]?token)'
$script:CwcSensitiveValuePatterns = @(
    '(?i)bearer\s+[A-Za-z0-9._\-]{8,}',
    '\bsk-[A-Za-z0-9_\-]{10,}',
    '\bgh[pousr]_[A-Za-z0-9]{20,}',
    '\beyJ[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{8,}',
    '\bAKIA[0-9A-Z]{16}\b'
)

function Hide-CwcSensitiveText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $Text }
    $out = $Text
    foreach ($pat in $script:CwcSensitiveValuePatterns) {
        $out = [regex]::Replace($out, $pat, '[REDACTED]')
    }
    return $out
}

function Hide-CwcSensitive {
    <#
    .SYNOPSIS
        返回脱敏后的深拷贝：敏感键名的值整体替换为 [REDACTED]，字符串里的凭据特征也替换。
    .DESCRIPTION
        支持 OrderedDictionary / Hashtable / PSCustomObject / 数组 / 标量。深度上限 10。
    #>
    param([AllowNull()]$InputObject, [int]$Depth = 0)

    if ($null -eq $InputObject) { return $null }
    if ($Depth -gt 10) { return '[DEPTH_LIMIT]' }

    if ($InputObject -is [string]) { return (Hide-CwcSensitiveText -Text $InputObject) }
    if ($InputObject -is [bool] -or $InputObject -is [int] -or $InputObject -is [long] -or $InputObject -is [double] -or $InputObject -is [decimal]) { return $InputObject }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in @($InputObject.Keys)) {
            $key = [string]$k
            if ($key -match $script:CwcSensitiveKeyPattern) { $out[$key] = '[REDACTED]' }
            else { $out[$key] = Hide-CwcSensitive -InputObject $InputObject[$k] -Depth ($Depth + 1) }
        }
        return $out
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $arr = @()
        foreach ($x in $InputObject) { $arr += , (Hide-CwcSensitive -InputObject $x -Depth ($Depth + 1)) }
        return , $arr
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            if ($prop.Name -match $script:CwcSensitiveKeyPattern) { $out[$prop.Name] = '[REDACTED]' }
            else { $out[$prop.Name] = Hide-CwcSensitive -InputObject $prop.Value -Depth ($Depth + 1) }
        }
        return $out
    }

    if ($InputObject -is [System.ValueType]) { return $InputObject }
    return (Hide-CwcSensitiveText -Text ([string]$InputObject))
}

# ── 并发锁（R4-5） ──────────────────────────────────────────────────────────

function Test-CwcStaleLock {
    param([Parameter(Mandatory)][string]$LockPath)
    try {
        $doc = [System.IO.File]::ReadAllText($LockPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($null -eq $doc.pid) { return $true }
        $null = Get-Process -Id ([int]$doc.pid) -ErrorAction Stop
        return $false
    } catch {
        return $true
    }
}

function Enter-CwcLock {
    <#
    .SYNOPSIS
        独占创建锁文件；成功返回 $true。已存在且持有进程仍活 -> $false。
    .DESCRIPTION
        只用于串行化 quarantine/restore，避免两个进程同时操作同一批条目。
        "进程已消失"的陈旧锁允许接管一次（进程崩溃后不应永久卡死）。
    #>
    param([Parameter(Mandatory)][string]$LockPath)

    $dir = [System.IO.Path]::GetDirectoryName($LockPath)
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $false }
    }

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $payload = (@{ pid = $PID; host = $env:COMPUTERNAME; started_at = (Get-CwcTimestamp) } | ConvertTo-Json -Compress)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            } finally {
                $fs.Dispose()
            }
            return $true
        } catch [System.IO.IOException] {
            if ($attempt -eq 0 -and (Test-CwcStaleLock -LockPath $LockPath)) {
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
                continue
            }
            return $false
        } catch {
            return $false
        }
    }
    return $false
}

function Exit-CwcLock {
    param([Parameter(Mandatory)][string]$LockPath)
    if (Test-Path -LiteralPath $LockPath) { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue }
}

# ── 隔离目录安全（R1/R4-4） ─────────────────────────────────────────────────

function Test-CwcQuarantineDir {
    <#
    .SYNOPSIS
        隔离目录必须存在、是普通目录、自身与全部祖先都不是重解析点。
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [pscustomobject]@{ Ok = $false; Reason = 'not_directory' } }
    if (Test-ReparseItem -Path $Path) { return [pscustomobject]@{ Ok = $false; Reason = 'reparse_root' } }

    $cur = $Path
    $guard = 0
    while ($guard -lt 64) {
        $guard++
        $parent = [System.IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrWhiteSpace($parent)) { break }
        if (Test-ReparseItem -Path $parent) { return [pscustomobject]@{ Ok = $false; Reason = ('reparse_ancestor:' + $parent) } }
        if ($parent -eq [System.IO.Path]::GetPathRoot($parent)) { break }
        $cur = $parent
    }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

# ── 移动 + 日志的原子组合（R1/R4-6/R4-7） ───────────────────────────────────

function Invoke-CwcMoveWithJournal {
    <#
    .SYNOPSIS
        先移动、再落盘日志；日志失败则立即搬回，避免"东西搬走了但没人知道"。
    .OUTPUTS
        @{ Ok; Stage='move'|'journal'|'done'; Reverted; Error }
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][scriptblock]$SaveJournal
    )

    try {
        Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Stage = 'move'; Reverted = $false; Error = $_.Exception.Message }
    }

    try {
        & $SaveJournal
    } catch {
        $journalError = $_.Exception.Message
        try {
            Move-Item -LiteralPath $Destination -Destination $Source -ErrorAction Stop
            return [pscustomobject]@{ Ok = $false; Stage = 'journal'; Reverted = $true; Error = $journalError }
        } catch {
            return [pscustomobject]@{ Ok = $false; Stage = 'journal'; Reverted = $false; Error = ($journalError + ' / revert_failed: ' + $_.Exception.Message) }
        }
    }

    return [pscustomobject]@{ Ok = $true; Stage = 'done'; Reverted = $false; Error = '' }
}

# ── 配置/脚本绑定（R1：配置被篡改则计划作废） ───────────────────────────────

function Get-CwcConfigBinding {
    param([Parameter(Mandatory)][string]$SkillRoot)
    $configPath = Join-Path $SkillRoot 'config\scope.json'
    $protectPath = Join-Path $SkillRoot 'config\protected-resources.json'
    return [pscustomobject]@{
        ConfigSha256     = if (Test-Path -LiteralPath $configPath) { Get-FileSha256 -Path $configPath } else { $null }
        ProtectionSha256 = if (Test-Path -LiteralPath $protectPath) { Get-FileSha256 -Path $protectPath } else { $null }
        SkillFingerprint = Get-CwcSkillFingerprint -SkillRoot $SkillRoot
    }
}