# dsh-web launcher

把 DeepSeek Harness 的 **Web host** 绑到本机 Tailscale IPv4 上，手机 / 本机浏览器共用一个会话库。
用 App 自带的 CLI（当前 `0.2.1-rc.5`，和桌面端同版本），不需要装 Node。

```
bin/dsh-web          包装脚本：等会话锁 → 解析 Tailscale IP → exec dsh web
bin/dsh-web-url      打印带 token 的访问地址 + 服务状态
bin/dsh-mode         一键切换 / 重启：dsh-mode app | web | restart | url
install.sh           装到 ~/.local/bin 和 ~/Library/LaunchAgents
uninstall.sh         卸载
com.deepseek.dsh-web.plist.in   launchd 模板
```

## 日常

```sh
dsh-mode           # 谁在跑
dsh-mode app       # 停 Web 服务，打开桌面版
dsh-mode web       # 退出桌面版，起 Web 服务，打印地址
dsh-mode restart   # 重启 Web 服务（升级 App 后用这个）
dsh-mode url       # 只要地址
```

`dsh-mode web` 会自己等 App 退出、等会话锁释放、确认端口起来再打印 URL；`dsh-mode app` 会先 bootout 服务再 `open`。

**不用记 `launchctl kickstart`**，一律用 `dsh-mode restart`。它失败时会打日志尾，不会静默。

## 升级（会忘就看这里）

1. 打开一次 **DeepSeek Harness.app**。它启动时从 `https://download.deepseek.com/dsh-desk/feeds/mac-arm64/`（nightly 频道）自更新；**不启动就不会检查更新**。
2. `dsh-mode restart`
3. `dsh -V` 或 `dsh-mode status` 确认版本。

升级前备份一下 `~/.dsh`（会话格式会迁移，不可逆）：

```sh
tar -czf ~/dsh-backup-$(date +%F).tgz -C ~ .dsh/sessions .dsh/storages .dsh/profiles
```

别同时用 npm 版和 App 版两个 runtime 指向同一个 `~/.dsh`，版本不一致会打架。

## cookie 到期怎么办

`?token=` 是进程级、每次启动都变，只印在日志里，`dsh-web-url` 随时能取。
**30/365 天是 cookie 的有效期**，到期前用 `dsh-web-url` 的链接打开一次就续期，不用重启服务。

本机已把有效期改成 **365 天**（web profile 的 `connection` 行）：

```yaml
# ~/.dsh/profiles/web/cordis.patch.yml
- id: connection
  name: "@deepseek-ai/dsh-client-connection"
  config:
    trustedHosts: !!js ctx.webStartup.trustedHosts
    cookieMaxAgeDays: 365
```

验证新签发的 cookie：带 token 请求一次，看 `Set-Cookie` 里 `Max-Age=31536000`。

## 安装

```sh
sh install.sh            # 只装文件
sh install.sh --start    # 装完立刻 bootstrap（会等桌面 App 释放会话锁）
```

启动 / 重启：

```sh
dsh-mode restart
```

## 它做了什么

1. **等锁**：`~/.dsh/sessions/*/*/session.lock` 被别的进程打开着（桌面 App 常驻时会这样），就每 5 秒看一次，最多等 10 分钟（`DSH_WEB_WAIT_SECONDS`）。
2. **解析 IP**：`tailscale ip -4`，接口没起来就等 60 秒。
3. **启动**：`dsh web --host <ts-ip> --port 8443 --no-open`。

日志在 `~/Library/Logs/dsh-web.log`（umask 077，含 token）。

## 必须知道的限制

- **和桌面 App 互斥**：同一个会话同一时刻只能有一个 host 持有写锁（内核 flock）。桌面 App 开着时，这个服务会等它退出；反过来服务在跑时，桌面 App 打开会话会报 `SessionAlreadyOwned`。要二选一。
- **web profile 是独立的一套插件配置**：首次启动会在 `~/.dsh/profiles/web` 初始化。默认模型、MCP（kimi-cu）要单独配——否则同一个会话在手机上会提示「N 个工具被删除」。会话、工作区、账号凭据是共享的。
- **office 技能只有桌面端有**：它由 Electron 进程注入，不是 profile 配置，web 端拿不到。
- **token 每个进程随机**：服务重启后旧地址失效（已签发的 cookie 还有效）。重跑 `dsh-web-url`。
- **裸端口 401**：`http://ip:8443/` 不带 cookie 就是 401，这是设计，不是坏了。

## 网络

手机和 Mac 本机都用 `http://<tailscale-ip>:8443/`。

本机浏览器如果被系统代理（`127.0.0.1:3128`）拦成 502，把 `100.64.0.0/10` 加进代理排除列表即可——不需要额外的本地监听。

## 安全

这个地址等于这台机器的完整 shell 权限（DSH 能跑命令）。

- 只在 tailnet 内用，**不要**开 Tailscale Funnel；
- 别把带 token 的 URL 贴进聊天、截图、issue；
- 有条件给 8443 加 tailnet ACL，只放行自己的设备；
- 日志文件含 token，别随便 `cat` 到公开的地方。

## 想要 HTTPS（可选）

手机上的剪贴板 API、PWA 安装需要 secure context。两条路：

1. dsh 自带 TLS：
   ```sh
   tailscale cert --cert-file ~/.dsh/tls/cert.pem --key-file ~/.dsh/tls/key.pem mac-mini.<tailnet>.ts.net
   # 然后在 bin/dsh-web 的 exec 行加 --tls-cert/--tls-key，并加 --public-url https://mac-mini.<tailnet>.ts.net:8443
   ```
   需要先在 Tailscale 管理台打开 HTTPS Certificates，且 MagicDNS 要开。
2. `tailscale serve` 反代到 `127.0.0.1:8443`：可行，但 cookie 按 Host/authority 绑定，Host 必须透传，还要给 dsh 加 `--trusted-host`，不如第 1 条稳。

## 排错

```sh
dsh-mode                       # 一眼看谁在跑
dsh-web-url                    # 地址 + launchd 状态 + HTTP 码 + 最近日志行
bin/dsh-web --dry-run          # 看锁在谁手里、会绑哪个地址
tail -n 40 ~/Library/Logs/dsh-web.log
lsof -nP -iTCP:8443 -sTCP:LISTEN
```

常见原因：桌面 App 还开着（等锁超时 → 退出 0，服务不重启）；Tailscale 没登录（退出 1，每 30 秒重试）；App 被移动/改名（找不到 CLI，退出 1）。
