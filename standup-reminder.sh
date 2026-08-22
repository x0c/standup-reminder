#!/bin/bash
set -euo pipefail

# standup-reminder —— macOS 久坐提醒守护脚本
# - 解锁后开始计时；锁屏 / 屏保 / 休眠须持续满防抖窗口才重置
# - 超时后隐藏窗口、弹出提示、启动屏保
# - 判断失败时按「正在使用」处理，避免静默从不提醒

VERSION="0.3.0"

# 显式传入的环境变量覆盖配置文件（测试 / 一次性演练）。未传则走配置文件或默认值。
if [[ "${REMINDER_INTERVAL+x}" == "x" ]]; then SR_ENV_INTERVAL="$REMINDER_INTERVAL"; fi
if [[ "${AWAY_DEBOUNCE_SECONDS+x}" == "x" ]]; then SR_ENV_AWAY="$AWAY_DEBOUNCE_SECONDS"; fi
if [[ "${REMINDER_MESSAGE+x}" == "x" ]]; then SR_ENV_MESSAGE="$REMINDER_MESSAGE"; fi
if [[ "${REMINDER_TITLE+x}" == "x" ]]; then SR_ENV_TITLE="$REMINDER_TITLE"; fi
if [[ "${REMINDER_BUTTON+x}" == "x" ]]; then SR_ENV_BUTTON="$REMINDER_BUTTON"; fi

STATE_DIR=${STATE_DIR:-"$HOME/Library/Application Support/standup-reminder"}
LOG_FILE=${LOG_FILE:-"$STATE_DIR/run.log"}
CONFIG_FILE="${STANDUP_CONFIG_FILE:-$STATE_DIR/config}"
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

# 下列由 load_effective_config 填入。未加载前给安全默认，避免帮助/解析类命令踩空。
REMINDER_INTERVAL=3600
REMINDER_MESSAGE="起身走动一下~"
REMINDER_TITLE="久坐提醒"
REMINDER_BUTTON="好的"
AWAY_DEBOUNCE_SECONDS=180
HIDE_WINDOWS=1
SHOW_DIALOG=1
START_SCREENSAVER=1
DIALOG_TIMEOUT=30
EFFECTIVE_STAMP=""

usage() {
  cat <<EOF
standup-reminder $VERSION —— macOS 久坐提醒守护脚本

用法:
  standup-reminder [start]     启动守护循环（前台运行，通常由登录项托管）
  standup-reminder status      查看是否在运行、是否在计时、距下次提醒多久
  standup-reminder doctor      自检：装上了但从不响，先跑这条
  standup-reminder now         立刻试响一次（确认弹窗/屏保真能出来）
  standup-reminder stop        停止守护进程并卸掉登录项
  standup-reminder config      查看全部配置
  standup-reminder config get <项>
  standup-reminder config set <项> <值>
  standup-reminder config unset <项>
  standup-reminder config path
  standup-reminder --dry-run   以演练模式启动（只记日志，不弹窗/不启屏保）
  standup-reminder --json      与 status / doctor / config 联用，输出机器可读结果
  standup-reminder --help      显示本帮助
  standup-reminder --version   显示版本号

可配置项:
  interval             连续使用多久后提醒。裸数字按分钟。默认 60m。例: 80、80m、1h20m
  away_reset           离开多久才清零。裸数字按分钟。默认 3m。未满又回来则接着计
  message              弹窗正文
  title                弹窗标题
  button               弹窗按钮
  hide_windows         到点是否藏窗口（true/false）
  show_dialog          到点是否弹窗
  start_screensaver    到点是否开屏保
  dialog_timeout       弹窗无人点时等多久自动关掉。裸数字按秒。默认 30s

改配置会写入配置文件，后台最多一轮（约 10 秒）后按新值计。不必改登录项。
config set 可加 --dry-run 只预览不写盘。

日志:
  tail -f "$LOG_FILE"
EOF
}

config_py() {
  CONFIG_FILE="$CONFIG_FILE" \
  SR_ENV_INTERVAL="${SR_ENV_INTERVAL-}" \
  SR_ENV_AWAY="${SR_ENV_AWAY-}" \
  SR_ENV_MESSAGE="${SR_ENV_MESSAGE-}" \
  SR_ENV_TITLE="${SR_ENV_TITLE-}" \
  SR_ENV_BUTTON="${SR_ENV_BUTTON-}" \
  /usr/bin/python3 - "$@" <<'PY'
import json, os, re, shlex, subprocess, sys

FILE = os.environ.get("CONFIG_FILE", "")
ENV = {
    "interval": os.environ.get("SR_ENV_INTERVAL"),
    "away_reset": os.environ.get("SR_ENV_AWAY"),
    "message": os.environ.get("SR_ENV_MESSAGE"),
    "title": os.environ.get("SR_ENV_TITLE"),
    "button": os.environ.get("SR_ENV_BUTTON"),
}

def is_zh():
    for key in ("LC_ALL", "LC_MESSAGES", "LANG"):
        if os.environ.get(key, "").lower().startswith("zh"):
            return True
    try:
        out = subprocess.check_output(
            ["/usr/bin/defaults", "read", "-g", "AppleLocale"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        return out.lower().startswith("zh")
    except Exception:
        return False

ZH = is_zh()

def loc_default(zh, en):
    return zh if ZH else en

KEYS = {
    "interval": {
        "type": "duration", "default": "60m", "bare": "m", "min": 60, "max": 86400,
        "env_as": "seconds",
        "desc": "连续使用多久后提醒",
    },
    "away_reset": {
        "type": "duration", "default": "3m", "bare": "m", "min": 0, "max": 3600,
        "env_as": "seconds",
        "desc": "离开多久才清零；未满又回来则接着计",
    },
    "message": {"type": "string", "desc": "弹窗正文"},
    "title": {"type": "string", "desc": "弹窗标题"},
    "button": {"type": "string", "desc": "弹窗按钮"},
    "hide_windows": {"type": "bool", "default": True, "desc": "到点是否藏窗口"},
    "show_dialog": {"type": "bool", "default": True, "desc": "到点是否弹窗"},
    "start_screensaver": {"type": "bool", "default": True, "desc": "到点是否开屏保"},
    "dialog_timeout": {
        "type": "duration", "default": "30s", "bare": "s", "min": 5, "max": 300,
        "desc": "弹窗无人点时等多久自动关掉",
    },
}

UNIT = {"s": 1, "sec": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600}

def string_default(key):
    if key == "message":
        return loc_default("起身走动一下~", "Time to stand up and walk around")
    if key == "title":
        return loc_default("久坐提醒", "Stand up")
    if key == "button":
        return loc_default("好的", "OK")
    return KEYS[key].get("default")

def parse_duration(text, bare):
    raw = str(text).strip().lower().replace(" ", "")
    if not raw:
        raise ValueError("时长不能为空")
    if re.fullmatch(r"\d+", raw):
        return int(raw) * UNIT[bare]
    total = 0
    pos = 0
    for m in re.finditer(r"(\d+)(hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)", raw):
        if m.start() != pos:
            raise ValueError("无法解析时长: %s" % text)
        n = int(m.group(1))
        u = m.group(2)
        if u in ("h", "hr", "hrs", "hour", "hours"):
            total += n * 3600
        elif u in ("m", "min", "mins", "minute", "minutes"):
            total += n * 60
        else:
            total += n
        pos = m.end()
    if pos != len(raw) or pos == 0:
        raise ValueError("无法解析时长: %s" % text)
    return total

def format_duration(seconds):
    seconds = int(seconds)
    if seconds % 3600 == 0 and seconds >= 7200:
        return "%dh" % (seconds // 3600)
    if seconds % 60 == 0:
        return "%dm" % (seconds // 60)
    return "%ds" % seconds

def human_duration(seconds):
    seconds = int(seconds)
    if seconds % 3600 == 0 and seconds >= 7200:
        return "%d 小时" % (seconds // 3600)
    if seconds >= 60 and seconds % 60 == 0:
        return "%d 分钟" % (seconds // 60)
    if seconds >= 60:
        return "%d 分 %d 秒" % (seconds // 60, seconds % 60)
    return "%d 秒" % seconds

def parse_bool(text):
    v = str(text).strip().lower()
    if v in ("1", "true", "yes", "on", "y"):
        return True
    if v in ("0", "false", "no", "off", "n"):
        return False
    raise ValueError("布尔值请用 true/false")

def canonical(key, value):
    spec = KEYS[key]
    t = spec["type"]
    if t == "duration":
        sec = parse_duration(value, spec["bare"])
        if sec < spec["min"] or sec > spec["max"]:
            raise ValueError("%s 允许范围是 %s–%s" % (
                key, format_duration(spec["min"]), format_duration(spec["max"])))
        return format_duration(sec), sec
    if t == "bool":
        b = parse_bool(value)
        return ("true" if b else "false"), b
    s = str(value)
    if not s.strip():
        raise ValueError("%s 不能为空" % key)
    if "\n" in s or "\r" in s:
        raise ValueError("%s 不能换行" % key)
    return s, s

def default_canon(key):
    spec = KEYS[key]
    if spec["type"] == "string":
        v = string_default(key)
        return v, v
    return canonical(key, spec["default"])

def read_file():
    out = {}
    if not FILE or not os.path.isfile(FILE):
        return out
    with open(FILE, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            raw = line.strip()
            if not raw or raw.startswith("#"):
                continue
            if "=" not in raw:
                raise ValueError("配置第 %d 行缺少 =: %s" % (lineno, raw))
            k, v = raw.split("=", 1)
            k = k.strip()
            if k not in KEYS:
                raise ValueError("配置第 %d 行未知项: %s" % (lineno, k))
            out[k] = v
    return out

def write_file(data):
    os.makedirs(os.path.dirname(FILE) or ".", exist_ok=True)
    tmp = FILE + ".tmp"
    lines = ["# standup-reminder 配置。请用 standup-reminder config set 修改。"]
    for k in KEYS:
        if k in data:
            lines.append("%s=%s" % (k, data[k]))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, FILE)

def env_raw(key):
    v = ENV.get(key)
    if v is None or v == "":
        return None
    return v

def resolve(key, filemap):
    spec = KEYS[key]
    ev = env_raw(key)
    if ev is not None:
        if spec.get("env_as") == "seconds" and re.fullmatch(r"\d+", ev):
            canon, inner = format_duration(int(ev)), int(ev)
        else:
            canon, inner = canonical(key, ev)
        return canon, inner, "env"
    if key in filemap:
        canon, inner = canonical(key, filemap[key])
        return canon, inner, "file"
    canon, inner = default_canon(key)
    return canon, inner, "default"

SOURCE_TAG = {"env": "环境变量", "file": "配置文件", "default": "默认值"}

def item(key, filemap):
    spec = KEYS[key]
    canon, inner, source = resolve(key, filemap)
    rec = {
        "key": key,
        "value": canon,
        "source": source,
        "source_tag": SOURCE_TAG[source],
        "description": spec["desc"],
        "type": spec["type"],
    }
    if spec["type"] == "duration":
        rec["value_seconds"] = int(inner)
        rec["value_tag"] = human_duration(inner)
        rec["default"] = spec["default"]
    elif spec["type"] == "bool":
        rec["value_bool"] = bool(inner)
        rec["value_tag"] = "是" if inner else "否"
        rec["default"] = "true" if spec["default"] else "false"
    else:
        rec["value_tag"] = canon
        rec["default"] = string_default(key)
    return rec, inner

def fail(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)

def cmd_export():
    filemap = read_file()
    vals = {}
    stamp_parts = []
    for key in KEYS:
        rec, inner = item(key, filemap)
        vals[key] = inner
        stamp_parts.append("%s=%s" % (key, rec["value"]))
    assigns = {
        "REMINDER_INTERVAL": str(vals["interval"]),
        "AWAY_DEBOUNCE_SECONDS": str(vals["away_reset"]),
        "REMINDER_MESSAGE": str(vals["message"]),
        "REMINDER_TITLE": str(vals["title"]),
        "REMINDER_BUTTON": str(vals["button"]),
        "HIDE_WINDOWS": "1" if vals["hide_windows"] else "0",
        "SHOW_DIALOG": "1" if vals["show_dialog"] else "0",
        "START_SCREENSAVER": "1" if vals["start_screensaver"] else "0",
        "DIALOG_TIMEOUT": str(vals["dialog_timeout"]),
        "EFFECTIVE_STAMP": "|".join(stamp_parts),
    }
    for k, v in assigns.items():
        print("%s=%s" % (k, shlex.quote(v)))

def cmd_list():
    filemap = read_file()
    items = [item(k, filemap)[0] for k in KEYS]
    json.dump({"path": FILE, "items": items}, sys.stdout, ensure_ascii=False)
    print()

def cmd_get(key):
    if key not in KEYS:
        fail(2, "未知配置项: %s" % key)
    rec, _ = item(key, read_file())
    json.dump(rec, sys.stdout, ensure_ascii=False)
    print()

def parse_pairs(args):
    pairs = []
    if len(args) == 2 and "=" not in args[0]:
        pairs.append((args[0], args[1]))
        return pairs
    i = 0
    while i < len(args):
        a = args[i]
        if "=" in a:
            k, v = a.split("=", 1)
            pairs.append((k, v))
            i += 1
        elif i + 1 < len(args) and "=" not in args[i + 1]:
            pairs.append((a, args[i + 1]))
            i += 2
        else:
            fail(2, "用法: config set <项> <值>")
    return pairs

def cmd_set(args, dry):
    if not args:
        fail(2, "用法: config set <项> <值>")
    pairs = parse_pairs(args)
    filemap = read_file()
    previous = dict(filemap)
    changed = []
    for k, v in pairs:
        if k not in KEYS:
            fail(2, "未知配置项: %s" % k)
        try:
            canon, _ = canonical(k, v)
        except ValueError as e:
            fail(2, str(e))
        old = filemap.get(k)
        filemap[k] = canon
        rec, _ = item(k, filemap)
        rec["previous"] = old
        rec["changed"] = old != canon
        changed.append(rec)
    any_change = any(r["changed"] or r["key"] not in previous for r in changed)
    # 第一次写入默认值也算 applied
    first = not os.path.isfile(FILE)
    if not dry and (any_change or first):
        write_file(filemap)
    action = "unchanged"
    if dry:
        action = "would_update" if (any_change or first) else "unchanged"
    elif any_change or first:
        action = "updated"
    json.dump({
        "path": FILE,
        "dry_run": dry,
        "action": action,
        "changed": action in ("updated", "would_update"),
        "items": changed,
    }, sys.stdout, ensure_ascii=False)
    print()

def cmd_unset(key, dry):
    if key not in KEYS:
        fail(2, "未知配置项: %s" % key)
    filemap = read_file()
    existed = key in filemap
    if existed:
        del filemap[key]
    rec, _ = item(key, filemap)
    rec["changed"] = existed
    action = "unchanged"
    if dry:
        action = "would_update" if existed else "unchanged"
    elif existed:
        write_file(filemap)
        action = "updated"
    json.dump({
        "path": FILE,
        "dry_run": dry,
        "action": action,
        "changed": action in ("updated", "would_update"),
        "items": [rec],
    }, sys.stdout, ensure_ascii=False)
    print()

argv = sys.argv[1:]
if not argv:
    fail(2, "config 内部参数缺失")
op = argv[0]
try:
    if op == "export":
        cmd_export()
    elif op == "list":
        cmd_list()
    elif op == "get":
        if len(argv) < 2:
            fail(2, "用法: config get <项>")
        cmd_get(argv[1])
    elif op == "set":
        dry = os.environ.get("SR_CONFIG_DRY", "0") == "1"
        cmd_set(argv[1:], dry)
    elif op == "unset":
        dry = os.environ.get("SR_CONFIG_DRY", "0") == "1"
        if len(argv) < 2:
            fail(2, "用法: config unset <项>")
        cmd_unset(argv[1], dry)
    elif op == "keys":
        print("\n".join(KEYS))
    else:
        fail(2, "未知配置内部命令: %s" % op)
except ValueError as e:
    fail(2, str(e))
PY
}

load_effective_config() {
  local exported
  exported="$(config_py export)"
  eval "$exported"
}

config_py_ok() {
  local err rc
  err="$(/usr/bin/mktemp -t standup-cfg-err)"
  set +e
  _CFG_OUT="$(config_py "$@" 2>"$err")"
  rc=$?
  set -e
  if [[ "$rc" != "0" ]]; then
    print_human_or_json 0 "invalid_config" "$(/usr/bin/tr '\n' ' ' <"$err")" "null" || true
    rm -f "$err"
    return "$rc"
  fi
  rm -f "$err"
  return 0
}

applescript_quote() {
  /usr/bin/python3 -c 'import sys; s=sys.argv[1]; print("\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")' "$1"
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

# 系统会话字典里，锁屏时才会出现 CGSSessionScreenIsLocked；解锁时该键不存在。
ioreg_reports_locked() {
  local blob="${1-}"
  if [[ -z "$blob" ]]; then
    blob="$(/usr/sbin/ioreg -n Root -d1 2>/dev/null || true)"
  fi
  printf '%s' "$blob" | /usr/bin/grep -q 'CGSSessionScreenIsLocked'
}

screensaver_running() {
  if /usr/bin/pgrep -x "ScreenSaverEngine" >/dev/null; then
    return 0
  fi
  if /usr/bin/pgrep -x "LockScreen" >/dev/null; then
    return 0
  fi
  if /usr/bin/pgrep -f 'legacyScreenSaver.appex' >/dev/null; then
    return 0
  fi
  local running
  running="$(/usr/bin/osascript -e 'tell application "System Events" to get running of screen saver preferences' 2>/dev/null || true)"
  [[ "$running" == "true" ]]
}

away_reason() {
  local user front
  user="$(console_user)"
  if [[ -z "$user" || "$user" == "loginwindow" || "$user" == "root" ]]; then
    printf 'loginwindow'
    return 0
  fi
  if ioreg_reports_locked; then
    printf 'locked'
    return 0
  fi
  if screensaver_running; then
    printf 'screensaver'
    return 0
  fi
  front="$(front_app_name || true)"
  case "$front" in
    loginwindow|ScreenSaverEngine|LockScreen|SecurityAgent)
      printf '%s' "$front"
      return 0
      ;;
  esac
  return 1
}

# 屏保/锁屏用系统状态判断。前台应用名解析失败仍视为在用，避免再出现「装了从不响」。
is_unlocked() {
  ! away_reason >/dev/null
}

# 离开从 started 起算，满防抖窗口才清零。started=0 表示尚未进入离开。
away_long_enough() {
  local started="${1:-0}" now="${2:-}"
  now="${now:-$(/bin/date +%s)}"
  [[ "$started" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  (( now - started >= AWAY_DEBOUNCE_SECONDS ))
}

debounce_minutes() {
  printf '%s' "$((AWAY_DEBOUNCE_SECONDS / 60))"
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
  if [[ "$HIDE_WINDOWS" != "1" ]]; then
    log "已配置不隐藏窗口"
    return 0
  fi
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
  if [[ "$SHOW_DIALOG" != "1" ]]; then
    log "已配置不弹窗"
    return 0
  fi
  if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，仅记录日志，不显示提醒"
    return 0
  fi

  local user uid msg title btn
  user="$(console_user)"
  uid="$(/usr/bin/id -u "$user" 2>/dev/null || true)"
  [[ -n "$uid" ]] || return 1

  msg="$(applescript_quote "$REMINDER_MESSAGE")"
  title="$(applescript_quote "$REMINDER_TITLE")"
  btn="$(applescript_quote "$REMINDER_BUTTON")"
  /bin/launchctl asuser "$uid" /usr/bin/osascript -e "display dialog $msg buttons {$btn} default button $btn with title $title giving up after $DIALOG_TIMEOUT" 2>&1 | while read -r line; do
    [[ -n "$line" ]] && log "显示提醒：$line"
  done
}

start_screensaver() {
  if [[ "$START_SCREENSAVER" != "1" ]]; then
    log "已配置不启动屏保"
    return 0
  fi
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

cmd_config() {
  local sub="${1:-list}"
  shift || true
  case "$sub" in
    list|"")
      cmd_config_list
      ;;
    get)
      cmd_config_get "${1-}"
      ;;
    set)
      cmd_config_set "$@"
      ;;
    unset)
      cmd_config_unset "${1-}"
      ;;
    path)
      cmd_config_path
      ;;
    *)
      local keys
      keys="$(config_py keys)"
      if printf '%s\n' "$keys" | /usr/bin/grep -qx -- "$sub"; then
        if [[ $# -eq 0 ]]; then
          cmd_config_get "$sub"
        else
          cmd_config_set "$sub" "$@"
        fi
      else
        print_human_or_json 0 "unknown_command" "未知命令: config $sub" "null" || true
        return 2
      fi
      ;;
  esac
}

cmd_config_path() {
  local data
  data="$(P="$CONFIG_FILE" /usr/bin/python3 -c 'import json,os; print(json.dumps({"path": os.environ["P"]}, ensure_ascii=False))')"
  print_human_or_json 1 "" "$CONFIG_FILE" "$data"
}

cmd_config_list() {
  local payload msg
  config_py_ok list || return $?
  payload="$_CFG_OUT"
  msg="$(printf '%s' "$payload" | /usr/bin/python3 -c '
import json,sys
d=json.load(sys.stdin)
print("配置文件: " + d.get("path",""))
for it in d["items"]:
    extra = ""
    if it["source"] != "default":
        extra = "（%s）" % it["source_tag"]
    print("- %s: %s%s" % (it["key"], it["value_tag"], extra))
    print("    %s" % it["description"])
')"
  print_human_or_json 1 "" "$msg" "$payload"
}

cmd_config_get() {
  local key="${1-}" rec msg
  if [[ -z "$key" ]]; then
    print_human_or_json 0 "usage" "用法: standup-reminder config get <项>" "null" || true
    return 2
  fi
  config_py_ok get "$key" || return $?
  rec="$_CFG_OUT"
  msg="$(printf '%s' "$rec" | /usr/bin/python3 -c '
import json,sys
it=json.load(sys.stdin)
print("%s=%s（%s，来源：%s）" % (it["key"], it["value"], it["value_tag"], it["source_tag"]))
')"
  print_human_or_json 1 "" "$msg" "$rec"
}

cmd_config_human_set() {
  /usr/bin/python3 -c '
import json,sys
d=json.load(sys.stdin)
action=d.get("action","")
if action=="unchanged":
    print("配置未变化")
elif action=="would_update":
    print("演练：将写入下列配置（未真正保存）")
else:
    print("已保存，后台最多约 10 秒后按新值计")
for it in d.get("items") or []:
    print("- %s=%s（%s）" % (it["key"], it["value"], it["value_tag"]))
'
}

cmd_config_set() {
  local payload msg
  if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
    export SR_CONFIG_DRY=1
  fi
  config_py_ok set "$@" || return $?
  payload="$_CFG_OUT"
  msg="$(printf '%s' "$payload" | cmd_config_human_set)"
  print_human_or_json 1 "" "$msg" "$payload"
}

cmd_config_unset() {
  local key="${1-}" payload msg
  if [[ -z "$key" ]]; then
    print_human_or_json 0 "usage" "用法: standup-reminder config unset <项>" "null" || true
    return 2
  fi
  if [[ "$STANDUP_DRY_RUN" == "1" ]]; then
    export SR_CONFIG_DRY=1
  fi
  config_py_ok unset "$key" || return $?
  payload="$_CFG_OUT"
  msg="$(printf '%s' "$payload" | cmd_config_human_set)"
  print_human_or_json 1 "" "$msg" "$payload"
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

apply_config_if_changed() {
  local prev="$EFFECTIVE_STAMP"
  load_effective_config
  if [[ -n "$prev" && "$EFFECTIVE_STAMP" != "$prev" ]]; then
    log "配置已更新：间隔=$((REMINDER_INTERVAL / 60))分钟，离开满$((AWAY_DEBOUNCE_SECONDS / 60))分钟才清零，提示=\"$REMINDER_MESSAGE\""
  fi
}

run_daemon() {
  require_macos || exit 1
  acquire_single_instance
  load_effective_config
  log "启动 (提醒间隔=${REMINDER_INTERVAL}秒, 离开防抖=${AWAY_DEBOUNCE_SECONDS}秒, 提示=\"$REMINDER_MESSAGE\", dry_run=${STANDUP_DRY_RUN})"

  local unlocked_since=0 last_unlocked=false last_wake="" now elapsed reason
  local ticks_unlocked=0 ticks_locked=0 away_since=0 last_loop_now
  last_wake="$(wake_sec)"
  last_loop_now="$(/bin/date +%s)"

  while true; do
    apply_config_if_changed
    now="$(/bin/date +%s)"
    local wake
    wake="$(wake_sec)"
    if [[ -n "$wake" && -n "$last_wake" && "$wake" != "$last_wake" ]]; then
      if away_long_enough "$last_loop_now" "$now"; then
        log "休眠已满$(debounce_minutes)分钟，计时已重置"
        unlocked_since=0
        last_unlocked=false
        away_since=0
        ticks_unlocked=0
        ticks_locked=0
        write_state "locked" 0 0 "wake"
      elif [[ "$unlocked_since" -gt 0 ]]; then
        log "短唤醒未满$(debounce_minutes)分钟，继续计时"
      fi
    fi
    last_wake="$wake"

    if is_unlocked; then
      if [[ "$away_since" -gt 0 ]]; then
        log "短离开未满$(debounce_minutes)分钟，继续计时"
        away_since=0
        ticks_unlocked=0
      elif [[ "$last_unlocked" == "false" ]]; then
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
      reason="$(away_reason || true)"
      if [[ "$unlocked_since" -le 0 ]]; then
        last_unlocked=false
        ticks_unlocked=0
        ticks_locked=$((ticks_locked + 1))
        write_state "locked" 0 0 "${reason:-locked}"
        if ((ticks_locked == 1 || ticks_locked % LOCKED_HEARTBEAT_EVERY == 0)); then
          log "仍判定为离开，不计时（原因=${reason:-unknown}）。若你正在用电脑，请运行 standup-reminder doctor"
        fi
      else
        if [[ "$away_since" -le 0 ]]; then
          away_since="$now"
          log "检测到离开（${reason:-unknown}），未满$(debounce_minutes)分钟回来则继续计时"
          ticks_locked=0
        fi
        if away_long_enough "$away_since" "$now"; then
          log "离开已满$(debounce_minutes)分钟，计时已重置"
          unlocked_since=0
          last_unlocked=false
          away_since=0
          ticks_unlocked=0
          ticks_locked=1
          write_state "locked" 0 0 "${reason:-locked}"
          log "仍判定为离开，不计时（原因=${reason:-unknown}）。若你正在用电脑，请运行 standup-reminder doctor"
        else
          last_unlocked=true
          elapsed=$((now - unlocked_since))
          write_state "unlocked" "$unlocked_since" "$elapsed" "away_pending"
          ticks_unlocked=$((ticks_unlocked + 1))
          if ((ticks_unlocked % HEARTBEAT_EVERY == 0)); then
            local remain=$((REMINDER_INTERVAL - elapsed))
            [[ "$remain" -lt 0 ]] && remain=0
            log "计时中（短暂离开）：已连续使用 $((elapsed / 60)) 分钟，约 $((remain / 60)) 分钟后提醒"
          fi
        fi
      fi
    fi

    last_loop_now="$now"
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
  start|status|doctor|now|test|--test|stop|config|__away-long-enough)
    load_effective_config
    ;;
esac

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
  config)
    shift
    cmd_config "$@"
    ;;
  __parse-front)
    cmd_parse_front "${2-}"
    ;;
  __ioreg-locked)
    if ioreg_reports_locked "${2-}"; then
      printf 'locked\n'
      exit 0
    fi
    printf 'unlocked\n'
    exit 1
    ;;
  __is-unlocked)
    if is_unlocked; then
      printf 'unlocked\n'
      exit 0
    fi
    printf 'locked\n'
    exit 1
    ;;
  __away-long-enough)
    if away_long_enough "${2-}" "${3-}"; then
      printf 'reset\n'
      exit 0
    fi
    printf 'hold\n'
    exit 1
    ;;
  *)
    printf '未知命令: %s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
