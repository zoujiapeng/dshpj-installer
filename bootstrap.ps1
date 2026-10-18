# 一行安装（Windows）：
#   irm https://raw.githubusercontent.com/zoujiapeng/dshpj-installer/main/bootstrap.ps1 | iex
# 可选参数：-Repo -Ref -Root
param(
    [string]$Repo = 'zoujiapeng/dshpj-installer',
    [string]$Ref = 'main',
    [Alias('Home')][string]$Root = "$env:USERPROFILE\.dshpj"
)
$ErrorActionPreference = 'Stop'

$dsh = (Get-Command dsh.cmd -ErrorAction SilentlyContinue).Source
if (-not $dsh) { $dsh = (Get-Command dsh -ErrorAction SilentlyContinue).Source }
if (-not $dsh) { throw 'dsh 不在 PATH，先跑：npm i -g @deepseek-ai/dsh' }

$stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
$zip = Join-Path $env:TEMP "dshpj-$stamp.zip"
$dir = Join-Path $env:TEMP "dshpj-$stamp"
$url = "https://github.com/$Repo/archive/refs/heads/$Ref.zip"
Write-Host "==> 下载 $url"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $dir -Force
$src = Get-ChildItem $dir -Directory | Select-Object -First 1
if (-not (Test-Path "$($src.FullName)\install.ps1")) { throw "压缩包结构不对：$($src.FullName)" }
& "$($src.FullName)\install.ps1" -Root $Root
Remove-Item -Recurse -Force $zip, $dir -ErrorAction SilentlyContinue
