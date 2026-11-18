# validate-plan.ps1 — 计划与审批的独立校验（只读）
# 退出码：0=通过；2=拒绝（篡改/未授权/状态变化）；3=输入缺失。

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Plan,
    [string]$Approval = '',
    [switch]$IntegrityOnly,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')
. (Join-Path $PSScriptRoot 'lib\Plan.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$config = Read-CwcJson -Path (Join-Path $skillRoot 'config\scope.json')
$protection = Read-CwcJson -Path (Join-Path $skillRoot 'config\protected-resources.json')
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; exit 3 }
if (-not (Test-Path -LiteralPath $Plan)) { Write-Error "计划不存在：$Plan"; exit 3 }

if ($IntegrityOnly) {
    $doc = Get-PlanDocument -Path $Plan
    if ($null -eq $doc) { Write-Error '计划无法解析'; exit 3 }
    $r = Test-PlanIntegrity -Plan $doc -PlanPath $Plan -SkillRoot $skillRoot
    if ($Json) {
        [pscustomobject]@{ ok = $r.Ok; checks = $r.Checks; errors = $r.Errors } | ConvertTo-Json -Depth 8
    } else {
        foreach ($c in $r.Checks) { Write-Output ("[{0}] {1}  {2}" -f $c.result, $c.check, $c.detail) }
        foreach ($e in @($r.Errors)) { Write-Output ("  - {0}" -f $e) }
    }
    if ($r.Ok) { exit 0 } else { exit 2 }
}

if ([string]::IsNullOrWhiteSpace($Approval)) {
    Write-Output '未提供审批文件：只能做完整性校验，不能批准执行。'
    $doc = Get-PlanDocument -Path $Plan
    if ($null -eq $doc) { exit 3 }
    $r = Test-PlanIntegrity -Plan $doc -PlanPath $Plan -SkillRoot $skillRoot
    foreach ($c in $r.Checks) { Write-Output ("[{0}] {1}  {2}" -f $c.result, $c.check, $c.detail) }
    if ($r.Ok) { exit 2 } else { exit 2 }
}

$result = Invoke-PlanValidation -PlanPath $Plan -ApprovalPath $Approval -Config $config -Protection $protection -SkillRoot $skillRoot

$payload = [pscustomobject]@{
    ok        = $result.Ok
    plan      = $Plan
    approval  = $Approval
    errors    = $result.Errors
    checks    = $result.Checks
    live      = $result.Live
    approved  = @($result.Approved | ForEach-Object { [pscustomobject]@{ id = $_.id; path = $_.normalized_path; bytes = $_.bytes } })
}

if ($Json) {
    $payload | ConvertTo-Json -Depth 10
} else {
    Write-Output '=== 计划与审批校验 ==='
    foreach ($c in @($result.Checks)) { Write-Output ("[{0}] {1}  {2}" -f $c.result, $c.check, $c.detail) }
    foreach ($l in @($result.Live)) {
        $mark = if ($l.ok) { 'PASS' } else { 'FAIL' }
        Write-Output ("[{0}] live {1}  {2} {3}" -f $mark, $l.id, $l.reason, $l.detail)
    }
    if ($result.Ok) {
        Write-Output ''
        Write-Output ("通过：{0} 项获得有效授权且当前状态与计划一致。" -f @($result.Approved).Count)
    } else {
        Write-Output ''
        Write-Output '拒绝执行，原因：'
        foreach ($e in @($result.Errors)) { Write-Output ("  - {0}" -f $e) }
    }
}

if ($result.Ok) { exit 0 } else { exit 2 }
