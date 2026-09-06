#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/standup-reminder.sh"
chmod +x "$BIN" "$ROOT/install.sh" "$ROOT/scripts/publish-release.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$*"; }

STATE_DIR="$(/usr/bin/mktemp -d -t standup-test)"
export STATE_DIR LOG_FILE="$STATE_DIR/run.log" STANDUP_FORCE_TEXT=1
cleanup() { rm -rf "$STATE_DIR"; }
trap cleanup EXIT

ver="$("$BIN" --version)"
[[ "$ver" == standup-reminder\ * ]] || fail "version: $ver"
pass "version ($ver)"

help="$("$BIN" --help)"
[[ "$help" == *doctor* && "$help" == *now* && "$help" == *config* ]] || fail "help 缺少 doctor/now/config"
pass "help"

set +e
"$BIN" not-a-command >/dev/null 2>&1
code=$?
set -e
[[ "$code" == "2" ]] || fail "未知命令退出码应为 2，实际 $code"
pass "未知命令退出码 2"

old_out="$("$BIN" __parse-front '"LSDisplayName"="Safari"')"
[[ "$old_out" == Safari ]] || fail "旧版前台名解析: [$old_out]"
pass "旧版 LSDisplayName 解析"

new_out="$("$BIN" __parse-front '"iTerm2" ASN:0x0-0x7f07f: (in front)')"
[[ "$new_out" == iTerm2 ]] || fail "现行前台名解析: [$new_out]"
pass "现行 lsappinfo 解析"

empty_out="$("$BIN" __parse-front 'bundleID=[ NULL ]')"
[[ -z "$empty_out" ]] || fail "空输入应解析为空: [$empty_out]"
pass "空前台名"

set +e
"$BIN" __ioreg-locked 'kCGSSessionOnConsoleKey=Yes' >/dev/null
ioreg_unlocked=$?
set -e
[[ "$ioreg_unlocked" == "1" ]] || fail "无锁屏键应视为未锁"
pass "ioreg 无锁屏键"

set +e
ioreg_locked_out="$("$BIN" __ioreg-locked 'CGSSessionScreenIsLocked=Yes')"
ioreg_locked=$?
set -e
[[ "$ioreg_locked" == "0" && "$ioreg_locked_out" == locked ]] || fail "有锁屏键应视为已锁: [$ioreg_locked_out] $ioreg_locked"
pass "ioreg 有锁屏键"

set +e
status_out="$("$BIN" status 2>&1)"
status_code=$?
set -e
[[ "$status_code" == "1" ]] || fail "隔离环境下 status 应为未运行，退出码 $status_code"
[[ "$status_out" == *未在运行* ]] || fail "status 文案: $status_out"
pass "status 未运行"

set +e
json="$("$BIN" status --json)"
json_code=$?
set -e
[[ "$json_code" == "1" ]] || fail "status --json 未运行退出码应为 1，实际 $json_code"
echo "$json" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False; assert "data" in d and "error" in d and "meta" in d; assert d["error"]["code"]=="not_running"'
pass "status --json envelope"

set +e
"$BIN" now --dry-run >/dev/null
now_code=$?
set -e
[[ "$now_code" == "0" ]] || fail "dry-run now 退出码 $now_code"
[[ -f "$LOG_FILE" ]] || fail "dry-run now 应写日志"
grep -q 'DRY_RUN=1' "$LOG_FILE" || fail "dry-run now 日志未标记 DRY_RUN"
pass "now --dry-run"

if [[ "$(uname -s)" == "Darwin" ]]; then
  set +e
  unlock_out="$("$BIN" __is-unlocked)"
  unlock_code=$?
  set -e
  [[ "$unlock_code" == "0" && "$unlock_out" == unlocked ]] || fail "本机应判定为已解锁: [$unlock_out] code=$unlock_code"
  pass "本机解锁判定"
fi

export AWAY_DEBOUNCE_SECONDS=180
set +e
hold_out="$("$BIN" __away-long-enough 100 279)"
hold_code=$?
set -e
[[ "$hold_code" == "1" && "$hold_out" == hold ]] || fail "179秒离开不应清零: [$hold_out] $hold_code"
pass "离开 179 秒仍接着计"

set +e
reset_out="$("$BIN" __away-long-enough 100 280)"
reset_code=$?
set -e
[[ "$reset_code" == "0" && "$reset_out" == reset ]] || fail "180秒离开应清零: [$reset_out] $reset_code"
pass "离开 180 秒才清零"

set +e
zero_out="$("$BIN" __away-long-enough 0 999)"
zero_code=$?
set -e
[[ "$zero_code" == "1" && "$zero_out" == hold ]] || fail "未进入离开不应清零: [$zero_out] $zero_code"
pass "尚未离开不清零"

# --- 配置 ---
cfg_json="$("$BIN" config get interval --json)"
echo "$cfg_json" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["data"]["key"]=="interval"; assert d["data"]["value_seconds"]==3600; assert d["data"]["source"]=="default"'
pass "默认间隔 60 分钟"

[[ ! -f "$STATE_DIR/config" ]] || fail "未 set 前不应有配置文件"
set +e
dry_json="$("$BIN" config set interval 80m --dry-run --json)"
dry_code=$?
set -e
[[ "$dry_code" == "0" ]] || fail "config set --dry-run 退出码 $dry_code"
echo "$dry_json" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["data"]["action"]=="would_update"'
[[ ! -f "$STATE_DIR/config" ]] || fail "dry-run 不应写配置文件"
pass "config set --dry-run 不写盘"

set1="$("$BIN" config set interval 80m --json)"
echo "$set1" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is True; assert d["data"]["action"]=="updated"; assert d["data"]["items"][0]["value_seconds"]==4800'
[[ -f "$STATE_DIR/config" ]] || fail "set 后应有配置文件"
pass "config set interval 80m"

set2="$("$BIN" config set interval 80 --json)"
echo "$set2" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["action"]=="unchanged"'
pass "同样的间隔第二次 set 为 unchanged"

set3="$("$BIN" config set interval 1h20m --json)"
echo "$set3" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["items"][0]["value_seconds"]==4800; assert d["data"]["action"]=="unchanged"'
pass "1h20m 与 80 分钟相同"

got="$("$BIN" config get interval --json)"
echo "$got" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["value"]=="80m"; assert d["data"]["source"]=="file"'
pass "config get 读到文件中的 80 分钟"

bool_set="$("$BIN" config set hide_windows false --json)"
echo "$bool_set" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["items"][0]["value_bool"] is False'
pass "config set hide_windows false"

env_json="$(REMINDER_INTERVAL=120 "$BIN" config get interval --json)"
echo "$env_json" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["value_seconds"]==120; assert d["data"]["source"]=="env"'
pass "环境变量覆盖配置文件"

set +e
bad="$("$BIN" config get not_a_key --json)"
bad_code=$?
set -e
[[ "$bad_code" == "2" ]] || fail "未知配置项退出码应为 2，实际 $bad_code"
echo "$bad" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["ok"] is False; assert d["error"]["code"]'
pass "未知配置项 --json envelope"

set +e
bad2="$("$BIN" config set interval 0 --json)"
bad2_code=$?
set -e
[[ "$bad2_code" == "2" ]] || fail "过短间隔退出码应为 2，实际 $bad2_code"
pass "间隔过短被拒绝"

un="$("$BIN" config unset interval --json)"
echo "$un" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["data"]["action"]=="updated"; assert d["data"]["items"][0]["source"]=="default"; assert d["data"]["items"][0]["value_seconds"]==3600'
pass "config unset 回到默认 60 分钟"

list="$("$BIN" config --json)"
echo "$list" | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); keys={i["key"] for i in d["data"]["items"]}; assert keys=={"interval","away_reset","message","title","button","hide_windows","show_dialog","start_screensaver","dialog_timeout"}'
pass "config list 含全部项"

# --- 单实例锁（flock / fcntl，覆盖纯 PID 文件 TOCTOU）---
"$BIN" __hold-instance 8 &
holder_pid=$!
# 等持有者写好 PID / 抢到锁
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$STATE_DIR/standup_reminder.pid" ]] && break
  sleep 0.1
done
[[ -f "$STATE_DIR/standup_reminder.pid" ]] || fail "持有实例应写出 PID 文件"
set +e
second_out="$("$BIN" __hold-instance 1 2>&1)"
second_code=$?
set -e
[[ "$second_code" == "5" ]] || fail "第二实例应立刻退出码 5，实际 $second_code；输出: $second_out"
[[ "$second_out" == *已在运行* ]] || fail "第二实例文案应含已在运行: $second_out"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
pass "第二实例立刻退出（单实例锁）"

# 并行抢锁：至多一个成功持有至 sleep 结束
race_dir="$STATE_DIR/race"
mkdir -p "$race_dir"
set +e
for i in $(seq 1 12); do
  (
    "$BIN" __hold-instance 2 >/dev/null 2>&1
    echo $? >"$race_dir/exit.$i"
  ) &
done
wait
set -e
ok_n=0
fail_n=0
for f in "$race_dir"/exit.*; do
  c="$(/bin/cat "$f")"
  if [[ "$c" == "0" ]]; then
    ok_n=$((ok_n + 1))
  elif [[ "$c" == "5" ]]; then
    fail_n=$((fail_n + 1))
  else
    fail "并行抢锁出现意外退出码 $c ($f)"
  fi
done
[[ "$ok_n" == "1" ]] || fail "并行抢锁应恰好 1 个成功，实际成功 $ok_n / 失败 $fail_n"
[[ "$fail_n" == "11" ]] || fail "并行抢锁应有 11 个退出码 5，实际失败 $fail_n"
pass "并行抢锁恰好一个成功"

pass "全部通过"
