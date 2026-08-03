# standup-reminder

A tiny, dependency-free macOS daemon that nudges you to **get up and move** after you've been continuously at your Mac for too long.

When your continuous-use timer crosses the threshold, it hides all visible windows, pops a reminder dialog, and kicks off the screensaver — so you actually take the break instead of dismissing a notification and carrying on. The timer pauses when you lock the screen and resumes when you unlock, so idle time doesn't count against you.

- Pure Bash + built-in macOS tools (`launchctl`, `osascript`, `pmset`-free) — nothing to compile, no runtime deps.
- Accurate lock/unlock detection (console user + `ScreenSaverEngine`/`LockScreen` checks).
- Single-instance lock, graceful shutdown, and a dry-run mode for testing.
- Fully configurable via environment variables.

## Install

### Homebrew (recommended)

```bash
brew install x0c/tap/standup-reminder
brew services start standup-reminder
```

`brew services` registers it as a launchd agent that starts at login and restarts if it dies.

### One-line installer (no Homebrew)

```bash
curl -fsSL https://raw.githubusercontent.com/x0c/standup-reminder/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/x0c/standup-reminder.git
cd standup-reminder
./install.sh
```

The installer copies the script to `~/.local/bin/standup-reminder`, writes a launchd agent to `~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist`, and loads it.

## Usage

```bash
standup-reminder            # run the daemon loop in the foreground (usually launchd-managed)
standup-reminder status     # is the daemon running?
standup-reminder stop       # stop the running daemon
standup-reminder --dry-run  # run but only log — never hide windows / show dialog / start screensaver
standup-reminder --help
standup-reminder --version
```

## Configuration

Set these as environment variables (for Homebrew, edit the service; for the installer, edit the plist's `EnvironmentVariables`).

| Variable            | Default                                              | Description |
|---------------------|------------------------------------------------------|-------------|
| `REMINDER_INTERVAL` | `2700` (45 min; installer/brew default `3600`)       | Continuous-use seconds before a reminder fires. |
| `REMINDER_MESSAGE`  | `起身走动一下~`                                       | Dialog text. |
| `STATE_DIR`         | `~/Library/Application Support/standup-reminder`     | Where the PID file and logs live. |
| `LOG_FILE`          | `$STATE_DIR/run.log`                                 | Log file path. |
| `STANDUP_DRY_RUN`   | `0`                                                  | `1` = log only, take no visible action. |

To change the interval after a Homebrew install:

```bash
brew services stop standup-reminder
# edit the interval, or set it via a launchd override, then:
brew services start standup-reminder
```

For the installer, edit `REMINDER_INTERVAL` in `~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist`, then reload:

```bash
launchctl unload ~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist
launchctl load   ~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist
```

## How it works

The daemon polls every 10 seconds:

1. **Unlocked?** It checks the console user and whether `ScreenSaverEngine` / `LockScreen` / `loginwindow` is frontmost. If the screen is locked or the saver is up, the timer is paused and reset.
2. **Timing.** On the first unlocked tick it records a start time. Once `now - start ≥ REMINDER_INTERVAL`, it fires.
3. **Firing.** It hides every visible app's windows, launches the screensaver, and shows a reminder dialog (auto-dismiss after 30s). Then it resets the timer.

A PID file guarantees only one instance runs; the process cleans up its PID on exit.

## Logs

```bash
tail -f "$HOME/Library/Application Support/standup-reminder/run.log"
```

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

macOS (uses `launchctl`, `osascript`, `lsappinfo`, `stat`). No other dependencies.

## License

[MIT](LICENSE)
