# inspect.ps1 — Claude Desktop 专项只读检查
# 输出：reports/inspection-<ts>.json
# 规则：默认拒绝；不可读 != 不存在；不读文件内容；不修改任何状态。

[CmdletBinding()]
param(
    [string]$OutputPath = '',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $skillRoot 'config\scope.json'
$protectPath = Join-Path $skillRoot 'config\protected-resources.json'

if (-not (Test-Path -LiteralPath $configPath)) { Write-Error "缺少配置：$configPath"; exit 3 }
if (-not (Test-Path -LiteralPath $protectPath)) { Write-Error "缺少配置：$protectPath"; exit 3 }

$config = Read-CwcJson -Path $configPath
$protection = Read-CwcJson -Path $protectPath
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; exit 3 }

function Test-ProductName {
    param([string]$Name, $Config)
    $n = ([string]$Name).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($n)) { return $false }
    return (@($Config.product.display_name_allow) -contains $n)
}

function Test-ProductIdentity {
    param([string]$Name, [string]$Publisher, $Config)
    if (Test-ProductName -Name $Name -Config $Config) { return $true }
    $pub = ([string]$Publisher).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($pub)) { return $false }
    if (-not (@($Config.product.publisher_allow) -contains $pub)) { return $false }
    return (([string]$Name).Trim().ToLowerInvariant() -like 'claude*')
}

function Get-LiveSignals {
    param($Config)

    $signals = [ordered]@{
        uninstall_entries = @()
        appx              = @()
        processes         = @()
        services          = @()
        tasks             = @()
        probes            = @()
    }

    $uninstallPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $uninstallPaths) {
        $ok = $true
        try {
            $entries = @(Get-ItemProperty -Path $p -ErrorAction Stop)
        } catch {
            $ok = $false
            $entries = @()
        }
        $signals.probes += [pscustomobject]@{ probe = 'uninstall'; path = $p; ok = $ok }
        foreach ($e in $entries) {
            if (Test-ProductIdentity -Name $e.DisplayName -Publisher $e.Publisher -Config $Config) {
                $signals.uninstall_entries += [pscustomobject]@{
                    hive             = if ($p -like 'HKLM*') { 'HKLM' } else { 'HKCU' }
                    key              = [string]$e.PSPath
                    display_name     = [string]$e.DisplayName
                    publisher        = [string]$e.Publisher
                    version          = [string]$e.DisplayVersion
                    install_location = [string]$e.InstallLocation
                    uninstall_string = [string]$e.UninstallString
                }
            }
        }
    }

    try {
        foreach ($pkg in @(Get-AppxPackage -ErrorAction Stop)) {
            $name = [string]$pkg.Name
            $pub = [string]$pkg.Publisher
            if (Test-ProductIdentity -Name $name -Publisher $pub -Config $Config) {
                $signals.appx += [pscustomobject]@{ name = $name; publisher = $pub; install_location = [string]$pkg.InstallLocation }
            }
        }
        $signals.probes += [pscustomobject]@{ probe = 'appx'; path = '*'; ok = $true }
    } catch {
        $signals.probes += [pscustomobject]@{ probe = 'appx'; path = '*'; ok = $false }
    }

    try {
        foreach ($proc in @(Get-Process -ErrorAction Stop)) {
            if (@($Config.product.process_name_allow) -contains $proc.ProcessName.ToLowerInvariant()) {
                $signals.processes += [pscustomobject]@{ name = $proc.ProcessName; id = $proc.Id }
            }
        }
        $signals.probes += [pscustomobject]@{ probe = 'process'; path = '*'; ok = $true }
    } catch {
        $signals.probes += [pscustomobject]@{ probe = 'process'; path = '*'; ok = $false }
    }

    try {
        foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction Stop)) {
            if (@($Config.product.service_name_allow) -contains ([string]$svc.Name).ToLowerInvariant()) {
                $signals.services += [pscustomobject]@{ name = [string]$svc.Name; state = [string]$svc.State; path_name = [string]$svc.PathName }
            }
        }
        $signals.probes += [pscustomobject]@{ probe = 'service'; path = '*'; ok = $true }
    } catch {
        $signals.probes += [pscustomobject]@{ probe = 'service'; path = '*'; ok = $false }
    }

    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            if (@($Config.product.task_name_allow) -contains ([string]$t.TaskName).ToLowerInvariant()) {
                $signals.tasks += [pscustomobject]@{ name = [string]$t.TaskName; path = [string]$t.TaskPath; state = [string]$t.State }
            }
        }
        $signals.probes += [pscustomobject]@{ probe = 'task'; path = '*'; ok = $true }
    } catch {
        $signals.probes += [pscustomobject]@{ probe = 'task'; path = '*'; ok = $false }
    }

    return $signals
}

Write-Output '=== claude-windows-cleanup / inspect (read-only) ==='

$source = 'live'
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    $source = 'file'
    $doc = Read-CwcJson -Path $EvidencePath
    if ($null -eq $doc) { Write-Error "证据文件无法解析：$EvidencePath"; exit 3 }
    $signals = $doc.install_signals
    if ($null -eq $signals) { Write-Error '证据文件缺少 install_signals'; exit 3 }
} else {
    $signals = Get-LiveSignals -Config $config
}

$rootSet = Get-AllowedRootSet -Config $config
$existingRoots = @($rootSet | Where-Object { Test-Path -LiteralPath $_.Path })
$installDirRoots = @($existingRoots | Where-Object { $_.Kind -eq 'install_dir' })

$uninstallCount = @($signals.uninstall_entries).Count
$appxCount = @($signals.appx).Count
$procCount = @($signals.processes).Count
$svcCount = @($signals.services).Count
$taskCount = @($signals.tasks).Count

$installState = 'NOT_PRESENT'
$stateReason = ''
$probeFailures = @()
if ($null -ne $signals.probes) { $probeFailures = @($signals.probes | Where-Object { $null -ne $_ -and -not $_.ok }) }

if (($uninstallCount + $appxCount + $procCount + $svcCount + $taskCount) -gt 0) {
    $installState = 'INSTALLED'
    $parts = @()
    if ($uninstallCount -gt 0) { $parts += ("卸载注册项 {0}" -f $uninstallCount) }
    if ($appxCount -gt 0) { $parts += ("MSIX 包 {0}" -f $appxCount) }
    if ($procCount -gt 0) { $parts += ("运行中进程 {0}" -f $procCount) }
    if ($svcCount -gt 0) { $parts += ("服务 {0}" -f $svcCount) }
    if ($taskCount -gt 0) { $parts += ("计划任务 {0}" -f $taskCount) }
    $stateReason = '检测到安装/运行信号：' + ($parts -join '、') + '；此状态下一律不清理。'
} elseif ($probeFailures.Count -gt 0) {
    # 关键探测失败 ≠ 没有安装项：不可读不等于不存在（与 H-1/H-3 同一原则）
    $installState = 'UNKNOWN'
    $stateReason = ('关键探测失败 {0} 项（{1}）；无法排除软件仍处于安装状态，拒绝给出可执行项。' -f `
        $probeFailures.Count, (($probeFailures | ForEach-Object { [string]$_.probe }) -join ','))
} elseif ($existingRoots.Count -gt 0) {
    $installState = 'UNINSTALLED_CONFIRMED'
    $stateReason = '无卸载注册项、无 MSIX、无进程/服务/任务，但存在产品目录，判定为已卸载后的残留。'
} else {
    $installState = 'NOT_PRESENT'
    $stateReason = '未发现任何产品目录或安装信号，无可维护对象。'
}

# ── 生成条目 ────────────────────────────────────────────────────────────────
$items = @()
$index = 0
foreach ($root in $rootSet) {
    if (-not (Test-Path -LiteralPath $root.Path)) { continue }
    $index++
    $id = New-CwcItemId -Number $index
    $safety = Test-CwcItemSafety -Path $root.Path -Config $config -Protection $protection
    $evidence = @(
        ("root:{0}" -f $root.Id),
        ("kind:{0}" -f $root.Kind),
        ("install_state:{0}" -f $installState)
    )

    $status = 'BLOCKED'
    $reason = $safety.Reason
    $action = 'NONE'
    $risk = 'NONE'
    $bytes = 0
    $count = 0
    $digest = ''
    $lastWrite = ''
    $readable = $false
    $fsKind = ''
    $fpOk = $false

    if ($safety.Decision -eq 'PROTECTED') {
        $status = 'PROTECTED'
        $action = 'NONE'
        $risk = 'NONE'
    } elseif ($safety.Decision -eq 'BLOCKED') {
        $status = 'BLOCKED'
        $action = 'NONE'
        $risk = 'NONE'
    } else {
        $readable = $true
        $fp = Get-TreeFingerprint -Path $safety.Normalized -MaxEntries $root.MaxEntries -MaxBytes 2147483648
        if ($fp.Ok) {
            $fpOk = $true
            $bytes = [long]$fp.Bytes
            $count = [int]$fp.Count
            $digest = [string]$fp.Digest
            $fsKind = [string]$fp.Kind
            try { $lastWrite = (Get-Item -LiteralPath $safety.Normalized -Force).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { $lastWrite = '' }
        } else {
            $readable = $false
            $status = 'BLOCKED'
            $reason = ("指纹不可得：{0}" -f $fp.Reason)
            $action = 'NONE'
        }

        if ($fpOk) {
            if ($installState -eq 'INSTALLED' -or $installState -eq 'UNKNOWN') {
                $status = 'UNKNOWN'
                $reason = if ($installState -eq 'INSTALLED') {
                    '软件仍处于安装/运行状态，拒绝把任何目录当残留处理。'
                } else {
                    '安装状态无法确认（关键探测失败），拒绝处理。'
                }
                $action = 'NONE'
            } elseif ($root.Kind -eq 'install_dir' -and $installState -notin @('UNINSTALLED_CONFIRMED')) {
                $status = 'UNKNOWN'
                $reason = '安装状态未确认，拒绝处理安装目录。'
                $action = 'NONE'
            } else {
                $status = 'VERIFIED'
                $reason = '产品归属由配置的规范根目录确定；已确认卸载；路径在允许范围内且可读。'
                $action = 'QUARANTINE'
                $risk = 'LOW'
            }
        }
    }

    $items += [pscustomobject]@{
        id                 = $id
        root_id            = $root.Id
        kind               = $root.Kind
        path               = $root.Path
        normalized_path    = if ($safety.Normalized) { $safety.Normalized } else { $root.Path }
        status             = $status
        status_reason      = $reason
        evidence           = $evidence
        risk               = $risk
        proposed_action    = $action
        restorable         = ($action -eq 'QUARANTINE')
        approval_required  = $true
        selected           = $false
        bytes              = $bytes
        bytes_human        = Format-CwcBytes -Bytes $bytes
        file_count         = $count
        fs_kind            = $fsKind
        digest             = $digest
        last_write_utc     = $lastWrite
        readable           = $readable
        is_reparse         = (Test-ReparseItem -Path $root.Path)
        exists             = $true
    }
}

# ── 受保护资源观察（只看存在性，不进目录） ────────────────────────────────
$protectedObserved = @()
foreach ($r in (Get-ProtectedRootSet -Protection $protection)) {
    if (-not (Test-Path -LiteralPath $r.Path)) { continue }
    $childCount = -1
    try { $childCount = @(Get-ChildItem -LiteralPath $r.Path -Force -ErrorAction Stop).Count } catch { $childCount = -1 }
    $protectedObserved += [pscustomobject]@{
        path        = $r.Path
        reason      = $r.Reason
        child_count = $childCount
        content_read = $false
    }
}

$summary = [ordered]@{
    total      = $items.Count
    verified   = @($items | Where-Object { $_.status -eq 'VERIFIED' }).Count
    unknown    = @($items | Where-Object { $_.status -eq 'UNKNOWN' }).Count
    blocked    = @($items | Where-Object { $_.status -eq 'BLOCKED' }).Count
    protected  = @($items | Where-Object { $_.status -eq 'PROTECTED' }).Count
    actionable = @($items | Where-Object { $_.proposed_action -eq 'QUARANTINE' }).Count
    total_bytes = [long](($items | Measure-Object -Property bytes -Sum).Sum)
}

$report = [ordered]@{
    schema_version      = 1
    skill_name          = 'claude-windows-cleanup'
    generated_at        = (Get-CwcTimestamp)
    source              = $source
    evidence_path       = if ($source -eq 'file') { $EvidencePath } else { '' }
    host                = $env:COMPUTERNAME
    user                = $env:USERNAME
    is_admin            = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    install_state       = $installState
    install_state_reason = $stateReason
    install_signals     = $signals
    allowed_roots       = @($rootSet | ForEach-Object { [pscustomobject]@{ id = $_.Id; kind = $_.Kind; path = $_.Path; exists = (Test-Path -LiteralPath $_.Path) } })
    items               = $items
    protected_observed  = $protectedObserved
    summary             = $summary
    limits              = $config.limits
}

$outDir = Join-Path $skillRoot 'reports'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $outDir ('inspection-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}
try {
    $null = Write-CwcJsonAtomic -Path $OutputPath -Object (Hide-CwcSensitive -InputObject $report)
} catch {
    Write-Error ("检查报告写入失败：{0}" -f $_.Exception.Message)
    exit 1
}

Write-Output ("安装状态      : {0}" -f $installState)
Write-Output ("状态依据      : {0}" -f $stateReason)
Write-Output ''
if ($items.Count -eq 0) {
    Write-Output '未发现任何产品目录。'
} else {
    Write-Output ('候选条目：{0} 项（VERIFIED {1} / UNKNOWN {2} / BLOCKED {3} / PROTECTED {4}）' -f `
        $summary.total, $summary.verified, $summary.unknown, $summary.blocked, $summary.protected)
    foreach ($it in $items) {
        Write-Output ("  {0}  {1,-8} {2,-8} {3,10}  {4}" -f $it.id, $it.status, $it.kind, $it.bytes_human, $it.normalized_path)
        if ($it.status -ne 'VERIFIED') { Write-Output ("         └ {0}" -f $it.status_reason) }
    }
}
Write-Output ''
Write-Output ("受保护资源观察: {0} 项存在（未读取内容）" -f $protectedObserved.Count)
Write-Output ("检查报告已写入: {0}" -f $OutputPath)

Write-CwcAudit -SkillRoot $skillRoot -Action 'inspect' -Fields @{
    report = $OutputPath
    install_state = $installState
    verified = $summary.verified
    actionable = $summary.actionable
}

exit 0
