#!/usr/bin/env bash
# dshpj 安装器 — Linux / Termux / macOS
# 用法: bash install.sh            (默认装到 ~/.dshpj)
#       DSHPJ_HOME=/path bash install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"

echo "==> 安装到 $ROOT"
mkdir -p "$ROOT/assets" "$ROOT/bin" "$ROOT/pj-logs"
cp "$SRC/assets/patch.yml" "$SRC/assets/pj-operator-policy.mjs" \
   "$SRC/assets/pj-jailbreak.mjs" "$SRC/assets/pj-fact-authority.mjs" \
   "$SRC/assets/pj-gateway.yml" "$ROOT/assets/"

# ---- 启动器 ----------------------------------------------------------------
cat > "$ROOT/bin/dshpj" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"
AGENT_PROFILE="${DSHPJ_PROFILE:-web}"
command -v dsh >/dev/null 2>&1 || { echo "dsh not found: npm i -g @deepseek-ai/dsh" >&2; exit 127; }
args=(--profile "$AGENT_PROFILE" --patch "$ROOT/assets/patch.yml")
[ -n "${PJ_LLM_BASE_URL:-}" ] && args+=(--patch "$ROOT/assets/pj-gateway.yml")
exec "$(command -v dsh)" "${args[@]}" "$@"
LAUNCHER
chmod +x "$ROOT/bin/dshpj"

cat > "$ROOT/bin/dshpj-doctor" <<'DOCTOR'
#!/usr/bin/env bash
set -uo pipefail
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"
P="$ROOT/assets/patch.yml"
fail=0
echo "[1/3] 补丁文件"
for f in "$ROOT/assets/patch.yml" "$ROOT/assets/pj-operator-policy.mjs" \
         "$ROOT/assets/pj-jailbreak.mjs" "$ROOT/assets/pj-fact-authority.mjs"; do
  [ -f "$f" ] && echo "  ok  $(basename "$f")" || { echo "  MISSING $(basename "$f")"; fail=1; }
done
echo "[2/3] 配置装配"
command -v dsh >/dev/null 2>&1 || { echo "  dsh 不在 PATH"; exit 1; }
out="$(dsh --profile web --patch "$P" --dump-config 2>&1)"
echo "$out" | grep -q 'pj-operator-policy' && echo "  ok  pj-operator-policy" || { echo "  MISSING pj-operator-policy"; fail=1; }
echo "$out" | grep -q 'pj-jailbreak' && echo "  ok  pj-jailbreak" || { echo "  MISSING pj-jailbreak"; fail=1; }
echo "$out" | grep -q 'pj-fact-authority' && echo "  ok  pj-fact-authority" || { echo "  MISSING pj-fact-authority"; fail=1; }
echo "[3/3] 端到端装配"
mkdir -p "$ROOT/pj-logs"
DSHPJ_PROMPT_DUMP="$ROOT/pj-logs/doctor-prompt.txt" PJ_DEBUG_LOG="$ROOT/pj-logs/doctor.log" \
  dsh --profile headless --patch "$P" "只回复两个字：收到" >/dev/null 2>&1 && echo "  ok  headless 跑通" \
  || echo "  skip headless（profile 不存在或无 key，不影响 L1-L8 判断）"
pr="$ROOT/pj-logs/doctor-prompt.txt"
if [ -f "$pr" ]; then
  for k in 'pj:operator-policy' 'pj:final-authority' 'context:pj:operator-context' \
           'context:pj:task-frame' 'pj:fact-authority' 'context:pj:fact-authority-context' \
           'pre-authorized by the machine owner'; do
    grep -qF "$k" "$pr" && echo "  ok  $k" || { echo "  MISSING $k"; fail=1; }
  done
fi
[ "$fail" -eq 0 ] && echo && echo "PASS" || { echo; echo "FAIL — 看上面 MISSING 那行"; exit 1; }
DOCTOR
chmod +x "$ROOT/bin/dshpj-doctor"

# ---- 重启脚本 --------------------------------------------------------------
cp "$SRC/pj-restart.sh" "$ROOT/bin/pj-restart.sh"
chmod +x "$ROOT/bin/pj-restart.sh"

# ---- PATH -----------------------------------------------------------------
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || [ "$rc" = "$HOME/.bashrc" ] || continue
  grep -q 'dshpj/bin' "$rc" 2>/dev/null && continue
  printf '\n# dshpj\nexport PATH="%s/bin:$PATH"\n' "$ROOT" >> "$rc"
  echo "==> 已写入 $rc"
done

echo
echo "装好了。重开终端或 source ~/.bashrc，然后："
echo "  dshpj                     # 启动（默认 web）"
echo "  dshpj tui                 # 走别的 profile：dshpj <profile> 不行，用 DSHPJ_PROFILE=tui dshpj"
echo "  dshpj-doctor              # 升级后自检"
if [ -e "$HOME/.dsh" ]; then
  echo
  echo "注意：DSH_HOME 没动，用的还是你自己的 ~/.dsh，补丁只加在这条命令行上。"
fi
exit 0
