# standup-reminder

**Languages:** English | [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A tiny macOS daemon that nudges you to **get up and move** after you have been at your Mac too long. It hides visible windows, shows a reminder, and starts the screensaver so the break is harder to ignore than a notification.

Compared with menu-bar timers that you can swipe away, this one is meant to interrupt you. Compared with tools that only count from last wake, it also notices lock and screensaver. A leave shorter than **3 minutes** (dimmed display, accidental hot corner, quick lid close) does **not** reset the timer — you were still sitting. Stay away 3 minutes or more, and the next hour starts fresh.

## Supported platforms

**macOS only.** Linux and Windows are not supported — this tool depends on macOS login items, screensaver, and session state. On another OS the installer exits with a clear error.

## Install

### Homebrew (recommended)

```bash
brew install x0c/tap/standup-reminder
brew services start standup-reminder
standup-reminder doctor
standup-reminder now
```

`doctor` must say it is counting. `now` fires one reminder immediately so you know it actually works.

### One-line installer (no Homebrew)

```bash
curl -fsSL https://raw.githubusercontent.com/x0c/standup-reminder/main/install.sh | bash
```

The installer copies the script, registers a login item, waits until timing has started, and prints `doctor` / `now` if anything looks off.

## Usage

```bash
standup-reminder status     # running? counting? minutes until the next nudge
standup-reminder doctor     # why it might be silent — run this first
standup-reminder now        # fire one reminder right now
standup-reminder stop       # stop it and disable start-at-login
standup-reminder --dry-run  # run the loop but do not hide windows / dialog / screensaver
standup-reminder --help
```

`status` and `doctor` also accept `--json` for scripts.

## Configuration

Set these as environment variables. Homebrew: `brew services` / the formula service block. Installer: `EnvironmentVariables` in `~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist`.

| Variable            | Default                                              | Description |
|---------------------|------------------------------------------------------|-------------|
| `REMINDER_INTERVAL` | `2700` (45 min; installer/brew default `3600`)       | Continuous unlocked use before a reminder. |
| `REMINDER_MESSAGE`  | `起身走动一下~`                                       | Dialog text. |
| `AWAY_DEBOUNCE_SECONDS` | `180` (3 min)                                    | Leave this long before the timer resets. Come back sooner and it keeps counting. |
| `STATE_DIR`         | `~/Library/Application Support/standup-reminder`     | PID, state, logs. |
| `LOG_FILE`          | `$STATE_DIR/run.log`                                 | Log file. |
| `STANDUP_DRY_RUN`   | `0`                                                  | `1` = log only. |

Reload after editing the login-item file:

```bash
launchctl unload ~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist
launchctl load   ~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist
standup-reminder doctor
```

## How it works

Every 10 seconds the daemon:

1. Treats screensaver, lock screen, or a logged-out console as **away**.
2. Treats an ambiguous session as **in use** (fail-open). A reminder tool must not stay silent because a front-app name parse failed.
3. **Does not reset** until you have been away for `AWAY_DEBOUNCE_SECONDS` (default 3 minutes). Come back sooner and the same sitting stretch continues, including those minutes.
4. After a long sleep (the process was frozen longer than the debounce), starts a fresh interval so hours asleep are not dumped into the next nudge.
5. After `REMINDER_INTERVAL` of continuous sitting: hide windows, show the dialog, start the screensaver, then start a new interval.

## If it never reminds you

```bash
standup-reminder doctor
tail -f "$HOME/Library/Application Support/standup-reminder/run.log"
standup-reminder now
```

`doctor` is the difference between “the process is running” and “it is actually counting time in front of you”. If doctor says it is paused while you are at the keyboard, the log will show why.

## Uninstall

Homebrew:

```bash
brew services stop standup-reminder
brew uninstall standup-reminder
```

Installer:

```bash
./install.sh --uninstall
```

## Requirements

macOS. Uses built-in `launchctl`, `osascript`, `lsappinfo`, and `sysctl`. Nothing to compile.

## License

[MIT](LICENSE)
