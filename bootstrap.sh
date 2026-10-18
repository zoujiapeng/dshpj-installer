#!/usr/bin/env bash
# 一行安装：curl -fsSL https://raw.githubusercontent.com/zoujiapeng/dshpj-installer/main/bootstrap.sh | bash
# 可选环境变量：DSHPJ_HOME（装到哪）、DSHPJ_REPO、DSHPJ_REF
set -euo pipefail

REPO="${DSHPJ_REPO:-zoujiapeng/dshpj-installer}"
REF="${DSHPJ_REF:-main}"
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"

command -v curl >/dev/null || { echo "需要 curl：pkg install curl / apt install curl" >&2; exit 1; }
command -v tar  >/dev/null || { echo "需要 tar" >&2; exit 1; }
command -v dsh  >/dev/null || { echo "dsh 不在 PATH，先：npm i -g @deepseek-ai/dsh" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TGZ="$TMP/src.tgz"

fetch() {
  local url="$1" n=0
  while [ "$n" -lt 4 ]; do
    n=$((n + 1))
    if curl -fsSL --connect-timeout 15 --max-time 900 -o "$TGZ" "$url" && gzip -t "$TGZ" 2>/dev/null; then
      return 0
    fi
    echo "   重试 $n/4（下载被截断或连接失败）" >&2
    rm -f "$TGZ"
    sleep 2
  done
  return 1
}

echo "==> 下载 $REPO@$REF"
fetch "https://codeload.github.com/$REPO/tar.gz/refs/heads/$REF" \
  || fetch "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" \
  || { echo "下载失败，检查网络后重试" >&2; exit 1; }

gzip -t "$TGZ" 2>/dev/null || { echo "压缩包不完整（下载被截断），重试一次" >&2; exit 1; }
tar xzf "$TGZ" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -f "$SRC/install.sh" ] || { echo "压缩包结构不对：$SRC" >&2; exit 1; }

DSHPJ_HOME="$ROOT" bash "$SRC/install.sh"
