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
standup-reminder config     # show interval, copy, and what happens at fire time
standup-reminder config set interval 80m   # remind every 80 minutes
standup-reminder stop       # stop it and disable start-at-login
standup-reminder --dry-run  # run the loop but do not hide windows / dialog / screensaver
standup-reminder --help
```

`status` and `doctor` also accept `--json` for scripts.

## Configuration

Change settings with commands. They take effect within about 10 seconds. You do not need to edit the login item or reinstall.

```bash
standup-reminder config
standup-reminder config set interval 80m
standup-reminder config set away_reset 3m
standup-reminder config set message "Time to stand up and walk around"
standup-reminder config set hide_windows false
standup-reminder config unset interval    # revert that key to the default
```

`status` / `doctor` / `config` accept `--json`. `config set --dry-run` previews without writing.

| Key | Default | Meaning |
|-----|---------|---------|
| `interval` | 60 minutes | Continuous unlocked use before a reminder. A bare number is minutes. Also accepts `80m` / `1h20m`. |
| `away_reset` | 3 minutes | How long you must be away before the timer resets. Come back sooner and it keeps counting. |
| `message` / `title` / `button` | follows system language | Dialog text, title, and button |
| `hide_windows` | true | Hide windows when the reminder fires |
| `show_dialog` | true | Show the dialog |
| `start_screensaver` | true | Start the screensaver |
| `dialog_timeout` | 30 seconds | Auto-dismiss the dialog if nobody clicks. A bare number is seconds. |

`standup-reminder config path` prints the config file path. Reinstalling keeps an existing config.

## How it works

Every 10 seconds the daemon:

1. Treats screensaver, lock screen, or a logged-out console as **away**.
2. Treats an ambiguous session as **in use** (fail-open). A reminder tool must not stay silent because a front-app name parse failed.
3. **Does not reset** until you have been away for the configured leave window (default 3 minutes). Come back sooner and the same sitting stretch continues, including those minutes.
4. After a long sleep (the process was frozen longer than the debounce), starts a fresh interval so hours asleep are not dumped into the next nudge.
5. After the configured interval of continuous sitting: hide windows, show the dialog, start the screensaver (each step can be turned off), then start a new interval.

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
