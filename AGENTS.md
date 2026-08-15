# standup-reminder

通用工程规范：本仓库是纯 Bash 的 macOS 登录项，不套用 Go/Swift/前端规范。

改锁屏/使用中判断、提醒触发、安装自检、发版或排「装了从不响」前 **必读** 本文。漏读的后果：进程看起来在跑，但永远不会提醒。

## 产品行为

- 连续解锁使用满间隔后：藏窗口 → 弹「起身走动一下~」→ 开屏保。
- 锁屏、屏保、系统休眠唤醒：重置计时，不把离开的时间算进去。
- **判断失败按正在使用处理**，禁止再写成「看不清前台应用就当成锁屏」。那是 v0.1.0 从不提醒的根因。
- **离开（热角屏保、锁屏）必须用系统会话锁屏标记 + 屏保是否在跑**，禁止只扫旧屏保进程名。那是 v0.2.0 热角锁屏不清零的根因。
- `status` 必须能回答「在不在计时、还有多久」；只说「进程在跑」不算可用。
- 安装结束必须等到自检通过，或明确叫用户跑 `doctor` / `now`。禁止报「已启动」就收工。

## 命令

| 命令 | 用途 |
|---|---|
| `status` | 运行中 / 计时中 / 距下次提醒 |
| `doctor` | 装了但不响时的自检（退出码 0 才算健康） |
| `now` | 立刻试响 |
| `stop` | 停进程并卸登录项（不要做成杀了又被拉起） |
| `--dry-run` | 只写日志 |

`status` / `doctor` 支持 `--json`：`{ok,data,error,meta}`，失败也走 stdout JSON + 非零退出码。

## 验证

```bash
bash tests/test.sh
```

改判断或安装后还要本机实装：

1. `./install.sh`
2. `standup-reminder doctor` 显示正在计时
3. 日志出现「检测到解锁，开始计时」
4. `STANDUP_DRY_RUN=1 standup-reminder now` 走完流程；需要确认真弹窗时再跑不带演练的 `now`（会藏窗口并开屏保）

## 发版

1. 改 `standup-reminder.sh` 里的 `VERSION`
2. `bash tests/test.sh`
3. 提交后打 `v*` 标签并推 `origin`
4. `bash scripts/publish-release.sh`（建 Release + 写 `x0c/homebrew-tap` 配方，防版本回退）
5. 本机 `./install.sh` 覆盖安装，再跑 `doctor`

不要另开分支。不要等 GitHub Actions 才让用户升到新版。

## 文档导航

- `README.md` / `README.zh-CN.md`：对外安装与使用。改安装渠道或命令面时两边一起改。
- `docs/TROUBLESHOOTING.md`：排「装了从不响」时必读，否则会把「进程在跑」误当成已经生效。
