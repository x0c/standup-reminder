#!/bin/bash
set -euo pipefail

# standup-reminder —— macOS 久坐提醒守护脚本
# - 解锁后开始计时；锁屏 / 屏保 / 系统休眠唤醒后重置
# - 超时后隐藏窗口、弹出提示、启动屏保
# - 判断失败时按「正在使用」处理，避免静默从不提醒

VERSION="0.2.0"

REMINDER_INTERVAL=${REMINDER_INTERVAL:-2700}
REMINDER_MESSAGE=${REMINDER_MESSAGE:-"起身走动一下~"}
STATE_DIR=${STATE_DIR:-"$HOME/Library/Application Support/standup-reminder"}
LOG_FILE=${LOG_FILE:-"$STATE_DIR/run.log"}
PID_FILE="$STATE_DIR/standup_reminder.pid"
STATE_FILE="$STATE_DIR/state"
LAUNCH_LABEL="io.github.x0c.standup-reminder"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/${LAUNCH_LABEL}.plist"

STANDUP_DRY_RUN=${STANDUP_DRY_RUN:-0}

JSON_MODE=0
POLL_SECONDS=10
STATE_STALE_AFTER=30
HEARTBEAT_EVERY=6
LOCKED_HEARTBEAT_EVERY=60

usage() {
  cat <<EOF
standup-reminder $VERSION —— macOS 久坐提醒守护脚本

用法:
  standup-reminder [start]     启动守护循环（前台运行，通常由登录项托管）
  standup-reminder status      查看是否在运行、是否在计时、距下次提醒多久
  standup-reminder doctor      自检：装上了但从不响，先跑这条
  standup-reminder now         立刻试响一次（确认弹窗/屏保真能出来）
  standup-reminder stop        停止守护进程并卸掉登录项
  standup-reminder --dry-run   以演练模式启动（只记日志，不弹窗/不启屏保）
  standup-reminder --json      与 status / doctor 联用，输出机器可读结果
  standup-reminder --help      显示本帮助
  standup-reminder --version   显示版本号

环境变量:
  REMINDER_INTERVAL   连续使用多久后提醒（秒），默认 2700（45 分钟）
  REMINDER_MESSAGE    提醒弹窗文案，默认 "起身走动一下~"
  STATE_DIR           状态与日志目录
  LOG_FILE            日志文件路径
  STANDUP_DRY_RUN     置 1 时只记日志，不隐藏窗口/不弹提醒/不启屏保

日志:
  tail -f "$LOG_FILE"
EOF
}

log() {
  mkdir -p "$(/usr/bin/dirname "$LOG_FILE")"
  # shellcheck disable=SC2059
  printf '%s %s\n' "$(/bin/date '+%F %T')" "$*" >>"$LOG_FILE"
}

want_json() {
  [[ "$JSON_MODE" == "1" ]] || { [[ ! -t 1 ]] && [[ "${STANDUP_FORCE_TEXT:-0}" != "1" ]]; }
}

emit_json() {
  /usr/bin/python3 -c '
import json, os
ok = os.environ["SR_OK"] == "1"
payload = {
    "ok": ok,
    "data": json.loads(os.environ["SR_DATA"] or "null"),
    "error": None if ok else {"code": os.environ["SR_CODE"], "message": os.environ["SR_MSG"]},
    "meta": {"version": os.environ["SR_VERSION"]},
}
print(json.dumps(payload, ensure_ascii=False))
'
}

json_env() {
  export SR_OK="$1" SR_CODE="$2" SR_MSG="$3" SR_DATA="$4" SR_VERSION="$VERSION"
}

print_human_or_json() {
  local ok="$1" code="$2" message="$3" data="$4"
  if want_json; then
    json_env "$ok" "$code" "$message" "$data"
    emit_json
  else
    printf '%s\n' "$message"
  fi
  [[ "$ok" == "1" ]]
}

require_macos() {
  if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    print_human_or_json 0 "unsupported_os" "standup-reminder 仅支持 macOS" "null" >&2 || true
    return 1
  fi
  return 0
}

is_pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  /bin/kill -0 "$pid" 2>/dev/null
}

running_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid cmd
  pid="$(/bin/cat "$PID_FILE" 2>/dev/null || true)"
  is_pid_running "$pid" || return 1
  cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$cmd" && "$cmd" == *"standup-reminder"* ]] || return 1
  printf '%s' "$pid"
}

console_user() {
  /usr/bin/stat -f%Su /dev/console 2>/dev/null || true
}

wake_sec() {
  /usr/sbin/sysctl -n kern.waketime 2>/dev/null | /usr/bin/awk '{print $4}' | /usr/bin/tr -d ','
}

# 兼容旧版 "LSDisplayName"="App" 与现行 `"App" ASN:...` 两种输出。
parse_front_name() {
  local info="$1" name=""
  name="$(printf '%s\n' "$info" | /usr/bin/awk -F'"' '/LSDisplayName/ {print $4; exit}')"
  if [[ -z "$name" ]]; then
    name="$(printf '%s\n' "$info" | /usr/bin/awk -F'"' '{print $2; exit}')"
  fi
  printf '%s' "$name"
}

front_app_name() {
  local asn info
  asn="$(/usr/bin/lsappinfo front 2>/dev/null || true)"
  [[ -n "$asn" ]] || return 0
  info="$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null || true)"
  parse_front_name "$info"
}

# 判断失败时视为已解锁（fail-open）：提醒工具宁可多响，不能装上后永远不响。
is_unlocked() {
  local user front
  user="$(console_user)"
  [[ -n "$user" && "$user" != "loginwindow" && "$user" != "root" ]] || return 1

  if /usr/bin/pgrep -x "ScreenSaverEngine" >/dev/null; then
    return 1
  fi
  if /usr/bin/pgrep -x "LockScreen" >/dev/null; then
    return 1
  fi

  front="$(front_app_name || true)"
  if [[ -z "$front" ]]; then
    return 0
  fi
  [[ "$front" != "loginwindow" && "$front" != "ScreenSaverEngine" && "$front" != "LockScreen" && "$front" != "SecurityAgent" ]]
}

write_state() {
  mkdir -p "$STATE_DIR"
  local session="$1" unlocked_since="$2" elapsed="$3" last_reason="${4:-}"
  cat >"$STATE_FILE" <<EOF
session=$session
unlocked_since=$unlocked_since
elapsed=$elapsed
interval=$REMINDER_INTERVAL
wake_sec=$(wake_sec)
last_tick=$(/bin/date +%s)
last_reason=$last_reason
pid=$$
version=$VERSION
EOF
}

read_state_value() {
  local key="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  /usr/bin/awk -F= -v k="$key" '$1==k {print substr($0, length(k)+2); exit}' "$STATE_FILE"
}

state_age_seconds() {
  [[ -f "$STATE_FILE" ]] || { printf '%s' "999999"; return 0; }
  local last now
  last="$(read_state_value last_tick)"
  now="$(/bin/date +%s)"
  [[ -n "$last" ]] || { printf '%s' "999999"; return 0; }
  printf '%s' "$((now - last))"
}

launchd_loaded() {
  /bin/launchctl print "gui/$(/usr/bin/id -u)/$LAUNCH_LABEL" >/dev/null 2>&1
}

brew_service_listed() {
  command -v brew >/dev/null 2>&1 || return 1
  brew services list 2>/dev/null | /usr/bin/awk '$1=="standup-reminder" {found=1} END {exit found?0:1}'
}

hide_all_windows() {
  if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，仅记录日志，不隐藏窗口"
    return 0
  fi

  local user uid
  user="$(console_user)"
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1

  /bin/launchctl asuser "$uid" /usr/bin/osascript -e 'tell application "System Events" to set visible of every process whose visible is true to false' 2>&1 | while read -r line; do
    [[ -n "$line" ]] && log "隐藏窗口：$line"
  done
}

show_reminder() {
  if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，仅记录日志，不显示提醒"
    return 0
  fi

  local user uid
  user="$(console_user)"
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1

  /bin/launchctl asuser "$uid" /usr/bin/osascript -e "display dialog \"$REMINDER_MESSAGE\" buttons {\"好的\"} default button \"好的\" with title \"久坐提醒\" giving up after 30" 2>&1 | while read -r line; do
    [[ -n "$line" ]] && log "显示提醒：$line"
  done
}

start_screensaver() {
  if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，仅记录日志，不启动屏保"
    return 0
  fi

  local user uid
  user="$(console_user)"
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1

  log "1秒后启动屏保"
  /bin/sleep 1
  /bin/launchctl asuser "$uid" /usr/bin/open -a ScreenSaverEngine 2>&1 | while read -r line; do
    [[ -n "$line" ]] && log "启动屏保：$line"
  done
  log "屏保已启动"
}

fire_reminder() {
  local elapsed="${1:-0}"
  log "触发提醒（已连续使用 ${elapsed} 秒）"
  hide_all_windows
  start_screensaver &
  show_reminder
  log "提醒流程结束"
}

acquire_single_instance() {
  if [[ -f "$PID_FILE" ]]; then
    local old_pid
    old_pid="$(/bin/cat "$PID_FILE" 2>/dev/null || true)"
    if is_pid_running "$old_pid"; then
      local cmd
      cmd="$(/bin/ps -p "$old_pid" -o command= 2>/dev/null || true)"
      if [[ -n "$cmd" && "$cmd" == *"standup-reminder"* ]]; then
        log "检测到已有实例在运行 (pid=$old_pid)，本次退出"
        printf 'standup-reminder 已在运行 (pid=%s)\n' "$old_pid" >&2
        exit 5
      fi
    fi
  fi

  mkdir -p "$STATE_DIR"
  printf '%s' "$$" >"$PID_FILE"

  cleanup() {
    rm -f "$PID_FILE"
    log "退出"
  }

  trap cleanup EXIT
  trap 'cleanup; exit 0' INT TERM
}

status_data_json() {
  local running="$1" pid="$2" session="$3" elapsed="$4" interval="$5" age="$6" reason="$7"
  local next=0 counting="false" status="stopped" tag="未在运行"
  if [[ "$running" == "1" ]]; then
    if [[ "$age" -gt "$STATE_STALE_AFTER" ]]; then
      status="stale"
      tag="在运行但状态过期"
    elif [[ "$session" == "unlocked" ]]; then
      counting="true"
      status="counting"
      tag="正在计时"
      next=$((interval - elapsed))
      [[ "$next" -lt 0 ]] && next=0
    else
      status="paused"
      tag="判定为锁屏，不计时"
    fi
  fi
  /usr/bin/python3 -c '
import json, os
print(json.dumps({
    "running": os.environ["A"] == "1",
    "pid": int(os.environ["B"]) if os.environ["B"].isdigit() else None,
    "session": os.environ["C"] or None,
    "elapsed_seconds": int(os.environ["D"] or 0),
    "interval_seconds": int(os.environ["E"] or 0),
    "next_in_seconds": int(os.environ["F"] or 0),
    "state_age_seconds": int(os.environ["G"] or 0),
    "counting": os.environ["H"] == "true",
    "status": os.environ["I"],
    "status_tag": os.environ["J"],
    "last_reason": os.environ["K"] or None,
}, ensure_ascii=False))
' 
}

cmd_status() {
  local pid="" running=0 session="" elapsed=0 interval="$REMINDER_INTERVAL" age=999999 reason=""
  if pid="$(running_pid)"; then
    running=1
  else
    pid=""
  fi
  if [[ -f "$STATE_FILE" ]]; then
    session="$(read_state_value session)"
    elapsed="$(read_state_value elapsed)"
    interval="$(read_state_value interval)"
    reason="$(read_state_value last_reason)"
    age="$(state_age_seconds)"
    elapsed="${elapsed:-0}"
    interval="${interval:-$REMINDER_INTERVAL}"
  fi

  export A="$running" B="${pid:-}" C="${session:-}" D="${elapsed:-0}" E="${interval:-0}" F="0" G="$age" H="false" I="stopped" J="未在运行" K="${reason:-}"
  local data next=0 msg
  if [[ "$running" == "1" ]]; then
    if [[ "$age" -gt "$STATE_STALE_AFTER" ]]; then
      export I="stale" J="在运行但状态过期"
      msg="standup-reminder 正在运行 (pid=${pid})，但超过 ${age} 秒没有刷新状态。先跑 standup-reminder doctor"
    elif [[ "$session" == "unlocked" ]]; then
      next=$((interval - elapsed))
      [[ "$next" -lt 0 ]] && next=0
      export F="$next" H="true" I="counting" J="正在计时"
      msg=$(printf 'standup-reminder 正在运行 (pid=%s)：已连续使用 %s 分钟，约 %s 分钟后提醒' "$pid" "$((elapsed / 60))" "$((next / 60))")
    else
      export I="paused" J="判定为锁屏，不计时"
      msg="standup-reminder 正在运行 (pid=${pid})：当前判定为锁屏/屏保，不计时"
    fi
  else
    msg="standup-reminder 未在运行"
  fi
  data="$(status_data_json "$running" "${pid:-0}" "${session:-}" "${elapsed:-0}" "${interval:-0}" "$age" "${reason:-}")"
  if want_json; then
    json_env "$([[ "$running" == "1" ]] && echo 1 || echo 0)" "not_running" "$msg" "$data"
    emit_json
  else
    printf '%s\n' "$msg"
  fi
  [[ "$running" == "1" ]]
}

cmd_doctor() {
  local issues_file hints_file running=0 pid="" session="" elapsed=0 age=999999 counting=0
  issues_file="$(/usr/bin/mktemp -t standup-issues)"
  hints_file="$(/usr/bin/mktemp -t standup-hints)"
  rm_doctor_tmp() { rm -f "$issues_file" "$hints_file"; }

  if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
    printf '%s\n' "当前系统不是 macOS" >>"$issues_file"
  fi
  if pid="$(running_pid)"; then
    running=1
  fi
  if [[ "$running" != "1" ]]; then
    printf '%s\n' "守护进程未在运行" >>"$issues_file"
    if [[ -f "$LAUNCH_PLIST" ]]; then
      printf '%s\n' "重新加载登录项：launchctl bootstrap gui/\$(id -u) \"$LAUNCH_PLIST\"" >>"$hints_file"
    else
      printf '%s\n' "尚未安装登录项。Homebrew: brew services start x0c/tap/standup-reminder ；或运行 ./install.sh" >>"$hints_file"
    fi
  fi
  if [[ "$running" == "1" ]] && [[ -f "$STATE_FILE" ]]; then
    session="$(read_state_value session)"
    elapsed="$(read_state_value elapsed)"
    age="$(state_age_seconds)"
    elapsed="${elapsed:-0}"
    if [[ "$age" -gt "$STATE_STALE_AFTER" ]]; then
      printf '%s\n' "进程在跑，但状态已 ${age} 秒未刷新" >>"$issues_file"
    elif [[ "$session" != "unlocked" ]]; then
      printf '%s\n' "进程在跑，但当前判定为锁屏，所以不会开始计时" >>"$issues_file"
      printf '%s\n' "若你正坐在电脑前，这就是从不提醒的根因。请看日志：$LOG_FILE" >>"$hints_file"
    else
      counting=1
    fi
  elif [[ "$running" == "1" ]]; then
    printf '%s\n' "进程在跑，但还没有状态文件（可能刚启动，等十几秒再查）" >>"$issues_file"
  fi

  local brew_on=0 agent_on=0
  brew_service_listed && brew_on=1 || true
  launchd_loaded && agent_on=1 || true
  if [[ "$brew_on" == "1" && "$agent_on" == "1" ]]; then
    printf '%s\n' "Homebrew 服务和手动登录项同时存在，可能重复拉起。只保留一种安装方式" >>"$hints_file"
  fi

  local issue_count=0
  if [[ -s "$issues_file" ]]; then
    issue_count="$(/usr/bin/wc -l <"$issues_file" | /usr/bin/tr -d ' ')"
  fi

  local ok=1 status="healthy" tag="正常：正在计时"
  if [[ "$issue_count" -gt 0 ]]; then
    ok=0
    status="unhealthy"
    tag="异常：还不能可靠提醒"
  elif [[ "$counting" != "1" ]]; then
    ok=0
    status="not_counting"
    tag="在跑但还没开始计时"
  fi

  local msg
  if [[ "$ok" == "1" ]]; then
    msg=$(printf '自检通过：正在计时，已连续使用 %s 分钟。立刻试响：standup-reminder now' "$((elapsed / 60))")
  else
    msg="自检未通过："
    if [[ -s "$issues_file" ]]; then
      msg+=$'\n'
      msg+="$(/usr/bin/sed 's/^/- /' "$issues_file")"
    fi
    if [[ -s "$hints_file" ]]; then
      msg+=$'\n'"建议："$'\n'
      msg+="$(/usr/bin/sed 's/^/- /' "$hints_file")"
    fi
    msg+=$'\n'"立刻试响：standup-reminder now"
  fi

  if want_json; then
    local data
    export SR_RUN="$running" SR_COUNT="$counting" SR_ST="$status" SR_TAG="$tag" SR_LOG="$LOG_FILE"
    export SR_ISSUES_FILE="$issues_file" SR_HINTS_FILE="$hints_file"
    data="$(/usr/bin/python3 -c '
import json, os, pathlib
def lines(path):
    p = pathlib.Path(path)
    if not p.exists():
        return []
    return [ln for ln in p.read_text(encoding="utf-8").splitlines() if ln]
print(json.dumps({
    "running": os.environ["SR_RUN"] == "1",
    "counting": os.environ["SR_COUNT"] == "1",
    "status": os.environ["SR_ST"],
    "status_tag": os.environ["SR_TAG"],
    "issues": lines(os.environ["SR_ISSUES_FILE"]),
    "hints": lines(os.environ["SR_HINTS_FILE"]),
    "log_file": os.environ["SR_LOG"],
}, ensure_ascii=False))
')"
    json_env "$ok" "unhealthy" "$msg" "$data"
    emit_json
  else
    printf '%s\n' "$msg"
  fi
  local doctor_ok="$ok"
  rm_doctor_tmp
  [[ "$doctor_ok" == "1" ]]
}

unload_service() {
  if launchd_loaded; then
    /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$LAUNCH_LABEL" 2>/dev/null || true
  fi
  if [[ -f "$LAUNCH_PLIST" ]]; then
    /bin/launchctl unload "$LAUNCH_PLIST" 2>/dev/null || true
  fi
  if command -v brew >/dev/null 2>&1; then
    brew services stop standup-reminder >/dev/null 2>&1 || true
  fi
}

cmd_stop() {
  unload_service
  local pid
  if pid="$(running_pid)"; then
    /bin/kill "$pid" 2>/dev/null || true
    printf '已停止 standup-reminder (pid=%s)\n' "$pid"
  else
    printf 'standup-reminder 未在运行，登录项已尝试卸下\n'
  fi
}

cmd_now() {
  require_macos || return 1
  mkdir -p "$STATE_DIR"
  log "手动试响"
  fire_reminder 0
  if want_json; then
    json_env 1 "" "" '{"fired": true}'
    emit_json
  else
    if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
      printf '已按演练模式走完提醒流程（没有真正弹窗/屏保）\n'
    else
      printf '已触发一次提醒\n'
    fi
  fi
}

run_daemon() {
  require_macos || exit 1
  acquire_single_instance
  log "启动 (提醒间隔=${REMINDER_INTERVAL}秒, 提示=\"$REMINDER_MESSAGE\", dry_run=${STANDUP_DRY_RUN})"

  local unlocked_since=0 last_unlocked=false last_wake="" now elapsed front
  local ticks_unlocked=0 ticks_locked=0
  last_wake="$(wake_sec)"

  while true; do
    now="$(/bin/date +%s)"
    local wake
    wake="$(wake_sec)"
    if [[ -n "$wake" && -n "$last_wake" && "$wake" != "$last_wake" ]]; then
      log "检测到系统唤醒，计时已重置"
      unlocked_since=0
      last_unlocked=false
      ticks_unlocked=0
      ticks_locked=0
      write_state "locked" 0 0 "wake"
    fi
    last_wake="$wake"

    if is_unlocked; then
      if [[ "$last_unlocked" == "false" ]]; then
        unlocked_since="$now"
        log "检测到解锁，开始计时"
        ticks_unlocked=0
      fi
      last_unlocked=true
      ticks_locked=0
      elapsed=$((now - unlocked_since))
      write_state "unlocked" "$unlocked_since" "$elapsed" "tick"
      ticks_unlocked=$((ticks_unlocked + 1))
      if ((ticks_unlocked % HEARTBEAT_EVERY == 0)); then
        local remain=$((REMINDER_INTERVAL - elapsed))
        [[ "$remain" -lt 0 ]] && remain=0
        log "计时中：已连续使用 $((elapsed / 60)) 分钟，约 $((remain / 60)) 分钟后提醒"
      fi
      if ((elapsed >= REMINDER_INTERVAL)); then
        fire_reminder "$elapsed"
        unlocked_since="$(/bin/date +%s)"
        ticks_unlocked=0
        write_state "unlocked" "$unlocked_since" 0 "fired"
        log "计时已重置"
      fi
    else
      front="$(front_app_name || true)"
      if [[ "$last_unlocked" == "true" ]]; then
        log "检测到锁屏或屏保，计时已重置（前台应用=${front:-未知}）"
        unlocked_since=0
        ticks_locked=0
      fi
      last_unlocked=false
      ticks_unlocked=0
      ticks_locked=$((ticks_locked + 1))
      write_state "locked" 0 0 "locked"
      if ((ticks_locked == 1 || ticks_locked % LOCKED_HEARTBEAT_EVERY == 0)); then
        log "仍判定为锁屏/屏保，不计时（前台应用=${front:-未知}）。若你正在用电脑，请运行 standup-reminder doctor"
      fi
    fi

    /bin/sleep "$POLL_SECONDS" &
    wait $!
  done
}

# 供测试调用的隐藏入口，不出现在帮助里
cmd_parse_front() {
  parse_front_name "${1-}"
  printf '\n'
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --dry-run)
      STANDUP_DRY_RUN=1
      shift
      ;;
    --help|-h|help)
      usage
      exit 0
      ;;
    --version|-v|version)
      printf 'standup-reminder %s\n' "$VERSION"
      exit 0
      ;;
    --)
      shift
      ARGS+=("$@")
      break
      ;;
    -*)
      printf '未知参数: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

set -- "${ARGS[@]+"${ARGS[@]}"}"

case "${1:-start}" in
  start|"")
    run_daemon
    ;;
  status)
    cmd_status
    ;;
  doctor)
    cmd_doctor
    ;;
  now|test|--test)
    cmd_now
    ;;
  stop)
    cmd_stop
    ;;
  __parse-front)
    cmd_parse_front "${2-}"
    ;;
  __is-unlocked)
    if is_unlocked; then
      printf 'unlocked\n'
      exit 0
    fi
    printf 'locked\n'
    exit 1
    ;;
  *)
    printf '未知命令: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
