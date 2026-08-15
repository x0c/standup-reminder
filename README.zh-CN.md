# standup-reminder

**语言：** [English](README.md) | 简体中文

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

一个很小的 macOS 后台提醒：你在电脑前连续待太久，就藏起窗口、弹出提示、打开屏保，逼你起身活动。比通知中心里那种一滑就没的提醒难忽略。

和「只从开机/唤醒开始数」的工具不同：锁屏或屏保算离开，但**未满 3 分钟又回来视为没起身**，接着计；满 3 分钟才从零开始。自动熄屏两分钟再亮，不会把这一小时打断。

## 支持的平台

**仅 macOS。** 不支持 Linux / Windows——依赖登录项、屏保和本机会话状态。在其他系统上安装脚本会明确报错退出。

## 安装

### Homebrew（推荐）

```bash
brew install x0c/tap/standup-reminder
brew services start standup-reminder
standup-reminder doctor
standup-reminder now
```

`doctor` 必须显示正在计时。`now` 会立刻响一次，用来确认真的会弹，而不是只看到「进程在跑」。

### 一键安装（不用 Homebrew）

```bash
curl -fsSL https://raw.githubusercontent.com/x0c/standup-reminder/main/install.sh | bash
```

安装脚本会拷贝程序、登记登录自启、等到确认已经开始计时；如果看起来不对，会打印 `doctor` / `now` 让你接着查。

## 用法

```bash
standup-reminder status     # 在不在跑、在不在计时、还有多久提醒
standup-reminder doctor     # 装了但不响，先跑这条
standup-reminder now        # 立刻试响一次
standup-reminder stop       # 停掉并取消登录自启
standup-reminder --dry-run  # 只记日志，不藏窗口 / 不弹窗 / 不启屏保
standup-reminder --help
```

`status` 和 `doctor` 支持 `--json`，给脚本用。

## 配置

用环境变量。Homebrew：改服务配置。安装脚本：改 `~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist` 里的环境变量。

| 变量 | 默认 | 含义 |
|---|---|---|
| `REMINDER_INTERVAL` | `2700`（45 分钟；安装/brew 默认 `3600`） | 连续解锁使用多久后提醒 |
| `REMINDER_MESSAGE` | `起身走动一下~` | 弹窗文案 |
| `AWAY_DEBOUNCE_SECONDS` | `180`（3 分钟） | 离开多久才清零。未满又回来则接着计 |
| `STATE_DIR` | `~/Library/Application Support/standup-reminder` | 状态与日志目录 |
| `LOG_FILE` | `$STATE_DIR/run.log` | 日志路径 |
| `STANDUP_DRY_RUN` | `0` | `1` = 只记日志 |

改完登录项文件后重新加载，并再跑一次自检：

```bash
launchctl unload ~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist
launchctl load   ~/Library/LaunchAgents/io.github.x0c.standup-reminder.plist
standup-reminder doctor
```

## 怎么计时

每 10 秒看一次：

1. 屏保、锁屏、或控制台已登出 → **离开**。
2. 会话状态看不清 → **按正在使用处理**。提醒工具不能因为前台应用名解析失败就永远不响。
3. 离开未满 3 分钟又回来 → **接着计**（离开那段也算坐着）。满 3 分钟才清零。
4. 休眠把进程冻住超过 3 分钟 → 醒来后从零计，避免把睡着的几小时算进去。
5. 连续坐满设定时长：藏窗口、弹提示、开屏保，然后重新计时。

## 装了但从不提醒

```bash
standup-reminder doctor
tail -f "$HOME/Library/Application Support/standup-reminder/run.log"
standup-reminder now
```

`doctor` 区分的是「进程在跑」和「真的在对着你计时」。如果你人就在电脑前，自检却说暂停了，日志里会写出原因。

## 卸载

Homebrew：

```bash
brew services stop standup-reminder
brew uninstall standup-reminder
```

安装脚本：

```bash
./install.sh --uninstall
```

## 运行要求

macOS。只用系统自带能力，不用编译。

## 许可证

[MIT](LICENSE)
