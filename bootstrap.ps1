# One-line install (Windows):
#   irm https://raw.githubusercontent.com/zoujiapeng/dshpj-installer/main/bootstrap.ps1 | iex
# Optional: -Repo -Ref -Root
param(
    [string]$Repo = 'zoujiapeng/dshpj-installer',
    [string]$Ref = 'main',
    [Alias('Home')][string]$Root = "$env:USERPROFILE\.dshpj"
)
$ErrorActionPreference = 'Stop'

$dsh = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dsh) { $dsh = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
if (-not $dsh) { throw 'dsh not in PATH. Run: npm i -g @deepseek-ai/dsh' }

$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$dir = Join-Path $env:TEMP "dshpj-$stamp"
$base = "https://raw.githubusercontent.com/$Repo/$Ref"
$files = @('install.ps1', 'doctor.ps1', 'assets/patch.yml', 'assets/pj-operator-policy.mjs', 'assets/pj-jailbreak.mjs', 'assets/pj-fact-authority.mjs', 'assets/pj-lan.mjs', 'assets/pj-ip.mjs', 'assets/qrcode.js', 'assets/pj-gateway.yml')

New-Item -ItemType Directory -Force "$dir\assets" | Out-Null
foreach ($f in $files) {
    $dest = Join-Path $dir $f
    $ok = $false
    foreach ($n in 1..4) {
        try {
            Invoke-WebRequest -Uri "$base/$f`?$stamp" -OutFile $dest -UseBasicParsing
            if ((Get-Item $dest).Length -gt 0) { $ok = $true; break }
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $ok) { throw "download failed: $f" }
}
Write-Host "==> fetched $Repo@$Ref, installing"
& "$dir\install.ps1" -Root $Root
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
