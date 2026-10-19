param([Alias('Home')][string]$Root = "$env:USERPROFILE\.dshpj")
$ErrorActionPreference = 'Continue'
$patch = "$Root\assets\patch.yml"
$fail = @()

Write-Host '[1/3] patch files'
foreach ($f in 'patch.yml', 'pj-operator-policy.mjs', 'pj-jailbreak.mjs', 'pj-fact-authority.mjs') {
    if (Test-Path "$Root\assets\$f") { Write-Host "  ok  $f" } else { Write-Host "  MISSING $f" -ForegroundColor Red; $fail += $f }
}

Write-Host '[2/3] config composition'
$dsh = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dsh) { $dsh = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
if (-not $dsh) { Write-Host '  dsh not in PATH' -ForegroundColor Red; exit 1 }
$dump = & $dsh --profile web --patch $patch --dump-config 2>&1
foreach ($k in 'pj-operator-policy', 'pj-jailbreak', 'pj-fact-authority') {
    if ($dump -match $k) { Write-Host "  ok  $k" } else { Write-Host "  MISSING $k" -ForegroundColor Red; $fail += $k }
}

Write-Host '[3/3] end-to-end assembly'
New-Item -ItemType Directory -Force "$Root\pj-logs" | Out-Null
$env:DSHPJ_PROMPT_DUMP = "$Root\pj-logs\doctor-prompt.txt"
$env:PJ_DEBUG_LOG = "$Root\pj-logs\doctor.log"
Remove-Item $env:DSHPJ_PROMPT_DUMP, $env:PJ_DEBUG_LOG -ErrorAction SilentlyContinue
& $dsh --profile headless --patch $patch "reply with two chars: ok" > $null 2>&1
$prompt = Get-Content $env:DSHPJ_PROMPT_DUMP -Raw -ErrorAction SilentlyContinue
if ($prompt) {
    foreach ($k in 'pj:operator-policy', 'pj:final-authority', 'context:pj:operator-context', 'context:pj:task-frame', 'pj:fact-authority', 'context:pj:fact-authority-context', 'pre-authorized by the machine owner') {
        if ($prompt -match [regex]::Escape($k)) { Write-Host "  ok  $k" } else { Write-Host "  MISSING $k" -ForegroundColor Red; $fail += $k }
    }
} else {
    Write-Host '  skip headless (no profile or no API key; L1-L8 unaffected)' -ForegroundColor Yellow
}

Write-Host ''
if ($fail.Count -eq 0) { Write-Host 'PASS' -ForegroundColor Green } else { Write-Host "FAIL: $($fail -join ', ')" -ForegroundColor Red; exit 1 }
