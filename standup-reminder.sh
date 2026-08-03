#!/bin/bash
set -euo pipefail

# standup-reminder —— macOS 久坐提醒守护脚本
# - 监听解锁事件，解锁后开始计时
# - 超过指定时间后隐藏所有窗口并弹出提示、启动屏保
# - 锁屏时暂停计时，解锁后继续

VERSION="0.1.0"

# 配置（均可通过环境变量覆盖）
REMINDER_INTERVAL=${REMINDER_INTERVAL:-2700}  # 默认 45 分钟（秒）
REMINDER_MESSAGE=${REMINDER_MESSAGE:-"起身走动一下~"}
STATE_DIR=${STATE_DIR:-"$HOME/Library/Application Support/standup-reminder"}
LOG_FILE=${LOG_FILE:-"$STATE_DIR/run.log"}
PID_FILE="$STATE_DIR/standup_reminder.pid"

# 1 = 只记日志，不真正隐藏窗口/弹提醒/启屏保
STANDUP_DRY_RUN=${STANDUP_DRY_RUN:-0}

log() {
  # shellcheck disable=SC2059
  printf '%s %s\n' "$(/bin/date '+%F %T')" "$*" >>"$LOG_FILE"
}

is_pid_running() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  /bin/kill -0 "$pid" 2>/dev/null
}

# 读取正在运行的守护进程 PID（校验是本脚本实例），无则返回空
running_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid cmd
  pid="$(/bin/cat "$PID_FILE" 2>/dev/null || true)"
  is_pid_running "$pid" || return 1
  cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$cmd" && "$cmd" == *"standup-reminder"* ]] || return 1
  printf '%s' "$pid"
}

usage() {
  cat <<EOF
standup-reminder $VERSION —— macOS 久坐提醒守护脚本

用法:
  standup-reminder [start]     启动守护循环（前台运行，通常由 launchd/brew services 托管）
  standup-reminder status      查看守护进程是否在运行
  standup-reminder stop        停止正在运行的守护进程
  standup-reminder --dry-run   以演练模式启动（只记日志，不弹窗/不启屏保）
  standup-reminder --help      显示本帮助
  standup-reminder --version   显示版本号

环境变量:
  REMINDER_INTERVAL   两次提醒之间的连续使用时长（秒），默认 2700（45 分钟）
  REMINDER_MESSAGE    提醒弹窗文案，默认 "起身走动一下~"
  STATE_DIR           状态与日志目录，默认 ~/Library/Application Support/standup-reminder
  LOG_FILE            日志文件路径，默认 \$STATE_DIR/run.log
  STANDUP_DRY_RUN     置 1 时只记日志，不隐藏窗口/不弹提醒/不启屏保

日志:
  tail -f "$LOG_FILE"
EOF
}

cmd_status() {
  local pid
  if pid="$(running_pid)"; then
    printf 'standup-reminder 正在运行 (pid=%s)\n' "$pid"
    return 0
  fi
  printf 'standup-reminder 未在运行\n'
  return 1
}

cmd_stop() {
  local pid
  if ! pid="$(running_pid)"; then
    printf 'standup-reminder 未在运行，无需停止\n'
    return 0
  fi
  /bin/kill "$pid" 2>/dev/null || true
  printf '已发送停止信号给 standup-reminder (pid=%s)\n' "$pid"
}

# ---- CLI 参数分派（必须早于 mkdir / 抢锁，避免 --help/status 也去创建目录、抢单实例锁）----
case "${1:-start}" in
  -h|--help|help)
    usage
    exit 0
    ;;
  -v|--version|version)
    printf 'standup-reminder %s\n' "$VERSION"
    exit 0
    ;;
  status)
    cmd_status
    exit $?
    ;;
  stop)
    cmd_stop
    exit 0
    ;;
  --dry-run)
    STANDUP_DRY_RUN=1
    ;;
  start)
    ;;
  *)
    printf '未知命令: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac

# ---- 以下为守护循环，仅在 start / --dry-run 时执行 ----

mkdir -p "$STATE_DIR"

acquire_single_instance() {
  if [[ -f "$PID_FILE" ]]; then
    local old_pid
    old_pid="$(/bin/cat "$PID_FILE" 2>/dev/null || true)"
    if is_pid_running "$old_pid"; then
      local cmd
      cmd="$(/bin/ps -p "$old_pid" -o command= 2>/dev/null || true)"
      if [[ -n "$cmd" && "$cmd" == *"standup-reminder"* ]]; then
        log "检测到已有实例在运行 (pid=$old_pid)，本次退出"
        exit 0
      fi
    fi
  fi

  printf '%s' "$$" >"$PID_FILE"

  cleanup() {
    rm -f "$PID_FILE"
    log "退出"
  }

  trap cleanup EXIT
  trap 'cleanup; exit 0' INT TERM
}

console_user() {
  /usr/bin/stat -f%Su /dev/console 2>/dev/null || true
}

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

  local asn
  asn="$(/usr/bin/lsappinfo front 2>/dev/null || true)"
  [[ -n "$asn" ]] || return 1
  front="$(/usr/bin/lsappinfo info -only name "$asn" 2>/dev/null | /usr/bin/awk -F'"' '/"LSDisplayName"=/ {print $4}')"
  [[ -n "$front" ]] || return 1
  [[ "$front" != "loginwindow" && "$front" != "ScreenSaverEngine" && "$front" != "LockScreen" && "$front" != "SecurityAgent" ]]
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

  log "3秒后启动屏保"
  /bin/sleep 3
  /bin/launchctl asuser "$uid" /usr/bin/open -a ScreenSaverEngine 2>&1 | while read -r line; do
    [[ -n "$line" ]] && log "启动屏保：$line"
  done
  log "屏保已启动"
}

acquire_single_instance
log "启动 (提醒间隔=${REMINDER_INTERVAL}秒, 提示=\"$REMINDER_MESSAGE\")"

# 状态变量
unlocked_since=0
last_unlocked=false

while true; do
  if is_unlocked; then
    if [[ "$last_unlocked" == "false" ]]; then
      # 刚解锁，开始计时
      unlocked_since=$(/bin/date +%s)
      log "检测到解锁，开始计时"
    fi
    last_unlocked=true

    now=$(/bin/date +%s)
    elapsed=$((now - unlocked_since))

    if ((elapsed >= REMINDER_INTERVAL)); then
      log "已连续使用 $elapsed 秒，触发提醒"
      hide_all_windows
      start_screensaver &
      show_reminder
      # 重置计时
      unlocked_since=$(/bin/date +%s)
      log "计时已重置"
    fi
  else
    if [[ "$last_unlocked" == "true" ]]; then
      log "检测到锁屏，计时已重置"
      unlocked_since=0
    fi
    last_unlocked=false
  fi

  # 后台 sleep + wait，使 INT/TERM 信号能立即中断轮询（否则要等满 10 秒）
  /bin/sleep 10 &
  wait $!
done
