#!/bin/bash
set -euo pipefail

# standup-reminder 一键安装脚本（面向不使用 Homebrew 的用户）
# - 把 standup-reminder.sh 安装到 ~/.local/bin/standup-reminder
# - 生成 launchd plist 到 ~/Library/LaunchAgents 并加载
# 用法:
#   ./install.sh              安装并启动
#   ./install.sh --uninstall  卸载并清理
# 也支持 curl 一键（无本地脚本时自动从 GitHub 下载）:
#   curl -fsSL https://raw.githubusercontent.com/x0c/standup-reminder/main/install.sh | bash

REPO="x0c/standup-reminder"
LABEL="io.github.x0c.standup-reminder"
BIN_DIR="$HOME/.local/bin"
BIN_PATH="$BIN_DIR/standup-reminder"
STATE_DIR="$HOME/Library/Application Support/standup-reminder"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[32m==>\033[0m %s\n' "$*"; }
err()  { printf '\033[31m错误:\033[0m %s\n' "$*" >&2; }

require_macos() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    err "standup-reminder 仅支持 macOS"
    exit 1
  fi
}

unload_agent() {
  # 幂等卸载：无论是否已加载都不报错
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
}

do_uninstall() {
  info "停止并卸载 launchd 服务"
  unload_agent
  rm -f "$PLIST_PATH"
  info "删除可执行文件 $BIN_PATH"
  rm -f "$BIN_PATH"
  info "已卸载。状态与日志目录保留在 ${STATE_DIR}（如需彻底清理请手动删除）"
}

install_binary() {
  mkdir -p "$BIN_DIR" "$STATE_DIR"

  if [[ -f "$SCRIPT_DIR/standup-reminder.sh" ]]; then
    info "从本地安装脚本到 $BIN_PATH"
    cp "$SCRIPT_DIR/standup-reminder.sh" "$BIN_PATH"
  else
    info "从 GitHub 下载脚本到 $BIN_PATH"
    curl -fsSL "https://raw.githubusercontent.com/$REPO/main/standup-reminder.sh" -o "$BIN_PATH"
  fi
  chmod +x "$BIN_PATH"
}

install_agent() {
  info "生成 launchd 配置 $PLIST_PATH"
  mkdir -p "$(dirname "$PLIST_PATH")"

  local template
  if [[ -f "$SCRIPT_DIR/com.github.x0c.standup-reminder.plist" ]]; then
    template="$(cat "$SCRIPT_DIR/com.github.x0c.standup-reminder.plist")"
  else
    template="$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/com.github.x0c.standup-reminder.plist")"
  fi

  # 用真实路径替换模板占位符
  template="${template//__BIN_PATH__/$BIN_PATH}"
  template="${template//__STATE_DIR__/$STATE_DIR}"
  printf '%s\n' "$template" >"$PLIST_PATH"

  info "加载服务"
  unload_agent
  launchctl load "$PLIST_PATH"
}

do_install() {
  install_binary
  install_agent
  info "安装完成，standup-reminder 已随登录自动运行"
  echo
  echo "常用命令:"
  echo "  standup-reminder status     # 查看运行状态"
  echo "  standup-reminder stop        # 手动停止（launchd 会自动重启）"
  echo "  tail -f \"$STATE_DIR/run.log\"  # 查看日志"
  echo
  echo "自定义提醒间隔（如改为 30 分钟）："
  echo "  1) 编辑 $PLIST_PATH 中 REMINDER_INTERVAL 的值（单位：秒）"
  echo "  2) launchctl unload \"$PLIST_PATH\" && launchctl load \"$PLIST_PATH\""
  echo
  echo "卸载: $BIN_PATH 所在项目的 install.sh --uninstall"
}

main() {
  require_macos
  case "${1:-install}" in
    --uninstall|uninstall)
      do_uninstall
      ;;
    install|"")
      do_install
      ;;
    *)
      err "未知参数: $1（支持: install | --uninstall）"
      exit 2
      ;;
  esac
}

main "$@"
