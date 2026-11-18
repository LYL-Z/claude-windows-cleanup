# preflight.ps1 — 环境基线（只读）
# 记录运行环境、受保护资源存在性、Claude 相关根目录状态与 Skill 源码指纹。
# 不读取任何文件内容，不修改任何系统状态。

[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\Core.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $skillRoot 'config\scope.json'
$protectPath = Join-Path $skillRoot 'config\protected-resources.json'

function Exit-With {
    param([int]$Code)
    exit $Code
}

if (-not (Test-Path -LiteralPath $configPath)) { Write-Error "缺少配置：$configPath"; Exit-With 3 }
if (-not (Test-Path -LiteralPath $protectPath)) { Write-Error "缺少配置：$protectPath"; Exit-With 3 }

$config = Read-CwcJson -Path $configPath
$protection = Read-CwcJson -Path $protectPath
if ($null -eq $config -or $null -eq $protection) { Write-Error '配置无法解析'; Exit-With 3 }

Write-Output '=== claude-windows-cleanup / preflight (read-only) ==='

$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { $os = $null }

$isAdmin = $false
try {
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $isAdmin = $false }

# Skill 源码指纹见 lib/Core.ps1 的 Get-CwcSkillFingerprint

$protectedState = @()
foreach ($r in (Get-ProtectedRootSet -Protection $protection)) {
    $exists = Test-Path -LiteralPath $r.Path
    $protectedState += [pscustomobject]@{
        path    = $r.Path
        reason  = $r.Reason
        exists  = $exists
        reparse = if ($exists) { Test-ReparseItem -Path $r.Path } else { $false }
    }
}

$allowedState = @()
foreach ($r in (Get-AllowedRootSet -Config $config)) {
    $exists = Test-Path -LiteralPath $r.Path
    $allowedState += [pscustomobject]@{
        id      = $r.Id
        kind    = $r.Kind
        path    = $r.Path
        exists  = $exists
        reparse = if ($exists) { Test-ReparseItem -Path $r.Path } else { $false }
    }
}

$quarantineRoot = Expand-CwcPath -Template ([string]$config.quarantine_root)
$quarantineFull = Get-NormalizedPath -Path $quarantineRoot

$baseline = [ordered]@{
    schema_version   = 1
    skill_name       = 'claude-windows-cleanup'
    generated_at     = (Get-CwcTimestamp)
    host             = $env:COMPUTERNAME
    user             = $env:USERNAME
    os               = [ordered]@{
        caption = if ($os) { [string]$os.Caption } else { '' }
        version = [string][Environment]::OSVersion.Version
        build   = if ($os) { [string]$os.BuildNumber } else { '' }
        arch    = [string]$env:PROCESSOR_ARCHITECTURE
    }
    powershell       = [ordered]@{ version = [string]$PSVersionTable.PSVersion; edition = [string]$PSVersionTable.PSEdition }
    is_admin         = $isAdmin
    skill            = [ordered]@{
        root       = $skillRoot
        fingerprint = (Get-CwcSkillFingerprint -SkillRoot $skillRoot)
        config_sha = (Get-FileSha256 -Path $configPath)
        protection_sha = (Get-FileSha256 -Path $protectPath)
    }
    paths            = [ordered]@{
        local_appdata = $env:LOCALAPPDATA
        appdata       = $env:APPDATA
        program_data  = $env:ProgramData
        user_profile  = $env:USERPROFILE
    }
    quarantine       = [ordered]@{
        configured = $quarantineFull
        volume     = if ($quarantineFull) { [System.IO.Path]::GetPathRoot($quarantineFull) } else { '' }
        exists     = if ($quarantineFull) { Test-Path -LiteralPath $quarantineFull } else { $false }
    }
    allowed_roots    = $allowedState
    protected_roots  = $protectedState
}

$outDir = Join-Path $skillRoot 'reports'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $outDir ('baseline-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
}

try {
    $null = Write-CwcJsonAtomic -Path $OutputPath -Object $baseline
} catch {
    Write-Error ("基线写入失败：{0}" -f $_.Exception.Message)
    Exit-With 1
}

Write-Output ("OS            : {0} build {1}" -f $baseline.os.caption, $baseline.os.build)
Write-Output ("PowerShell    : {0} ({1})" -f $baseline.powershell.version, $baseline.powershell.edition)
Write-Output ("Administrator : {0}" -f $isAdmin)
Write-Output ("Skill root    : {0}" -f $skillRoot)
Write-Output ("Fingerprint   : {0}" -f $baseline.skill.fingerprint)
Write-Output ("Quarantine    : {0}" -f $quarantineFull)
Write-Output ''
Write-Output 'Claude 相关根目录：'
foreach ($r in $allowedState) {
    Write-Output ("  [{0}] {1,-12} exists={2,-5} {3}" -f $r.id, $r.kind, $r.exists, $r.path)
}
$missingProtected = @($protectedState | Where-Object { -not $_.exists })
Write-Output ("受保护资源      : {0} 项存在 / {1} 项不存在（不读取内容）" -f @($protectedState | Where-Object { $_.exists }).Count, $missingProtected.Count)
Write-Output ''
Write-Output ("基线已写入：{0}" -f $OutputPath)

Write-CwcAudit -SkillRoot $skillRoot -Action 'preflight' -Fields @{
    baseline = $OutputPath
    is_admin = $isAdmin
    fingerprint = $baseline.skill.fingerprint
}

exit 0
