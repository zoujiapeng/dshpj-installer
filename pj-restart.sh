#!/data/data/com.termux/files/usr/bin/bash
# pj-restart.sh — 用新补丁栈重启 127.0.0.1:3081 上的 dshpj 服务。
#
# 为什么要 detach：agent 本身是 3081 那个 node 进程的子进程，直接 kill 会把
# 正在生成回答的这条链路一起打断。所以由调用方 setsid 挂一个延时任务，
# 等当前回话结束后再执行。
#
# 用法：
#   DELAY=45 setsid nohup pj-restart.sh >/dev/null 2>&1 &
#
# 报告：~/.dshpj/pj-logs/restart-report.txt（最后一次重启的结果）
# 日志：~/.dshpj/pj-logs/restart.log（追加）
set -uo pipefail

export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export TMPDIR="$PREFIX/tmp"
export PATH="$PREFIX/bin:$PREFIX/bin/applets:$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib"
export LD_PRELOAD="$PREFIX/lib/libtermux-exec.so"
export LANG="${LANG:-en_US.UTF-8}"
cd "$HOME" 2>/dev/null || cd /

ROOT="${DSHPJ_HOME:-$HOME/.dshpj}"
PORT="${DSHPJ_PORT:-3081}"
LOG_DIR="$ROOT/pj-logs"
LOG="$LOG_DIR/dshpj.log"
PIDFILE="${DSHPJ_PIDFILE:-$LOG.pid}"
ENTRY="$ROOT/bin/dshpj-entry.mjs"
PATCH="$ROOT/assets/patch.yml"
NODE="$PREFIX/bin/node"
REPORT="$LOG_DIR/restart-report.txt"
DELAY="${DELAY:-45}"

mkdir -p "$LOG_DIR"
: >"$REPORT"
say() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$REPORT" >>"$LOG_DIR/restart.log"; }

say "restart scheduled: delay=${DELAY}s port=$PORT"
sleep "$DELAY"

old="$(cat "$PIDFILE" 2>/dev/null || true)"
say "old pid=${old:-none}"

# 只认 3081 上那个 dshpj-entry 进程，pid 文件过期就不碰
if [ -n "${old:-}" ] && [ -r "/proc/$old/cmdline" ] &&
   tr '\0' ' ' <"/proc/$old/cmdline" | grep -q 'dshpj-entry.mjs'; then
  kill -TERM "$old" 2>/dev/null
  for _ in $(seq 1 20); do
    [ -d "/proc/$old" ] || break
    sleep 1
  done
  if [ -d "/proc/$old" ]; then
    say "old pid $old did not exit on TERM, sending KILL"
    kill -KILL "$old" 2>/dev/null
    sleep 2
  fi
  say "old pid stopped: $([ -d "/proc/$old" ] && echo NO || echo yes)"
else
  say "pid file stale or empty; nothing to stop"
fi

for _ in $(seq 1 20); do
  ss -lnt 2>/dev/null | grep -q ":$PORT " || break
  sleep 1
done
if ss -lnt 2>/dev/null | grep -q ":$PORT "; then
  say "ABORT: port $PORT still bound, not starting a second server"
  exit 1
fi
say "port $PORT free"

say "patch entries: $(grep -c 'id: pj-' "$PATCH" 2>/dev/null || echo '?')"
say "plugin files: $(ls "$ROOT/assets"/*.mjs 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"

# 启动就走 dshpj 本体：它自己拿 patch.yml、自己 daemon 化、自己写 pid 文件，
# 手工拼 node 命令只会和 launcher 漂移。
export DSHPJ_NO_OPEN=1
export DSHPJ_ROOTED=1
export DSHPJ_PROMPT_DUMP="$LOG_DIR/web-prompt.txt"
say "starting: dshpj (profile=${DSHPJ_PROFILE:-web} port=$PORT)"
out="$("$PREFIX/bin/dshpj" 2>&1)"; rc=$?
say "dshpj exit=$rc: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"

code=000
for i in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null || true)"
  [ "$code" != "000" ] && { say "answered after ${i}s (http $code)"; break; }
  sleep 1
done

if [ "$code" = "000" ]; then
  say "FAIL: no answer after 60s; last log lines:"
  tail -15 "$LOG" >>"$REPORT"
  exit 1
fi

new="$(cat "$PIDFILE" 2>/dev/null || true)"
say "new pid=${new:-none} alive=$([ -n "${new:-}" ] && [ -d "/proc/$new" ] && echo yes || echo NO)"
say "cmdline: $(tr '\0' ' ' <"/proc/${new:-0}/cmdline" 2>/dev/null || echo '?')"
say "sections will be dumped to $DSHPJ_PROMPT_DUMP on the next message"
say "READY http://127.0.0.1:$PORT/"
