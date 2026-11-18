# plan.ps1 — 由只读检查报告生成维护计划 + 审批模板（V1.1）
# 输出：
#   manifests/plan-<ts>.json        计划（items 哈希 + 配置/源码绑定 + 口令哈希）
#   manifests/plan-<ts>.json.sha256 计划文件哈希（防篡改）
#   manifests/approval-template-<ts>.json 审批模板（默认空）
#   reports/plan-<ts>.md            人读版
# 本脚本不执行任何文件操作。
#
# 一次性口令（nonce）只打印到控制台，计划文件里只存它的 SHA-256：
# 只有拿到本次控制台输出的人（或进程）才能写出合法审批。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InspectionPath,
    [string]$PlanPath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $skillRoot 'config\scope.json'
$protectPath = Join-Path $skillRoot 'config\protected-resources.json'

if (-not (Test-Path -LiteralPath $configPath)) { Write-Error "缺少配置：$configPath"; exit 3 }
$config = Read-CwcJson -Path $configPath
if ($null -eq $config) { Write-Error '配置无法解析'; exit 3 }

if (-not (Test-Path -LiteralPath $InspectionPath)) { Write-Error "检查报告不存在：$InspectionPath"; exit 3 }
$inspection = Read-CwcJson -Path $InspectionPath
if ($null -eq $inspection) { Write-Error '检查报告无法解析'; exit 3 }

Write-Output '=== claude-windows-cleanup / plan (V1.1) ==='

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$planId = ('plan-' + $stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

$planItems = @()
foreach ($it in @($inspection.items)) {
    if ($null -eq $it) { continue }
    $planItems += [pscustomobject][ordered]@{
        id                = [string]$it.id
        root_id           = [string]$it.root_id
        kind              = [string]$it.kind
        fs_kind           = [string]$it.fs_kind
        path              = [string]$it.path
        normalized_path   = [string]$it.normalized_path
        status            = [string]$it.status
        status_reason     = [string]$it.status_reason
        proposed_action   = [string]$it.proposed_action
        risk              = [string]$it.risk
        bytes             = [long]$it.bytes
        file_count        = [int]$it.file_count
        digest            = [string]$it.digest
        last_write_utc    = [string]$it.last_write_utc
        restorable        = [bool]$it.restorable
        approval_required = $true
        selected          = $false
    }
}

$hash = Get-PlanSha256 -Items $planItems

# 一次性口令：8 位十六进制，分两段；只在控制台出现一次
$raw = ([guid]::NewGuid().ToString('N').Substring(0, 8)).ToUpperInvariant()
$nonce = $raw.Substring(0, 4) + '-' + $raw.Substring(4, 4)
$nonceHash = Get-TextSha256 -Text $nonce

$binding = Get-CwcConfigBinding -SkillRoot $skillRoot

$counts = [ordered]@{
    total      = $planItems.Count
    verified   = @($planItems | Where-Object { $_.status -eq 'VERIFIED' }).Count
    unknown    = @($planItems | Where-Object { $_.status -eq 'UNKNOWN' }).Count
    blocked    = @($planItems | Where-Object { $_.status -eq 'BLOCKED' }).Count
    protected  = @($planItems | Where-Object { $_.status -eq 'PROTECTED' }).Count
    actionable = @($planItems | Where-Object { $_.status -eq 'VERIFIED' -and $_.proposed_action -eq 'QUARANTINE' }).Count
}

$plan = [ordered]@{
    schema_version        = 2
    skill                 = 'claude-windows-cleanup'
    skill_version         = '1.1.0'
    plan_id               = $planId
    created_at            = (Get-CwcTimestamp)
    source_inspection     = (Resolve-Path -LiteralPath $InspectionPath).Path
    inspection_sha256     = (Get-FileSha256 -Path $InspectionPath)
    install_state         = [string]$inspection.install_state
    config_sha256         = [string]$binding.ConfigSha256
    protection_sha256     = [string]$binding.ProtectionSha256
    skill_fingerprint     = [string]$binding.SkillFingerprint
    approval_nonce_sha256 = $nonceHash
    execution_policy      = [ordered]@{
        mode                   = 'QUARANTINE_ONLY'
        permanent_delete       = $false
        acl_change             = $false
        takeown                = $false
        network                = $false
        registry_write         = $false
        environment_write      = $false
        requires_approval      = $true
        requires_dry_run_first = $true
        same_volume_required   = $true
    }
    counts                = $counts
    items                 = $planItems
    plan_sha256           = $hash
}

if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    $PlanPath = Join-Path (Join-Path $skillRoot 'manifests') ($planId + '.json')
}
$null = Write-CwcJsonAtomic -Path $PlanPath -Object (Hide-CwcSensitive -InputObject $plan)
# sidecar 绑定的是"计划文件本身"的哈希（防文件级篡改）；items 哈希另由 plan_sha256 承担。
$planFileHash = Get-FileSha256 -Path $PlanPath
[System.IO.File]::WriteAllText(($PlanPath + '.sha256'), $planFileHash, (New-Object System.Text.UTF8Encoding($false)))

$templatePath = Join-Path (Join-Path $skillRoot 'manifests') ('approval-template-' + $stamp + '.json')
$template = [ordered]@{
    schema_version      = 2
    plan_sha256         = $hash
    decision            = ''
    approved_ids        = @()
    approved_by         = ''
    approved_at         = ''
    confirmation_nonce  = ''
    note                = '由用户本人填写：decision=APPROVE；approved_ids 只填你逐项确认过的 id；confirmation_nonce 填 plan.ps1 控制台打印的一次性口令；approved_by/approved_at 填你的标识与时间。任何一项不符都会拒绝执行。'
}
$null = Write-CwcJsonAtomic -Path $templatePath -Object $template

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Claude Desktop 维护计划 ' + $planId)
$md.Add('')
$md.Add(('- 生成时间：{0}' -f $plan.created_at))
$md.Add(('- 安装状态：{0}' -f $plan.install_state))
$md.Add(('- 计划哈希：`{0}`' -f $hash))
$md.Add(('- 配置绑定：`{0}` / 保护清单 `{1}`' -f $plan.config_sha256, $plan.protection_sha256))
$md.Add(('- 条目：共 {0} 项（VERIFIED {1} / UNKNOWN {2} / BLOCKED {3} / PROTECTED {4}）' -f $counts.total, $counts.verified, $counts.unknown, $counts.blocked, $counts.protected))
$md.Add('')
$md.Add('| ID | 状态 | 类型 | 大小 | 路径 | 说明 |')
$md.Add('|----|------|------|------|------|------|')
foreach ($it in $planItems) {
    $reason = ([string]$it.status_reason) -replace '\|', '/'
    $md.Add(('| {0} | {1} | {2} | {3} | `{4}` | {5} |' -f $it.id, $it.status, $it.kind, (Format-CwcBytes -Bytes $it.bytes), $it.normalized_path, $reason))
}
$md.Add('')
$md.Add('## 执行规则')
$md.Add('')
$md.Add('1. 只有 `VERIFIED` 且 `proposed_action=QUARANTINE` 的条目可以被批准；其余状态一律拒绝。')
$md.Add('2. 审批必须绑定计划哈希 + 一次性口令；缺任一项都会被拒绝。')
$md.Add('3. 计划生成后如果 `config/` 或脚本被改动，旧计划立即失效，必须重新生成。')
$md.Add('4. 执行只做"隔离移动"，不做删除；隔离目录与原路径必须同卷，事后可用 `restore.ps1` 原样搬回。')
$md.Add('5. 执行前会逐项复核指纹（类型/大小/摘要/重解析点/可读性），任何变化都会中止整轮。')
$md.Add('')
$md.Add('## 下一步')
$md.Add('')
$md.Add('```powershell')
$md.Add('# 1) 干跑：不写任何东西')
$md.Add('.\scripts\quarantine.ps1 -Plan "' + $PlanPath + '"')
$md.Add('# 2) 填写审批文件后执行（需用户本人授权 + 口令）')
$md.Add('.\scripts\quarantine.ps1 -Plan "' + $PlanPath + '" -Approval "' + $templatePath + '" -Execute')
$md.Add('```')

$mdPath = Join-Path (Join-Path $skillRoot 'reports') ($planId + '.md')
[System.IO.File]::WriteAllLines($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ("计划 ID     : {0}" -f $planId)
Write-Output ("计划哈希    : {0}" -f $hash)
Write-Output ("条目        : 共 {0} 项 / 可执行候选 {1} 项" -f $counts.total, $counts.actionable)
Write-Output ("计划文件    : {0}" -f $PlanPath)
Write-Output ("审批模板    : {0}" -f $templatePath)
Write-Output ("人读报告    : {0}" -f $mdPath)
Write-Output ''
Write-Output '----------------------------------------------------------------'
Write-Output ("一次性授权口令（只打印这一次，不落盘）: {0}" -f $nonce)
Write-Output '把它填进审批文件的 confirmation_nonce 字段；丢失则重新生成计划。'
Write-Output '----------------------------------------------------------------'
Write-Output ''
Write-Output '注意：计划中的所有条目 selected=false。未填写审批文件前，任何执行请求都会被拒绝。'

Write-CwcAudit -SkillRoot $skillRoot -Action 'plan' -Fields @{
    plan = $PlanPath
    plan_id = $planId
    plan_sha256 = $hash
    actionable = $counts.actionable
    config_sha256 = [string]$binding.ConfigSha256
}

exit 0
