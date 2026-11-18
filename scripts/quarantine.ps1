# quarantine.ps1 — 唯一会改动文件系统的脚本：可恢复隔离（移动），绝不删除（V1.1）
# 用法：
#   .\quarantine.ps1 -Plan <plan.json>                       # 干跑，零写入
#   .\quarantine.ps1 -Plan <plan.json> -Approval <a.json> -Execute
# 退出码：0=成功；2=拒绝（未授权/篡改/状态变化/跨卷/并发/隔离根不安全）；3=输入缺失；5=执行中失败；15=持久化失败
#
# V1.1 加固：
#   - 进度锁：同一时间只允许一个执行进程
#   - 隔离根/运行目录必须是普通目录且祖先无重解析点
#   - 移动前把 planned_dest 写进日志（崩溃后仍可对账）
#   - 移动成功但日志写失败 -> 立即搬回；搬不回则写应急记录并以 15 退出

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Plan,
    [string]$Approval = '',
    [switch]$Execute,
    [string]$QuarantineRoot = '',
    [string]$JournalPath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')
. (Join-Path $PSScriptRoot 'lib\Plan.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$config = Read-CwcJson -Path (Join-Path $skillRoot 'config\scope.json')
$protection = Read-CwcJson -Path (Join-Path $skillRoot 'config\protected-resources.json')
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; exit 3 }
if (-not (Test-Path -LiteralPath $Plan)) { Write-Error "计划不存在：$Plan"; exit 3 }

$planDoc = Get-PlanDocument -Path $Plan
if ($null -eq $planDoc) { Write-Error '计划无法解析'; exit 3 }

# ── 干跑：只读，不写任何文件 ────────────────────────────────────────────────
if (-not $Execute) {
    Write-Output '=== quarantine / DRY-RUN（不会移动或删除任何文件） ==='
    Write-Output ("计划      : {0}" -f $Plan)
    Write-Output ("计划哈希  : {0}" -f [string]$planDoc.plan_sha256)
    Write-Output ("策略      : {0}" -f [string]$planDoc.execution_policy.mode)
    Write-Output ''
    $n = 0
    foreach ($it in @($planDoc.items)) {
        $n++
        Write-Output ("  {0}  {1,-8} {2,-12} {3,10}  {4}" -f $it.id, $it.status, $it.kind, (Format-CwcBytes -Bytes ([long]$it.bytes)), $it.normalized_path)
    }
    if ($n -eq 0) { Write-Output '  （计划为空）' }

    if (-not [string]::IsNullOrWhiteSpace($Approval)) {
        Write-Output ''
        Write-Output '--- 预校验（只读） ---'
        $v = Invoke-PlanValidation -PlanPath $Plan -ApprovalPath $Approval -Config $config -Protection $protection -SkillRoot $skillRoot
        foreach ($c in @($v.Checks)) { Write-Output ("[{0}] {1}  {2}" -f $c.result, $c.check, $c.detail) }
        foreach ($e in @($v.Errors)) { Write-Output ("  - {0}" -f $e) }
    }
    Write-Output ''
    Write-Output 'DRY-RUN 结束：未创建隔离目录、未写日志、未改动任何文件。'
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Approval)) {
    Write-Error '缺少审批文件：未经人工逐项授权不得执行。'
    exit 2
}

# ── 并发锁 ──────────────────────────────────────────────────────────────────
$lockPath = Join-Path (Join-Path $skillRoot 'manifests') '.quarantine.lock'
if (-not (Enter-CwcLock -LockPath $lockPath)) {
    Write-Error ("已有另一个执行进程持有锁：{0}。并发执行会让日志与移动顺序错乱，已拒绝。" -f $lockPath)
    exit 2
}

try {
    $validation = Invoke-PlanValidation -PlanPath $Plan -ApprovalPath $Approval -Config $config -Protection $protection -SkillRoot $skillRoot
    if (-not $validation.Ok) {
        Write-Output '=== 拒绝执行 ==='
        foreach ($e in @($validation.Errors)) { Write-Output ("  - {0}" -f $e) }
        Write-CwcAudit -SkillRoot $skillRoot -Action 'quarantine_refused' -Fields @{
            plan = $Plan; approval = $Approval; errors = @($validation.Errors)
        }
        exit 2
    }

    $approved = @($validation.Approved)
    if ($approved.Count -eq 0) { Write-Error '审批文件没有可执行条目。'; exit 2 }

    # ── 隔离根：同卷 + 不在允许范围内 + 非重解析点 + 祖先干净 ──────────────
    $qRootTemplate = if ([string]::IsNullOrWhiteSpace($QuarantineRoot)) { [string]$config.quarantine_root } else { $QuarantineRoot }
    $qRoot = Get-NormalizedPath -Path (Expand-CwcPath -Template $qRootTemplate)
    if ([string]::IsNullOrWhiteSpace($qRoot)) { Write-Error '隔离根路径无效。'; exit 2 }

    foreach ($r in (Get-AllowedRootSet -Config $config)) {
        if (Test-PathUnder -Path $qRoot -Root $r.Path) { Write-Error ("隔离根位于允许清理范围内，拒绝：{0}" -f $qRoot); exit 2 }
    }
    foreach ($r in (Get-ProtectedRootSet -Protection $protection)) {
        if (Test-PathUnder -Path $qRoot -Root $r.Path) { Write-Error ("隔离根位于受保护资源内，拒绝：{0}" -f $qRoot); exit 2 }
    }

    $qVolume = [System.IO.Path]::GetPathRoot($qRoot)
    foreach ($it in $approved) {
        $p = [string]$it.normalized_path
        $iv = [System.IO.Path]::GetPathRoot($p)
        if ($iv -ne $qVolume) {
            Write-Error ("跨卷隔离被拒绝：{0} 在 {1}，隔离根在 {2}。跨卷移动不是原子操作。" -f $p, $iv, $qVolume)
            exit 2
        }
        if (Test-PathUnder -Path $qRoot -Root $p) { Write-Error ("隔离根位于待移动条目内部：{0}" -f $p); exit 2 }
        if (Test-PathUnder -Path $p -Root $qRoot) { Write-Error ("待移动条目位于隔离根内部：{0}" -f $p); exit 2 }
    }

    $runId = [guid]::NewGuid().ToString()
    $runDir = Join-Path $qRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $runId.Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $runDir -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Error ("无法创建隔离目录：{0}" -f $_.Exception.Message)
        exit 2
    }
    # New-Item -Force 在"父路径是文件"时会静默成功却不创建目录；必须复核。
    $qSafe = Test-CwcQuarantineDir -Path $runDir
    if (-not $qSafe.Ok) {
        Write-Error ("隔离目录不可信：{0}（{1}）" -f $runDir, $qSafe.Reason)
        exit 2
    }

    if ([string]::IsNullOrWhiteSpace($JournalPath)) {
        $JournalPath = Join-Path (Join-Path $skillRoot 'manifests') ('journal-' + $runId.Substring(0, 8) + '.json')
    }

    $journal = [ordered]@{
        schema_version  = 2
        skill           = 'claude-windows-cleanup'
        skill_version   = '1.1.0'
        run_id          = $runId
        started_at      = (Get-CwcTimestamp)
        finished_at     = ''
        plan            = (Resolve-Path -LiteralPath $Plan).Path
        plan_sha256     = [string]$planDoc.plan_sha256
        approval        = (Resolve-Path -LiteralPath $Approval).Path
        approval_sha256 = (Get-FileSha256 -Path $Approval)
        quarantine_root = $qRoot
        quarantine_run  = $runDir
        is_admin        = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
        entries         = @()
        result          = 'in_progress'
    }
    $entries = New-Object System.Collections.Generic.List[object]

    $journalWriter = {
        # 注意：PS 5.1 下 @($list) 对 List[object] 会抛"参数类型不匹配"，必须 ToArray()
        $journal['entries'] = $entries.ToArray()
        $null = Write-CwcJsonAtomic -Path $JournalPath -Object (Hide-CwcSensitive -InputObject $journal)
    }

    function New-Entry {
        param($Item, [string]$PlannedDest)
        $e = [ordered]@{
            id            = [string]$Item.id
            original_path = [string]$Item.normalized_path
            kind          = [string]$Item.kind
            bytes         = [long]$Item.bytes
            digest        = [string]$Item.digest
            state         = 'planned'
            planned_dest  = $PlannedDest
            planned_at    = (Get-CwcTimestamp)
            moved_at      = ''
            moved_to      = ''
            error         = ''
        }
        $entries.Add($e) | Out-Null
        return $e
    }

    function Save-Emergency {
        param([string]$Reason)
        # 日志目录都写不进去时的最后手段：写到 %TEMP%（不依赖 skill 目录权限）
        $path = Join-Path $env:TEMP ('cwc-emergency-' + $runId.Substring(0, 8) + '.json')
        try {
            $doc = [ordered]@{
                run_id = $runId; reason = $Reason; quarantine_run = $runDir
                entries = $entries.ToArray(); written_at = (Get-CwcTimestamp)
            }
            [System.IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
        } catch { $path = '' }
        return $path
    }

    & $journalWriter
    Write-Output '=== quarantine / EXECUTE（仅隔离移动，不删除） ==='
    Write-Output ("运行 ID   : {0}" -f $runId)
    Write-Output ("隔离目录  : {0}" -f $runDir)
    Write-Output ("日志      : {0}" -f $JournalPath)
    Write-Output ''

    $fatal = $false
    $persistenceFailure = $false
    foreach ($item in @($approved | Sort-Object { $_.id })) {
        $leaf = [System.IO.Path]::GetFileName([string]$item.normalized_path)
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'item' }
        $dest = Join-Path $runDir ('{0}-{1}' -f $item.id, $leaf)
        $entry = New-Entry -Item $item -PlannedDest $dest
        & $journalWriter

        # 移动前最后一次复核：路径、指纹、重解析点、隔离目录本身
        $qNow = Test-CwcQuarantineDir -Path $runDir
        if (-not $qNow.Ok) {
            $entry['state'] = 'failed'; $entry['error'] = ('quarantine_dir_untrusted:' + $qNow.Reason)
            & $journalWriter; $fatal = $true; break
        }
        $pre = Test-CwcItemSafety -Path ([string]$item.normalized_path) -Config $config -Protection $protection
        if ($pre.Decision -ne 'ALLOW') {
            $entry['state'] = 'failed'; $entry['error'] = ('precheck_{0}:{1}' -f $pre.Decision, $pre.Code)
            & $journalWriter; $fatal = $true; break
        }
        $live = Test-LiveItemState -Item $item -Config $config -Protection $protection
        if (-not $live.Ok) {
            $entry['state'] = 'failed'; $entry['error'] = ('live_{0}' -f $live.Reason)
            & $journalWriter; $fatal = $true; break
        }
        if (Test-Path -LiteralPath $dest) {
            $entry['state'] = 'failed'; $entry['error'] = 'destination_exists'
            & $journalWriter; $fatal = $true; break
        }

        $mv = Invoke-CwcMoveWithJournal -Source $pre.Normalized -Destination $dest -SaveJournal {
            $entry['moved_at'] = (Get-CwcTimestamp)
            $entry['moved_to'] = $dest
            $entry['state'] = 'moved'
            & $journalWriter
        }

        if (-not $mv.Ok) {
            if ($mv.Stage -eq 'journal') {
                # 移动成功但记账失败：可能已搬回，也可能悬空
                $entry['error'] = ('journal_failed: ' + $mv.Error)
                if ($mv.Reverted) {
                    $entry['state'] = 'reverted'
                    $entry['moved_to'] = ''
                } else {
                    $entry['state'] = 'moved_unverified'
                    $emergency = Save-Emergency -Reason 'journal_write_failed_after_move'
                    Write-Error ("移动已完成但日志无法落盘，且无法自动搬回。应急记录：{0}" -f $emergency)
                    $persistenceFailure = $true
                    $fatal = $true
                    break
                }
                $persistenceFailure = $true
                $fatal = $true
                break
            }
            $entry['state'] = 'failed'; $entry['error'] = ('move_failed: ' + $mv.Error)
            & $journalWriter; $fatal = $true; break
        }

        # 移动后复核：内容必须与计划一致，否则搬回
        $post = Get-TreeFingerprint -Path $dest -MaxEntries 50000 -MaxBytes 2147483648
        if (-not $post.Ok -or [string]$post.Digest -ne [string]$item.digest -or [long]$post.Bytes -ne [long]$item.bytes) {
            $detail = if (-not $post.Ok) { 'post_fingerprint_failed:' + $post.Reason } else { 'post_digest_mismatch' }
            $entry['error'] = $detail
            try {
                Move-Item -LiteralPath $dest -Destination $pre.Normalized -ErrorAction Stop
                $entry['state'] = 'reverted'; $entry['moved_to'] = ''
            } catch {
                $entry['state'] = 'moved_unverified'
                $entry['error'] = $detail + ' / revert_failed: ' + $_.Exception.Message
            }
            & $journalWriter; $fatal = $true; break
        }
        & $journalWriter
        Write-Output ("  {0}  已隔离 -> {1}" -f $item.id, $dest)
    }

    $journal['finished_at'] = (Get-CwcTimestamp)
    if ($fatal) {
        $journal['result'] = if ($persistenceFailure) { 'persistence_failed' } else { 'failed' }
        try { & $journalWriter } catch { $null = Save-Emergency -Reason 'final_journal_failed' }
        Write-Output ''
        Write-Output '执行中止：后续条目未处理。已移动的条目仍在隔离目录，可用 restore.ps1 -Reconcile 对账后搬回。'
        Write-CwcAudit -SkillRoot $skillRoot -Action 'quarantine_failed' -Fields @{
            journal = $JournalPath; run_id = $runId; quarantine = $runDir; persistence = $persistenceFailure
        }
        if ($persistenceFailure) { exit 15 }
        exit 5
    }

    $journal['result'] = 'completed'
    & $journalWriter
    $moved = @($entries | Where-Object { $_.state -eq 'moved' }).Count
    Write-Output ''
    Write-Output ("完成：{0} 项已隔离到 {1}" -f $moved, $runDir)
    Write-Output '未删除任何文件。恢复：.\scripts\restore.ps1 -Journal "' + $JournalPath + '" -Execute'
    Write-CwcAudit -SkillRoot $skillRoot -Action 'quarantine_completed' -Fields @{
        journal = $JournalPath; run_id = $runId; quarantine = $runDir; moved = $moved
    }
    exit 0
} finally {
    Exit-CwcLock -LockPath $lockPath
}
