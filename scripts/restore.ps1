# restore.ps1 — 从隔离区原样搬回（V1.1：支持崩溃对账）
# 用法：
#   .\restore.ps1 -Journal <journal.json>              # 干跑
#   .\restore.ps1 -Journal <journal.json> -Execute
#   .\restore.ps1 -Journal <journal.json> -Reconcile -Execute   # 含"planned 但已移动"的崩溃残留
# 退出码：0=成功；2=拒绝（冲突/哈希不符）；3=输入缺失；5=中途失败（已停止）

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Journal,
    [switch]$Reconcile,
    [switch]$Execute
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$config = Read-CwcJson -Path (Join-Path $skillRoot 'config\scope.json')
$protection = Read-CwcJson -Path (Join-Path $skillRoot 'config\protected-resources.json')
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; exit 3 }
if (-not (Test-Path -LiteralPath $Journal)) { Write-Error "日志不存在：$Journal"; exit 3 }

$doc = Read-CwcJson -Path $Journal
if ($null -eq $doc) { Write-Error '日志无法解析'; exit 3 }

# 可恢复集合：已移动的；以及（-Reconcile 时）"计划移动、目标已在隔离区、原路径已消失"的崩溃残留
$restorable = @()
$orphans = @()
foreach ($e in @($doc.entries)) {
    if ($null -eq $e) { continue }
    $state = [string]$e.state
    if ((@('moved', 'moved_unverified', 'restore_failed')) -contains $state) { $restorable += $e; continue }
    if ($state -eq 'planned' -and $Reconcile) {
        $pd = [string]$e.planned_dest
        if (-not [string]::IsNullOrWhiteSpace($pd) -and (Test-Path -LiteralPath $pd) -and -not (Test-Path -LiteralPath ([string]$e.original_path))) {
            $e | Add-Member -NotePropertyName reconciled -NotePropertyValue $true -Force
            $restorable += $e
        }
    }
}

if ($Reconcile) {
    # 隔离区里存在、但日志里没有归属的条目：只报告，绝不自动动
    $runDir = [string]$doc.quarantine_run
    if (-not [string]::IsNullOrWhiteSpace($runDir) -and (Test-Path -LiteralPath $runDir)) {
        $known = @{}
        foreach ($e in @($doc.entries)) { if ($e.moved_to) { $known[[string]$e.moved_to.ToLowerInvariant()] = $true } }
        foreach ($child in @(Get-ChildItem -LiteralPath $runDir -Force -ErrorAction SilentlyContinue)) {
            if (-not $known.ContainsKey($child.FullName.ToLowerInvariant())) { $orphans += $child.FullName }
        }
    }
}

if (-not $Execute) {
    Write-Output '=== restore / DRY-RUN（不会移动任何文件） ==='
    Write-Output ("日志      : {0}" -f $Journal)
    Write-Output ("运行 ID   : {0}" -f [string]$doc.run_id)
    Write-Output ("结果      : {0}" -f [string]$doc.result)
    Write-Output ''
    if ($restorable.Count -eq 0) { Write-Output '没有可恢复的条目。' }
    foreach ($e in $restorable) {
        $src = [string]$e.moved_to
        if ($e.reconciled) { $src = [string]$e.planned_dest }
        $dst = [string]$e.original_path
        Write-Output ("  {0}  {1}{2}  source_exists={3}  target_free={4}" -f $e.id, $e.state, $(if ($e.reconciled) { '(reconciled)' } else { '' }), (Test-Path -LiteralPath $src), (-not (Test-Path -LiteralPath $dst)))
        Write-Output ("      {0}  ->  {1}" -f $src, $dst)
    }
    if ($orphans.Count -gt 0) {
        Write-Output ''
        Write-Output ("隔离区存在 {0} 个无法对账的条目（需人工确认，本工具不会动）：" -f $orphans.Count)
        foreach ($o in $orphans) { Write-Output ("  {0}" -f $o) }
    }
    Write-Output ''
    Write-Output 'DRY-RUN 结束：未改动任何文件。'
    exit 0
}

$lockPath = Join-Path (Join-Path $skillRoot 'manifests') '.restore.lock'
if (-not (Enter-CwcLock -LockPath $lockPath)) {
    Write-Error '已有另一个恢复进程在运行，已拒绝。'
    exit 2
}

try {
    Write-Output '=== restore / EXECUTE ==='
    $fatal = $false
    $restored = 0

    foreach ($e in $restorable) {
        $src = [string]$e.moved_to
        if ($e.reconciled) { $src = [string]$e.planned_dest }
        $dst = [string]$e.original_path
        $expected = [string]$e.digest

        if ([string]::IsNullOrWhiteSpace($src) -or -not (Test-Path -LiteralPath $src)) {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue 'source_missing' -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }
        if (Test-Path -LiteralPath $dst) {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue 'target_occupied' -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }

        $shape = Test-CwcItemSafety -Path $dst -Config $config -Protection $protection -SkipExistence
        if ($shape.Decision -ne 'ALLOW') {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue ('target_unsafe:{0}:{1}' -f $shape.Decision, $shape.Code) -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }

        $parent = [System.IO.Path]::GetDirectoryName($dst)
        if (-not (Test-Path -LiteralPath $parent)) {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue 'parent_missing' -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }
        # 目标父链在恢复时同样不能有重解析点，否则会搬进别人的目录
        $anc = Get-AncestorReparse -Path $dst -StopAt ([System.IO.Path]::GetPathRoot($dst))
        if (-not [string]::IsNullOrWhiteSpace($anc)) {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue ('target_reparse_ancestor:' + $anc) -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }

        $pre = Get-TreeFingerprint -Path $src -MaxEntries 50000 -MaxBytes 2147483648
        if (-not $pre.Ok -or [string]$pre.Digest -ne $expected) {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue 'quarantine_digest_mismatch' -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }

        try {
            Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
        } catch {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue ('move_failed: ' + $_.Exception.Message) -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }

        $post = Get-TreeFingerprint -Path $dst -MaxEntries 50000 -MaxBytes 2147483648
        if (-not $post.Ok -or [string]$post.Digest -ne $expected) {
            $e | Add-Member -NotePropertyName restore_error -NotePropertyValue 'post_digest_mismatch' -Force; $e | Add-Member -NotePropertyName restore_failed_at -NotePropertyValue (Get-CwcTimestamp) -Force; $fatal = $true; break
        }

        $e.state = 'restored'
        $e | Add-Member -NotePropertyName restored_at -NotePropertyValue (Get-CwcTimestamp) -Force
        $restored++
        $doc.entries = @($doc.entries)
        $null = Write-CwcJsonAtomic -Path $Journal -Object (Hide-CwcSensitive -InputObject $doc)
        Write-Output ("  {0}  已恢复 -> {1}" -f $e.id, $dst)
    }

    $doc.entries = @($doc.entries)
    if ($fatal) {
        $doc | Add-Member -NotePropertyName restore_result -NotePropertyValue 'partial' -Force
        $null = Write-CwcJsonAtomic -Path $Journal -Object (Hide-CwcSensitive -InputObject $doc)
        Write-Output ''
        Write-Output '恢复中止：后续条目未处理。日志已记录失败原因。'
        Write-CwcAudit -SkillRoot $skillRoot -Action 'restore_failed' -Fields @{ journal = $Journal }
        exit 5
    }

    $doc | Add-Member -NotePropertyName restore_result -NotePropertyValue 'completed' -Force
    $null = Write-CwcJsonAtomic -Path $Journal -Object (Hide-CwcSensitive -InputObject $doc)
    Write-Output ''
    Write-Output ("完成：{0} 项已原样恢复。" -f $restored)
    if ($orphans.Count -gt 0) {
        Write-Output ("注意：隔离区仍有 {0} 个未对账条目，需人工确认。" -f $orphans.Count)
    }
    Write-CwcAudit -SkillRoot $skillRoot -Action 'restore_completed' -Fields @{ journal = $Journal; restored = $restored }
    exit 0
} finally {
    Exit-CwcLock -LockPath $lockPath
}
