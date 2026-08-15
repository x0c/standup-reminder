# 运行与安装操作

## 文档定位

覆盖本机如何装上、如何看是否在计时、日志在哪。不解释「什么算离开」（见连续使用计时知识库）。

## 本机约定

这台电脑用仓库根目录 `./install.sh` 安装，可执行文件在 `~/.local/bin/standup-reminder`。不要再 `brew services start`，避免两套常驻。

## 启动与探活

```bash
./install.sh
STANDUP_FORCE_TEXT=1 ~/.local/bin/standup-reminder doctor
STANDUP_FORCE_TEXT=1 ~/.local/bin/standup-reminder status
```

自检必须显示正在计时。非终端环境下默认可能打出 JSON，看人话时加上 `STANDUP_FORCE_TEXT=1`。

## 日志

```bash
tail -f "$HOME/Library/Application Support/standup-reminder/run.log"
```

关键句：`检测到解锁，开始计时`、`计时中`、`检测到离开（screensaver|locked）`、`检测到系统唤醒`。

## 停止

```bash
~/.local/bin/standup-reminder stop
```

须卸掉登录项，否则会自己起来。

## 卸载

```bash
./install.sh --uninstall
```

状态目录默认保留。
