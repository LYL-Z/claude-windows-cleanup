# Plan.ps1 — 计划完整性、配置绑定、审批绑定与执行前复核（只读）
# 被 validate-plan.ps1 与 quarantine.ps1 共用，保证"校验"与"执行"用的是同一套判定。
#
# V1.1 新增（第二轮复审结论）：
#   - 计划绑定 config/protection 的 SHA-256 与 Skill 源码指纹：配置被改宽 → 旧计划立即失效。
#   - 审批绑定一次性口令（nonce）：计划里只存 nonce 的 SHA-256，审批里必须给出原文。
#   - 执行策略白名单：计划声称要删/改 ACL/联网 → 直接拒绝。

$script:CwcPlanLoaded = $true

function Get-PlanDocument {
    param([Parameter(Mandatory)][string]$Path)
    return (Read-CwcJson -Path $Path)
}

function Test-PlanPolicy {
    <# 计划声明的执行策略必须与 Skill 允许的唯一形态一致。 #>
    param([Parameter(Mandatory)]$Plan)

    $errors = @()
    $policy = $Plan.execution_policy
    if ($null -eq $policy) { return @('execution_policy_missing') }
    if ([string]$policy.mode -ne 'QUARANTINE_ONLY') { $errors += 'policy_mode_not_quarantine_only' }
    foreach ($flag in @('permanent_delete', 'acl_change', 'takeown', 'network', 'registry_write', 'environment_write')) {
        if ($null -ne $policy.$flag -and [bool]$policy.$flag) { $errors += ('policy_forbids_' + $flag) }
    }
    return $errors
}

function Test-PlanIntegrity {
    <#
    .SYNOPSIS
        校验计划：items 哈希、文件哈希、配置/保护/源码指纹绑定、执行策略。
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$PlanPath,
        [string]$SkillRoot = ''
    )

    $checks = @()
    $errors = @()

    $schema = 0
    if ($null -ne $Plan.schema_version) { [int]::TryParse([string]$Plan.schema_version, [ref]$schema) | Out-Null }
    if ($schema -lt 2) {
        $errors += 'plan_schema_outdated'
        $checks += [pscustomobject]@{ check = 'plan_schema'; result = 'FAIL'; detail = ('schema={0}，V1.1 要求 >= 2' -f $Plan.schema_version) }
    } else {
        $checks += [pscustomobject]@{ check = 'plan_schema'; result = 'PASS'; detail = [string]$schema }
    }

    $items = @($Plan.items)
    $recomputed = Get-PlanSha256 -Items $items
    $declared = [string]$Plan.plan_sha256
    if ($recomputed -ne $declared) {
        $errors += 'plan_items_hash_mismatch'
        $checks += [pscustomobject]@{ check = 'plan_items_hash'; result = 'FAIL'; detail = ('recomputed={0} declared={1}' -f $recomputed, $declared) }
    } else {
        $checks += [pscustomobject]@{ check = 'plan_items_hash'; result = 'PASS'; detail = $declared }
    }

    $sidecar = $PlanPath + '.sha256'
    if (Test-Path -LiteralPath $sidecar) {
        $expected = ([System.IO.File]::ReadAllText($sidecar, [System.Text.Encoding]::UTF8)).Trim().ToLowerInvariant()
        $actual = Get-FileSha256 -Path $PlanPath
        if ($null -eq $actual -or $actual -ne $expected) {
            $errors += 'plan_file_hash_mismatch'
            $checks += [pscustomobject]@{ check = 'plan_file_hash'; result = 'FAIL'; detail = ('expected={0} actual={1}' -f $expected, $actual) }
        } else {
            $checks += [pscustomobject]@{ check = 'plan_file_hash'; result = 'PASS'; detail = $actual }
        }
    } else {
        $checks += [pscustomobject]@{ check = 'plan_file_hash'; result = 'SKIP'; detail = 'sidecar 不存在' }
    }

    # 配置绑定：白名单/保护清单被改宽或被换掉时，旧计划不得继续用
    if (-not [string]::IsNullOrWhiteSpace($SkillRoot)) {
        $binding = Get-CwcConfigBinding -SkillRoot $SkillRoot
        foreach ($pair in @(
            @{ name = 'config_binding'; declared = [string]$Plan.config_sha256; actual = [string]$binding.ConfigSha256 },
            @{ name = 'protection_binding'; declared = [string]$Plan.protection_sha256; actual = [string]$binding.ProtectionSha256 },
            @{ name = 'skill_binding'; declared = [string]$Plan.skill_fingerprint; actual = [string]$binding.SkillFingerprint }
        )) {
            if ([string]::IsNullOrWhiteSpace($pair.declared)) {
                # 不能 SKIP：否则剥离字段就能绕过"配置被改宽"的检测
                $errors += ($pair.name + '_missing')
                $checks += [pscustomobject]@{ check = $pair.name; result = 'FAIL'; detail = '计划未记录该绑定' }
                continue
            }
            if ($pair.declared -ne $pair.actual) {
                $errors += ($pair.name + '_mismatch')
                $checks += [pscustomobject]@{ check = $pair.name; result = 'FAIL'; detail = ('declared={0} actual={1}' -f $pair.declared, $pair.actual) }
            } else {
                $checks += [pscustomobject]@{ check = $pair.name; result = 'PASS'; detail = $pair.actual }
            }
        }
    }

    $policyErrors = Test-PlanPolicy -Plan $Plan
    if ($policyErrors.Count -gt 0) {
        $errors += $policyErrors
        $checks += [pscustomobject]@{ check = 'execution_policy'; result = 'FAIL'; detail = ($policyErrors -join ',') }
    } else {
        $checks += [pscustomobject]@{ check = 'execution_policy'; result = 'PASS'; detail = 'QUARANTINE_ONLY' }
    }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Checks = $checks; Errors = $errors; ItemsHash = $recomputed }
}

function Test-ApprovalBinding {
    <#
    .SYNOPSIS
        审批必须绑定同一份计划、携带一次性口令、只批准可执行条目。
    .DESCRIPTION
        口令的原文只在 plan.ps1 的控制台输出里出现一次；计划文件里只有它的 SHA-256。
        这能挡住"只拿到文件就能伪造审批"的路径，但挡不住拥有完整控制台历史/进程访问权的本机攻击者——
        这是已知边界，见 SECURITY.md。
    #>
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$ApprovalPath
    )

    $checks = @()
    $errors = @()
    $approved = @()

    if (-not (Test-Path -LiteralPath $ApprovalPath)) {
        return [pscustomobject]@{ Ok = $false; Checks = @(); Errors = @('approval_missing'); Approved = @() }
    }
    $approval = Read-CwcJson -Path $ApprovalPath
    if ($null -eq $approval) {
        return [pscustomobject]@{ Ok = $false; Checks = @(); Errors = @('approval_unparsable'); Approved = @() }
    }

    $planHash = [string]$Plan.plan_sha256
    $boundHash = [string]$approval.plan_sha256
    if ($boundHash -ne $planHash) {
        $errors += 'approval_plan_hash_mismatch'
        $checks += [pscustomobject]@{ check = 'approval_plan_binding'; result = 'FAIL'; detail = ('approval={0} plan={1}' -f $boundHash, $planHash) }
    } else {
        $checks += [pscustomobject]@{ check = 'approval_plan_binding'; result = 'PASS'; detail = $planHash }
    }

    # 一次性口令
    $nonceHash = [string]$Plan.approval_nonce_sha256
    $givenNonce = ([string]$approval.confirmation_nonce).Trim()
    if ([string]::IsNullOrWhiteSpace($nonceHash)) {
        $errors += 'plan_nonce_missing'
        $checks += [pscustomobject]@{ check = 'approval_nonce'; result = 'FAIL'; detail = '计划未生成口令（旧计划），请重新生成计划' }
    } elseif ([string]::IsNullOrWhiteSpace($givenNonce)) {
        $errors += 'approval_nonce_missing'
        $checks += [pscustomobject]@{ check = 'approval_nonce'; result = 'FAIL'; detail = '审批缺少 confirmation_nonce' }
    } elseif ((Get-TextSha256 -Text $givenNonce) -ne $nonceHash) {
        $errors += 'approval_nonce_mismatch'
        $checks += [pscustomobject]@{ check = 'approval_nonce'; result = 'FAIL'; detail = '口令与计划不匹配' }
    } else {
        $checks += [pscustomobject]@{ check = 'approval_nonce'; result = 'PASS'; detail = 'matched' }
    }

    $decision = ([string]$approval.decision).Trim().ToUpperInvariant()
    if ($decision -ne 'APPROVE') {
        $errors += 'approval_decision_missing'
        $checks += [pscustomobject]@{ check = 'approval_decision'; result = 'FAIL'; detail = ([string]$approval.decision) }
    } else {
        $checks += [pscustomobject]@{ check = 'approval_decision'; result = 'PASS'; detail = 'APPROVE' }
    }

    $by = ([string]$approval.approved_by).Trim()
    $at = ([string]$approval.approved_at).Trim()
    if ([string]::IsNullOrWhiteSpace($by) -or [string]::IsNullOrWhiteSpace($at)) {
        $errors += 'approval_identity_missing'
        $checks += [pscustomobject]@{ check = 'approval_identity'; result = 'FAIL'; detail = 'approved_by/approved_at 必填' }
    } else {
        $checks += [pscustomobject]@{ check = 'approval_identity'; result = 'PASS'; detail = ('{0} @ {1}' -f $by, $at) }
    }

    $ids = @($approval.approved_ids)
    if ($ids.Count -eq 0) {
        $errors += 'approval_empty'
        $checks += [pscustomobject]@{ check = 'approval_ids'; result = 'FAIL'; detail = 'approved_ids 为空' }
    }

    $planById = @{}
    foreach ($it in @($Plan.items)) { $planById[[string]$it.id] = $it }

    $seen = @{}
    foreach ($id in $ids) {
        $sid = [string]$id
        if ($seen.ContainsKey($sid)) { continue }
        $seen[$sid] = $true
        if (-not $planById.ContainsKey($sid)) {
            $errors += ('approval_unknown_id:' + $sid)
            continue
        }
        $it = $planById[$sid]
        if ([string]$it.status -ne 'VERIFIED' -or [string]$it.proposed_action -ne 'QUARANTINE') {
            $errors += ('approval_ineligible_id:' + $sid)
            continue
        }
        $approved += $it
    }
    $checks += [pscustomobject]@{ check = 'approval_ids'; result = $(if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }); detail = ('{0}/{1} 项可执行' -f $approved.Count, $ids.Count) }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Checks = $checks; Errors = $errors; Approved = $approved; Approval = $approval }
}

function Test-LiveItemState {
    <#
    .SYNOPSIS
        执行前复核：路径仍在允许范围、仍可读、仍无重解析点，且指纹与计划一致。
    #>
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Protection
    )

    $path = [string]$Item.normalized_path
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string]$Item.path }

    $safety = Test-CwcItemSafety -Path $path -Config $Config -Protection $Protection
    if ($safety.Decision -ne 'ALLOW') {
        return [pscustomobject]@{ Ok = $false; Reason = ('safety_{0}:{1}' -f $safety.Decision, $safety.Code); Detail = $safety.Reason }
    }

    $fp = Get-TreeFingerprint -Path $safety.Normalized -MaxEntries 50000 -MaxBytes 2147483648
    if (-not $fp.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = ('fingerprint_{0}' -f $fp.Reason); Detail = '无法取得当前指纹' }
    }
    if ([string]$fp.Digest -ne [string]$Item.digest) {
        return [pscustomobject]@{ Ok = $false; Reason = 'state_changed_digest'; Detail = ('计划 digest={0} 当前={1}' -f $Item.digest, $fp.Digest) }
    }
    if ([long]$fp.Bytes -ne [long]$Item.bytes) {
        return [pscustomobject]@{ Ok = $false; Reason = 'state_changed_size'; Detail = ('计划 {0} B 当前 {1} B' -f $Item.bytes, $fp.Bytes) }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.fs_kind) -and [string]$fp.Kind -ne [string]$Item.fs_kind) {
        return [pscustomobject]@{ Ok = $false; Reason = 'kind_changed'; Detail = ('{0} -> {1}' -f $Item.fs_kind, $fp.Kind) }
    }

    return [pscustomobject]@{ Ok = $true; Reason = ''; Detail = ''; Normalized = $safety.Normalized; Fingerprint = $fp }
}

function Invoke-PlanValidation {
    <#
    .SYNOPSIS
        完整校验：计划完整性 -> 审批绑定 -> 逐项实时复核。
    #>
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [string]$ApprovalPath = '',
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Protection,
        [string]$SkillRoot = ''
    )

    $checks = @()
    $errors = @()

    $plan = Get-PlanDocument -Path $PlanPath
    if ($null -eq $plan) {
        return [pscustomobject]@{ Ok = $false; Checks = @(); Errors = @('plan_unparsable'); Approved = @(); Plan = $null; Approval = $null }
    }
    $integ = Test-PlanIntegrity -Plan $plan -PlanPath $PlanPath -SkillRoot $SkillRoot
    $checks += $integ.Checks
    $errors += $integ.Errors
    if (-not $integ.Ok) {
        return [pscustomobject]@{ Ok = $false; Checks = $checks; Errors = $errors; Approved = @(); Plan = $plan; Approval = $null }
    }

    if ([string]::IsNullOrWhiteSpace($ApprovalPath)) {
        return [pscustomobject]@{ Ok = $false; Checks = $checks; Errors = @('approval_not_provided'); Approved = @(); Plan = $plan; Approval = $null }
    }

    $bind = Test-ApprovalBinding -Plan $plan -ApprovalPath $ApprovalPath
    $checks += $bind.Checks
    $errors += $bind.Errors
    if (-not $bind.Ok) {
        return [pscustomobject]@{ Ok = $false; Checks = $checks; Errors = $errors; Approved = $bind.Approved; Plan = $plan; Approval = $bind.Approval }
    }

    $live = @()
    foreach ($it in @($bind.Approved)) {
        $r = Test-LiveItemState -Item $it -Config $Config -Protection $Protection
        $live += [pscustomobject]@{ id = [string]$it.id; ok = [bool]$r.Ok; reason = [string]$r.Reason; detail = [string]$r.Detail }
        if (-not $r.Ok) { $errors += ('live_check_failed:{0}:{1}' -f $it.id, $r.Reason) }
    }
    $failed = @($live | Where-Object { -not $_.ok }).Count
    $checks += [pscustomobject]@{ check = 'live_recheck'; result = $(if ($failed -eq 0) { 'PASS' } else { 'FAIL' }); detail = ('{0}/{1} 项通过' -f (@($live).Count - $failed), @($live).Count) }

    return [pscustomobject]@{
        Ok       = ($errors.Count -eq 0)
        Checks   = $checks
        Errors   = $errors
        Approved = $bind.Approved
        Live     = $live
        Plan     = $plan
        Approval = $bind.Approval
    }
}
