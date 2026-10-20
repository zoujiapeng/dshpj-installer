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
    Copy-Item "$assets\patch.yml", "$assets\pj-operator-policy.mjs", "$assets\pj-jailbreak.mjs", "$assets\pj-fact-authority.mjs", "$assets\pj-lan.mjs", "$assets\pj-ip.mjs", "$assets\qrcode.js", "$assets\pj-gateway.yml" "$Root\assets\" -Force
}

# ---- launcher -------------------------------------------------------------
$launcher = @'
$root = Split-Path -Parent $PSScriptRoot
$agentProfile = if ($env:DSHPJ_PROFILE) { $env:DSHPJ_PROFILE } else { 'web' }
$port = if ($env:DSHPJ_PORT) { [int]$env:DSHPJ_PORT } else { 3081 }
$lanPort = if ($env:DSHPJ_LAN_PORT) { [int]$env:DSHPJ_LAN_PORT } else { $port + 1 }
$logDir = Join-Path $root 'pj-logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'dshpj.log'

$dsh = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dsh) { $dsh = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
if (-not $dsh) { Write-Error 'dsh not found: npm i -g @deepseek-ai/dsh'; exit 127 }
$node = (Get-Command node -ErrorAction SilentlyContinue).Source

$patchArgs = @('--profile', $agentProfile, '--patch', "$root\assets\patch.yml")
if ($env:PJ_LLM_BASE_URL) { $patchArgs += @('--patch', "$root\assets\pj-gateway.yml") }

# non-web profile or explicit args: pass straight through to dsh
if ($agentProfile -ne 'web' -or $args.Count -gt 0) {
    & $dsh @patchArgs @args
    exit $LASTEXITCODE
}

$up = $false
try { $up = (Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2).StatusCode -gt 0 } catch { $up = $false }

if (-not $up) {
    $lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.InterfaceAlias -notmatch 'Loopback' } |
        Select-Object -First 1).IPAddress
    $startArgs = $patchArgs + @('--no-open', '--port', "$port")
    if ($lanIp -and -not $env:DSHPJ_NO_LAN) { $startArgs += @('--trusted-host', "${lanIp}:${lanPort}") }
    Start-Process -FilePath $dsh -ArgumentList $startArgs -RedirectStandardOutput $log -RedirectStandardError "$log.err" -WindowStyle Hidden
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 1
        try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$port/" -UseBasicParsing -TimeoutSec 2).StatusCode -gt 0) { break } } catch { }
    }
}

$token = ''
for ($i = 0; $i -lt 20; $i++) {
    if (Test-Path $log) {
        $m = Select-String -Path $log -Pattern 'token=([A-Za-z0-9_-]{8,})' -AllMatches |
            Select-Object -Last 1
        if ($m) { $token = $m.Matches[0].Groups[1].Value }
    }
    if ($token) { break }
    Start-Sleep -Milliseconds 500
}

$localUrl = "http://127.0.0.1:$port/" + $(if ($token) { "?token=$token" } else { "" })
if (-not $env:DSHPJ_NO_OPEN) { try { Start-Process $localUrl } catch { } }
if ($env:DSHPJ_NO_LAN) { Write-Host $localUrl; exit 0 }
& $node "$root\assets\pj-lan.mjs" --target "$port" --listen "$lanPort" --token "$token"
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
