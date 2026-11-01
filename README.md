# dsh-web launcher

把 DeepSeek Harness 的 **Web host** 用 launchd 常驻，手机 / 本机浏览器共用一个会话库。
两种接法：直接绑 Tailscale IP（HTTP），或 `127.0.0.1` + `tailscale serve`（HTTPS，推荐）。
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
2. **解析绑定地址**：`DSH_WEB_HOST` 优先；没设就 `tailscale ip -4`（接口没起来等 60 秒）。
3. **启动**：`dsh web --host <addr> --port 8443 --no-open`，`DSH_WEB_PUBLIC_URL` / `DSH_WEB_TRUSTED_HOST` 会透传成 `--public-url` / `--trusted-host`。

日志在 `~/Library/Logs/dsh-web.log`（umask 077，含 token）。

## 必须知道的限制

- **和桌面 App 互斥**：同一个会话同一时刻只能有一个 host 持有写锁（内核 flock）。桌面 App 开着时，这个服务会等它退出；反过来服务在跑时，桌面 App 打开会话会报 `SessionAlreadyOwned`。要二选一。
- **web profile 是独立的一套插件配置**：首次启动会在 `~/.dsh/profiles/web` 初始化。默认模型、MCP（kimi-cu）要单独配——否则同一个会话在手机上会提示「N 个工具被删除」。会话、工作区、账号凭据是共享的。
- **office 技能只有桌面端有**：它由 Electron 进程注入，不是 profile 配置，web 端拿不到。
- **token 每个进程随机**：服务重启后旧地址失效（已签发的 cookie 还有效）。重跑 `dsh-web-url`。
- **裸端口 401**：`http://ip:8443/` 不带 cookie 就是 401，这是设计，不是坏了。

## 两种接入方式

### A. 直接绑 Tailscale IP（HTTP）

`dsh-web` 启动时解析 `tailscale ip -4` 并 `--host <ts-ip>`。tailscaled 把 IP 挂在 utun 上，内核直接投递到 socket。

- 手机 / 本机：`http://<tailscale-ip>:8443/`
- 优点：没有额外一跳，最简单
- 缺点：明文 HTTP；手机侧剪贴板 API / PWA 安装需要 secure context，用不了

本机浏览器如果被系统代理（`127.0.0.1:3128`）拦成 502，把 `100.64.0.0/10` 加进代理排除列表即可。

### B. 127.0.0.1 + `tailscale serve`（HTTPS，推荐）

tailscaled 在 tailnet 的 443 上终止 TLS 并反代到本地 loopback，dsh 不用自己管证书。

**前置**（Tailscale 管理台 → DNS）：

- 打开 **MagicDNS**
- 打开 **HTTPS Certificates**（`tailscale cert` 报 “account does not support getting TLS certs” 就是这里没开）

**配置**：

```sh
# 1) serve：tailnet 443 -> 本地 loopback
tailscale serve --bg --https=443 http://127.0.0.1:8443

# 2) 让 dsh 只绑 loopback，并把对外地址告诉它（写进 plist 的 EnvironmentVariables）
#    DSH_WEB_HOST=127.0.0.1
#    DSH_WEB_PUBLIC_URL=https://<machine>.<tailnet>.ts.net
#    DSH_WEB_TRUSTED_HOST=<machine>.<tailnet>.ts.net

# 3) 重载生效
dsh-mode restart
```

`dsh-mode restart` 走的是 bootout + bootstrap，会重新读 plist；`launchctl kickstart` **不会**，改了 plist 必须用前者。

**踩过的坑**：

- `serve` 的上游**必须是 127.0.0.1**。指到 `100.x` 会挂住：TLS 握手能完成，但请求永远等不到响应（tailscaled 自己 hairpin 自己的 tailnet IP）
- `serve` 会**原样透传 Host**（实测 `Host: <machine>.<tailnet>.ts.net`），所以 cookie 按这个 authority 签发，正常；但 `/api` 的 host fence 不认这个域名，必须配 `DSH_WEB_TRUSTED_HOST`
- 证书 90 天，`serve` 会自动续，不用管
- 入站是 tailscaled 接的：换成 sing-box 这类**用户态** Tailscale 端点没有 `serve` 能力，模式 B 走不通，只能模式 A

## 安全

这个地址等于这台机器的完整 shell 权限（DSH 能跑命令）。

- 只在 tailnet 内用，**不要**开 Tailscale Funnel；
- 别把带 token 的 URL 贴进聊天、截图、issue；
- 有条件给 8443 加 tailnet ACL，只放行自己的设备；
- 日志文件含 token，别随便 `cat` 到公开的地方。

## 备选：dsh 自己挂证书

不想用 `serve` 的话，也可以让 dsh 直接讲 TLS（绑 100.x 或 loopback 都行）：

```sh
tailscale cert --cert-file ~/.dsh/tls/cert.pem --key-file ~/.dsh/tls/key.pem <machine>.<tailnet>.ts.net
# 再给 dsh web 加 --tls-cert/--tls-key/--public-url
```

代价是证书 90 天到期后要重签并重启；`serve` 那条路会自动续期。

## 排错

```sh
dsh-mode                       # 一眼看谁在跑
dsh-web-url                    # 地址 + launchd 状态 + HTTP 码
bin/dsh-web --dry-run          # 看锁在谁手里、会绑哪个地址
tailscale serve status         # HTTPS 模式：反代目标对不对
tail -n 40 ~/Library/Logs/dsh-web.log
lsof -nP -iTCP:8443 -sTCP:LISTEN
```

常见原因：桌面 App 还开着（等锁超时 → 退出 0，服务不重启）；Tailscale 没登录（退出 1，每 30 秒重试）；App 被移动/改名（找不到 CLI，退出 1）；HTTPS 模式 502（`serve` 正常但上游没起——dsh 还绑在 100.x，或根本没启动）；改了 plist 但用的是 `kickstart`（不重载配置）。
