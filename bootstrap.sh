#!/usr/bin/env bash
# 一行安装：curl -fsSL https://raw.githubusercontent.com/zoujiapeng/dshpj-installer/main/bootstrap.sh | bash
# 可选环境变量：DSHPJ_HOME（装到哪）、DSHPJ_REPO、DSHPJ_REF
#
# 不用 tar 包：直接逐个下载很小的文本文件，网络抖动能按文件重试。
set -euo pipefail

REPO="${DSHPJ_REPO:-zoujiapeng/dshpj-installer}"
REF="${DSHPJ_REF:-main}"
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"
FILES="install.sh doctor.ps1 assets/patch.yml assets/pj-operator-policy.mjs assets/pj-jailbreak.mjs assets/pj-gateway.yml"
STAMP="$(date +%s)"

command -v curl >/dev/null || { echo "需要 curl：pkg install curl / apt install curl" >&2; exit 1; }
command -v dsh  >/dev/null || { echo "dsh 不在 PATH，先：npm i -g @deepseek-ai/dsh" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/assets"

for f in $FILES; do
  ok=0
  for n in 1 2 3 4; do
    if curl -fsSL --connect-timeout 15 --max-time 120 \
         -o "$TMP/repo/$f" "$BASE/$f?$STAMP" 2>/dev/null && [ -s "$TMP/repo/$f" ]; then
      ok=1; break
    fi
    echo "   重试 $f ($n/4)" >&2
    sleep 2
  done
  [ "$ok" = 1 ] || { echo "下载失败：$f" >&2; exit 1; }
done

echo "==> 已下载 $REPO@$REF，开始安装"
DSHPJ_HOME="$ROOT" bash "$TMP/repo/install.sh"
