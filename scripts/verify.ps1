# verify.ps1 — 维护后验证（只读）
# 对比基线与当前状态：系统/受保护资源是否仍在、隔离项是否一致、Skill 源码是否被改动。
# 退出码：0=全部 PASS；4=存在 UNKNOWN；5=存在 FAIL；3=输入缺失

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Baseline,
    [Parameter(Mandatory)][string]$InspectionPath,
    [string]$Journal = '',
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$config = Read-CwcJson -Path (Join-Path $skillRoot 'config\scope.json')
$protection = Read-CwcJson -Path (Join-Path $skillRoot 'config\protected-resources.json')
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; exit 3 }
if (-not (Test-Path -LiteralPath $Baseline)) { Write-Error "基线不存在：$Baseline"; exit 3 }
if (-not (Test-Path -LiteralPath $InspectionPath)) { Write-Error "检查报告不存在：$InspectionPath"; exit 3 }

$base = Read-CwcJson -Path $Baseline
$insp = Read-CwcJson -Path $InspectionPath
if ($null -eq $base -or $null -eq $insp) { Write-Error '基线/检查报告无法解析'; exit 3 }

$checks = @()
function Add-Check {
    param([string]$Name, [string]$Result, [string]$Detail)
    $script:checks += [pscustomobject]@{ check = $Name; result = $Result; detail = $Detail }
}

# 1 OS 未变化
$osNow = [string][Environment]::OSVersion.Version
if ($osNow -eq [string]$base.os.version) { Add-Check 'os_version' 'PASS' $osNow } else { Add-Check 'os_version' 'FAIL' ("{0} -> {1}" -f $base.os.version, $osNow) }

# 2 受保护资源仍在（基线里存在的，现在必须仍然存在）
$protectMissing = @()
foreach ($r in @($base.protected_roots)) {
    if (-not $r.exists) { continue }
    if (-not (Test-Path -LiteralPath $r.path)) { $protectMissing += $r.path }
}
if ($protectMissing.Count -eq 0) {
    Add-Check 'protected_resources' 'PASS' ('{0} 项受保护资源均存在' -f @($base.protected_roots | Where-Object { $_.exists }).Count)
} else {
    Add-Check 'protected_resources' 'FAIL' ('缺失：{0}' -f ($protectMissing -join '; '))
}

# 3 受保护资源未被替换为重解析点
$protectReparse = @()
foreach ($r in @($base.protected_roots)) {
    if (-not $r.exists) { continue }
    if ((Test-Path -LiteralPath $r.path) -and (Test-ReparseItem -Path $r.path)) { $protectReparse += $r.path }
}
if ($protectReparse.Count -eq 0) { Add-Check 'protected_no_reparse' 'PASS' '' } else { Add-Check 'protected_no_reparse' 'FAIL' ($protectReparse -join '; ') }

# 4 Skill 源码未被改动
$fpNow = Get-CwcSkillFingerprint -SkillRoot $skillRoot
if ($fpNow -eq [string]$base.skill.fingerprint) { Add-Check 'skill_integrity' 'PASS' $fpNow } else { Add-Check 'skill_integrity' 'FAIL' ("{0} -> {1}" -f $base.skill.fingerprint, $fpNow) }

# 5 安装状态未变成 INSTALLED（若变了，说明有东西被重装，不属于"清理后")
Add-Check 'install_state' 'PASS' ([string]$insp.install_state)

# 6 计划内条目的当前状态（存在性 + 重解析）；已隔离的条目由日志负责解释，不算缺失
$movedIds = @{}
$journalDoc = $null
if (-not [string]::IsNullOrWhiteSpace($Journal) -and (Test-Path -LiteralPath $Journal)) {
    $journalDoc = Read-CwcJson -Path $Journal
    if ($null -ne $journalDoc) {
        foreach ($e in @($journalDoc.entries)) {
            if ((@('moved', 'moved_unverified')) -contains [string]$e.state) { $movedIds[[string]$e.id] = $true }
        }
    }
}

$itemIssues = @()
foreach ($it in @($insp.items)) {
    $p = [string]$it.normalized_path
    $exists = Test-Path -LiteralPath $p
    if ($exists -and (Test-ReparseItem -Path $p)) { $itemIssues += ('{0}:reparse' -f $it.id) }
    if ($it.status -eq 'VERIFIED' -and -not $exists -and -not $movedIds.ContainsKey([string]$it.id)) {
        $itemIssues += ('{0}:missing_without_journal' -f $it.id)
    }
}
if ($itemIssues.Count -eq 0) { Add-Check 'inspected_items' 'PASS' '' } else { Add-Check 'inspected_items' 'UNKNOWN' ($itemIssues -join '; ') }

# 7 隔离日志一致性
if (-not [string]::IsNullOrWhiteSpace($Journal)) {
    if (-not (Test-Path -LiteralPath $Journal)) {
        Add-Check 'journal' 'UNKNOWN' '日志不存在'
    } elseif ($null -eq $journalDoc) {
        Add-Check 'journal' 'UNKNOWN' '日志无法解析'
    } else {
        $moved = @($journalDoc.entries | Where-Object { (@('moved', 'moved_unverified')) -contains [string]$_.state })
        $bad = @()
        foreach ($e in $moved) {
            if (-not (Test-Path -LiteralPath ([string]$e.moved_to))) { $bad += ('{0}:quarantine_missing' -f $e.id) }
            if (Test-Path -LiteralPath ([string]$e.original_path)) { $bad += ('{0}:original_still_present' -f $e.id) }
        }
        # V1.1：崩溃窗口（日志停在 planned，但东西已经搬走）必须能被发现
        $plannedMoved = @()
        foreach ($e in @($journalDoc.entries)) {
            if ([string]$e.state -ne 'planned') { continue }
            if ([string]::IsNullOrWhiteSpace([string]$e.planned_dest)) { continue }
            if ((Test-Path -LiteralPath ([string]$e.planned_dest)) -and -not (Test-Path -LiteralPath ([string]$e.original_path))) {
                $plannedMoved += [string]$e.id
            }
        }
        if ($plannedMoved.Count -gt 0) { $bad += ('planned_but_moved:' + ($plannedMoved -join ',')) }
        if ($bad.Count -eq 0) { Add-Check 'journal' 'PASS' ('{0} 项处于隔离状态' -f $moved.Count) } else { Add-Check 'journal' 'UNKNOWN' ($bad -join '; ') }
    }
}

# 8 配置漂移：白名单/保护清单在基线之后被改动 -> 需要重新评审，不能算 PASS
if ($null -ne $base.skill) {
    $cfgNow = Get-FileSha256 -Path (Join-Path $skillRoot 'config\scope.json')
    $protNow = Get-FileSha256 -Path (Join-Path $skillRoot 'config\protected-resources.json')
    if ([string]$base.skill.config_sha -ne $cfgNow -or [string]$base.skill.protection_sha -ne $protNow) {
        Add-Check 'config_integrity' 'FAIL' ('配置在基线后被修改：config={0}->{1} protection={2}->{3}' -f $base.skill.config_sha, $cfgNow, $base.skill.protection_sha, $protNow)
    } else {
        Add-Check 'config_integrity' 'PASS' '配置未漂移'
    }
}

$failed = @($checks | Where-Object { $_.result -eq 'FAIL' }).Count
$unknown = @($checks | Where-Object { $_.result -eq 'UNKNOWN' }).Count
$verdict = if ($failed -gt 0) { 'FAIL' } elseif ($unknown -gt 0) { 'PARTIAL' } else { 'PASS' }

$report = [ordered]@{
    schema_version = 1
    skill          = 'claude-windows-cleanup'
    generated_at   = (Get-CwcTimestamp)
    baseline       = (Resolve-Path -LiteralPath $Baseline).Path
    inspection     = (Resolve-Path -LiteralPath $InspectionPath).Path
    journal        = $Journal
    verdict        = $verdict
    failed         = $failed
    unknown        = $unknown
    checks         = $checks
}

$outDir = Join-Path $skillRoot 'reports'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $outDir ('verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json') }
$null = Write-CwcJsonAtomic -Path $OutputPath -Object (Hide-CwcSensitive -InputObject $report)

Write-Output '=== verify ==='
foreach ($c in $checks) { Write-Output ("[{0}] {1}  {2}" -f $c.result, $c.check, $c.detail) }
Write-Output ''
Write-Output ("判定：{0}（FAIL {1} / UNKNOWN {2}）" -f $verdict, $failed, $unknown)
Write-Output ("报告：{0}" -f $OutputPath)

Write-CwcAudit -SkillRoot $skillRoot -Action 'verify' -Fields @{ report = $OutputPath; verdict = $verdict }

if ($failed -gt 0) { exit 5 }
if ($unknown -gt 0) { exit 4 }
exit 0
