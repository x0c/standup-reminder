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
[[ "$help" == *doctor* && "$help" == *now* ]] || fail "help 缺少 doctor/now"
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

pass "全部通过"
