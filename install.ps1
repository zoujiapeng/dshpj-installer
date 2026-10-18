param(
    [Alias('Home')][string]$Root = "$env:USERPROFILE\.dshpj",
    [switch]$SkipProfile,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets = Join-Path $src 'assets'

Write-Host "==> 安装到 $Root"
if ($DryRun) { Write-Host "(dry run，不写盘)" }

if (-not $DryRun) {
    New-Item -ItemType Directory -Force "$Root\assets", "$Root\bin", "$Root\pj-logs" | Out-Null
    Copy-Item "$assets\patch.yml", "$assets\pj-operator-policy.mjs", "$assets\pj-jailbreak.mjs", "$assets\pj-gateway.yml" "$Root\assets\" -Force
}

# ---- 启动器 ---------------------------------------------------------------
$launcher = @'
$root = Split-Path -Parent $PSScriptRoot
$agentProfile = if ($env:DSHPJ_PROFILE) { $env:DSHPJ_PROFILE } else { 'web' }
$dsh = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dsh) { $dsh = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
if (-not $dsh) { Write-Error 'dsh not found: npm i -g @deepseek-ai/dsh'; exit 127 }
$patchArgs = @('--profile', $agentProfile, '--patch', "$root\assets\patch.yml")
if ($env:PJ_LLM_BASE_URL) { $patchArgs += @('--patch', "$root\assets\pj-gateway.yml") }
& $dsh @patchArgs @args
'@
$cmd = @'
@echo off
set "PS=pwsh"
where pwsh >nul 2>nul || set "PS=powershell"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0dshpj.ps1" %*
'@
if (-not $DryRun) {
    Set-Content "$Root\bin\dshpj.ps1" $launcher -Encoding utf8
    Set-Content "$Root\bin\dshpj.cmd" $cmd -Encoding ascii
    Copy-Item (Join-Path $src 'doctor.ps1') "$Root\bin\doctor.ps1" -Force
}

# ---- PowerShell profile 函数 ---------------------------------------------
if (-not $SkipProfile -and -not $DryRun) {
    $block = "`n# dshpj — 无限制 DSH（补丁只在命令行加载，不改 profile 文件）`nfunction dshpj { & `"$Root\bin\dshpj.ps1`" @args }`nfunction dshpj-doctor { & `"$Root\bin\doctor.ps1`" @args }`n"
    $profilePath = $PROFILE.CurrentUserAllHosts
    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    if ($existing -notmatch [regex]::Escape("$Root\bin\dshpj.ps1")) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $profilePath) | Out-Null
        Add-Content -Path $profilePath -Value $block -Encoding utf8
        Write-Host "==> 已写入 $profilePath"
    }
}

Write-Host ''
Write-Host "装好了。重开 PowerShell，或 . `$PROFILE，然后："
Write-Host "  dshpj              # 启动"
Write-Host "  dshpj-doctor       # 升级后自检"
Write-Host ''
Write-Host "DSH_HOME 没动，补丁只加在 dshpj 这条命令行上；原版 dsh 不受影响。"
