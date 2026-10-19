param(
    [Alias('Home')][string]$Root = "$env:USERPROFILE\.dshpj",
    [switch]$SkipProfile,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets = Join-Path $src 'assets'

Write-Host "==> installing to $Root"
if ($DryRun) { Write-Host "(dry run, nothing written)" }

if (-not $DryRun) {
    New-Item -ItemType Directory -Force "$Root\assets", "$Root\bin", "$Root\pj-logs" | Out-Null
    Copy-Item "$assets\patch.yml", "$assets\pj-operator-policy.mjs", "$assets\pj-jailbreak.mjs", "$assets\pj-fact-authority.mjs", "$assets\pj-gateway.yml" "$Root\assets\" -Force
}

# ---- launcher -------------------------------------------------------------
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

# ---- PowerShell profile functions ----------------------------------------
if (-not $SkipProfile -and -not $DryRun) {
    $block = "`n# dshpj - unrestricted DSH (patches load from the command line only)`nfunction dshpj { & `"$Root\bin\dshpj.ps1`" @args }`nfunction dshpj-doctor { & `"$Root\bin\doctor.ps1`" @args }`n"
    $profilePath = $PROFILE.CurrentUserAllHosts
    $existing = if (Test-Path $profilePath) { Get-Content $profilePath -Raw } else { '' }
    if ($existing -notmatch [regex]::Escape("$Root\bin\dshpj.ps1")) {
        New-Item -ItemType Directory -Force (Split-Path -Parent $profilePath) | Out-Null
        Add-Content -Path $profilePath -Value $block -Encoding utf8
        Write-Host "==> wrote $profilePath"
    }
}

Write-Host ''
Write-Host 'installed. Reopen PowerShell (or dot-source $PROFILE), then:'
Write-Host '  dshpj              # start'
Write-Host '  dshpj-doctor       # self-check after a dsh upgrade'
Write-Host ''
Write-Host 'DSH_HOME untouched; patches are passed on the dshpj command line only.'
