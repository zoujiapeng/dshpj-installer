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
URL="https://github.com/$REPO/archive/refs/heads/$REF.tar.gz"
echo "==> 下载 $URL"
curl -fsSL "$URL" | tar xz -C "$TMP"
SRC="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
[ -f "$SRC/install.sh" ] || { echo "压缩包结构不对：$SRC" >&2; exit 1; }

DSHPJ_HOME="$ROOT" bash "$SRC/install.sh"
