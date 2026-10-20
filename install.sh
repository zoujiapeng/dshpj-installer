#!/usr/bin/env bash
# dshpj 安装器 — Linux / Termux / macOS
# 用法: bash install.sh            (默认装到 ~/.dshpj)
#       DSHPJ_HOME=/path bash install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Termux 上没有 /usr/bin/env；su 逃逸后 LD_PRELOAD 被清掉，#!/usr/bin/env bash 会
# 直接 bad interpreter。生成脚本时一律写死绝对 bash 路径。
BASH_BIN="$(command -v bash || true)"
[ -n "$BASH_BIN" ] || BASH_BIN=/bin/bash
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"

echo "==> 安装到 $ROOT"
mkdir -p "$ROOT/assets" "$ROOT/bin" "$ROOT/pj-logs"
cp "$SRC/assets/patch.yml" "$SRC/assets/pj-operator-policy.mjs" \
   "$SRC/assets/pj-jailbreak.mjs" "$SRC/assets/pj-fact-authority.mjs" \
   "$SRC/assets/pj-lan.mjs" "$SRC/assets/pj-ip.mjs" "$SRC/assets/qrcode.js" \
   "$SRC/assets/pj-gateway.yml" "$ROOT/assets/"

# ---- 启动器 ----------------------------------------------------------------
cat > "$ROOT/bin/dshpj" <<'LAUNCHER'
#!/usr/bin/env bash
# dshpj — 带补丁栈的 dsh，并把前端开到局域网（终端出网址 + 二维码）。
#
#   dshpj                     默认 web：后台起服务 + 前台跑局域网转发
#   DSHPJ_PROFILE=tui dshpj   换 profile，直通 dsh，不转发
#   DSHPJ_PORT=3081           本机端口（局域网端口自动 +1）
#   DSHPJ_LAN_PORT=3082       显式指定局域网端口
#   DSHPJ_NO_LAN=1            只起本机服务，不转发
set -euo pipefail
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"
PROFILE="${DSHPJ_PROFILE:-web}"
PORT="${DSHPJ_PORT:-3081}"
LAN_PORT="${DSHPJ_LAN_PORT:-$((PORT + 1))}"
PORT_SCAN="${DSHPJ_PORT_SCAN:-40}"
LOG="$ROOT/pj-logs/dshpj.log"
mkdir -p "$ROOT/pj-logs"
touch "$LOG"

DSH_BIN="$(command -v dsh || true)"
[ -n "$DSH_BIN" ] || { echo "[dshpj] dsh 不在 PATH：npm i -g @deepseek-ai/dsh" >&2; exit 127; }
NODE_BIN="$(command -v node || true)"
[ -n "$NODE_BIN" ] || { echo "[dshpj] node 不在 PATH" >&2; exit 127; }

args=(--profile "$PROFILE" --patch "$ROOT/assets/patch.yml")
[ -n "${PJ_LLM_BASE_URL:-}" ] && args+=(--patch "$ROOT/assets/pj-gateway.yml")

# 非 web，或显式带了参数：直通 dsh，行为和原版一致
if [ "$PROFILE" != "web" ] || [ "$#" -gt 0 ]; then
  exec "$DSH_BIN" "${args[@]}" "$@"
fi

lan_ip() {
  "$NODE_BIN" -e '
    const os = require("os");
    const out = [];
    for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
      for (const a of addrs || []) {
        if (a.family !== "IPv4" || a.internal) continue;
        let s = 0;
        if (a.address.startsWith("192.168.")) s = 30;
        else if (a.address.startsWith("10.")) s = 20;
        else if (/^172\.(1[6-9]|2\d|3[01])\./.test(a.address)) s = 10;
        if (/^(tun|utun|tailscale|wg)/i.test(name)) s -= 15;
        out.push([s, a.address]);
      }
    }
    out.sort((x, y) => y[0] - x[0]);
    if (out.length) process.stdout.write(out[0][1]);
  ' 2>/dev/null || true
}
IP="$(lan_ip)"

# 和原版 dsh web 一样：起完自动开浏览器。termux-open-url / xdg-open / open / am 依次尝试。
open_url() {
  local url="$1"
  [ "${DSHPJ_NO_OPEN:-0}" = "1" ] && return 0
  if command -v termux-open-url >/dev/null 2>&1 && termux-open-url "$url" >/dev/null 2>&1; then return 0; fi
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v open >/dev/null 2>&1 && open "$url" >/dev/null 2>&1; then return 0; fi
  if command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1; then return 0; fi
  if command -v am >/dev/null 2>&1 && am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1; then return 0; fi
  return 1
}

# 端口占用探测（不依赖 ss/netstat，Windows/WSL/macOS 都有 node）
port_free() {
  "$NODE_BIN" -e 'const n=require("net");const s=n.createServer();s.once("error",()=>process.exit(1));s.listen(+process.argv[1],"0.0.0.0",()=>s.close(()=>process.exit(0)))' "$1" 2>/dev/null
}
is_dsh_on() {
  curl -s --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null | grep -q '__DSH_BOOT__'
}
pick_server_port() {
  local p
  if is_dsh_on "$PORT"; then printf '%s' "$PORT"; return 0; fi
  for p in $(seq "$PORT" $((PORT + PORT_SCAN))); do
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}
pick_lan_port() {
  local p
  for p in $(seq "$LAN_PORT" $((LAN_PORT + PORT_SCAN))); do
    if port_free "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null || true; }

START_LINES=0
if ! is_dsh_on "$PORT"; then
  PORT="$(pick_server_port)" || { echo "[dshpj] $PORT..$((PORT+PORT_SCAN)) 全被占用，用 DSHPJ_PORT 指定一个空闲端口" >&2; exit 1; }
  START_LINES="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
  echo "[dshpj] starting patched dsh (profile=$PROFILE port=$PORT)"
  start=( "${args[@]}" --no-open --port "$PORT" )
  [ -n "$IP" ] && [ "${DSHPJ_NO_LAN:-0}" != "1" ] && start+=( --trusted-host "$IP:$LAN_PORT" )
  setsid nohup "$DSH_BIN" "${start[@]}" >>"$LOG" 2>&1 </dev/null &
  echo $! > "$LOG.pid"
  for _ in $(seq 1 40); do
    [ "$(http_code)" = "000" ] || break
    sleep 1
  done
  if [ "$(http_code)" = "000" ]; then
    echo "[dshpj] 启动失败，最后几行日志：" >&2
    tail -15 "$LOG" >&2
    exit 1
  fi
fi

TOKEN=""
for _ in $(seq 1 20); do
  TOKEN="$(tail -n "+$((START_LINES + 1))" "$LOG" 2>/dev/null | grep -o 'token=[A-Za-z0-9_-]\{8,\}' | tail -1 | cut -d= -f2 || true)"
  [ -n "$TOKEN" ] && break
  sleep 0.5
done

LOCAL_URL="http://127.0.0.1:$PORT/${TOKEN:+?token=$TOKEN}"

if [ "${DSHPJ_NO_LAN:-0}" = "1" ] || [ -z "$IP" ]; then
  open_url "$LOCAL_URL" || true
  echo "[dshpj] $LOCAL_URL"
  exit 0
fi

# 局域网代理自己持 cookie，客户端 URL 里不带任何 token。
# 先起代理、等它监听，再开浏览器；前台等代理，Ctrl-C 只停代理，后台服务还在。
LAN_PORT="$(pick_lan_port)" || { echo "[dshpj] 局域网端口 $LAN_PORT 起被占满，用 DSHPJ_LAN_PORT 指定" >&2; exit 1; }

# 代理守护：异常退出就重起（浏览器刷新会掐断 SSE，早前一次 ECONNRESET 就能把整个
# 代理带走，用户看到的就是"页面空白、会话消失"）。这里保证它死了会自己回来。
LAN_PID=""
supervise() {
  trap 'kill ${LAN_PID:-0} 2>/dev/null; exit 0' INT TERM
  local rc=0
  while :; do
    # 放进 if 里，set -e 才不会在代理非 0 退出时把守护循环一起干掉
    if "$NODE_BIN" "$ROOT/assets/pj-lan.mjs" --target "$PORT" --listen "$LAN_PORT" --token "$TOKEN" --log "$LOG.lan-req"; then
      break
    else
      rc=$?
    fi
    echo "[dshpj] 局域网代理退出（$rc），1 秒后重启"
    sleep 1
  done
}
supervise &
SUP_PID=$!
LAN_PID=$SUP_PID
echo $LAN_PID > "$LOG.lan.pid"

for _ in $(seq 1 40); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$LAN_PORT/" 2>/dev/null || true)" != "000" ] && break
  sleep 0.2
done
open_url "http://127.0.0.1:$LAN_PORT/" || echo "[dshpj] 打不开浏览器，手动访问：http://127.0.0.1:$LAN_PORT/"
wait $SUP_PID
LAUNCHER
sed -i.tmp "1s|.*|#!$BASH_BIN|" "$ROOT/bin/dshpj" && rm -f "$ROOT/bin/dshpj.tmp"
chmod +x "$ROOT/bin/dshpj"

cat > "$ROOT/bin/dshpj-doctor" <<'DOCTOR'
#!/usr/bin/env bash
set -uo pipefail
ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"
P="$ROOT/assets/patch.yml"
fail=0
echo "[1/3] 补丁文件"
for f in "$ROOT/assets/patch.yml" "$ROOT/assets/pj-operator-policy.mjs" \
         "$ROOT/assets/pj-jailbreak.mjs" "$ROOT/assets/pj-fact-authority.mjs" \
         "$ROOT/assets/pj-lan.mjs" "$ROOT/assets/pj-ip.mjs" "$ROOT/assets/qrcode.js"; do
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
  || echo "  skip headless（profile 不存在或无 key，不影响判断）"
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
sed -i.tmp "1s|.*|#!$BASH_BIN|" "$ROOT/bin/dshpj-doctor" && rm -f "$ROOT/bin/dshpj-doctor.tmp"
chmod +x "$ROOT/bin/dshpj-doctor"

# ---- PATH -----------------------------------------------------------------
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  [ -f "$rc" ] || continue
  grep -q 'dshpj/bin' "$rc" 2>/dev/null && continue
  printf '\n# dshpj\nexport PATH="%s/bin:$PATH"\n' "$ROOT" >> "$rc"
  echo "==> 已写入 $rc"
done

echo
echo "装好了。重开终端或 source ~/.bashrc，然后："
echo "  dshpj                     # 起服务 + 局域网网址 + 二维码"
echo "  dshpj-doctor              # 自检"
echo "  DSHPJ_PROFILE=tui dshpj   # 换 profile"
if [ -e "$HOME/.dsh" ]; then
  echo
  echo "注意：DSH_HOME 没动，用的还是你自己的 ~/.dsh，补丁只加在这条命令行上。"
fi
exit 0
