# OpenWrt Cloudflare 优选 IP 工具包

在 OpenWrt 路由器上给 Cloudflare 站点加速的完整方案，以及修复 `luci-app-cloudflarespeedtest` 在定制固件上「装了看不见」的一整套补丁。

> 本仓库的所有脚本都是在真实设备上踩完坑验证过的：  
> **Radxa E20C（ARMv8 四核）/ bleachwrt plus 20250629 / OpenWrt 24.10.1 / LuCI Master git-25.168 / 内核 6.12.34**

---

## 目录

- [一、要解决什么问题](#一要解决什么问题)
- [二、原理：为什么 Cloudflare 站点会慢](#二原理为什么-cloudflare-站点会慢)
- [三、两个方案怎么选](#三两个方案怎么选)
- [四、方案一：cf-optimizer（本地 DNS 优选）](#四方案一cf-optimizer本地-dns-优选)
- [五、方案二：修复并汉化 LuCI 插件](#五方案二修复并汉化-luci-插件)
- [六、诊断工具](#六诊断工具)
- [七、踩坑记录](#七踩坑记录)
- [八、FAQ](#八faq)

---

## 一、要解决什么问题

两个独立但相关的问题：

**问题 A：Cloudflare 上的站点，国内访问慢**

站点挂在 Cloudflare 上，但 CF 的任播调度不一定给你最优节点。实测一台国内电信线路的机器访问自己的 CF 站点，`/cdn-cgi/trace` 显示：

```
ip=122.188.63.155
loc=CN
colo=LAX        ← 被调度到洛杉矶
http=http/1.1
tls=TLSv1.3
```

国内 → 洛杉矶往返，TTFB 常在 1~4 秒，还伴随大量丢包和超时。而香港、日本节点往往只要几十毫秒。

**问题 B：`luci-app-cloudflarespeedtest` 装了，LuCI 里看不到菜单**

这是本仓库重点解决的问题。在定制固件上，这个插件会遇到**三层**独立的坑，缺任何一层都打不开。详见[第五节](#五方案二修复并汉化-luci-插件)。

---

## 二、原理：为什么 Cloudflare 站点会慢

Cloudflare 的 IP 是**任播**（anycast）的——同一个 IP 在全球几百个机房都有节点，用户的请求会落到哪个机房，由 BGP 路由决定。

问题在于：**这个调度结果不一定对国内线路最优**。运营商到 CF 各机房的互联质量差异很大，有时明明香港更近，流量却绕去了美西。

「优选 IP」的思路是：**主动测一遍 CF 公布的 IP 段，找出你这根宽带上延迟最低、丢包最少、速度最快的那个 IP，然后想办法让流量走它。**

关键前提：**Cloudflare 的任播 IP 是共享的**。任何一个 CF 边缘 IP 都能服务任何一个 CF 站点——它靠 TLS 的 SNI 和 HTTP 的 Host 头来识别你要访问哪个域名。所以换一个 IP 不会导致证书错误或找不到站点。

---

## 三、两个方案怎么选

|               | **方案一 cf-optimizer** | **方案二 LuCI 插件**      |
| ------------- | -------------------- | -------------------- |
| 原理            | 路由器 DNS 劫持           | 测速后把 IP 应用到代理/DNS 插件 |
| 影响范围          | 只有你自己家网络             | 取决于插件配置              |
| 要不要改 CF 后台    | **不用**               | 不用（除非开 CF DNS 同步）    |
| 橙云（Proxied）域名 | **能用**               | 能用                   |
| 需要装插件         | 不需要                  | 需要                   |
| 适合            | 只想让自己访问变快            | 想图形化管理、或要给代理节点优选     |

**如果你只是想让自己的博客/站点打开快一点，直接看方案一，五分钟搞定。**

方案二更适合这种情况：你路由器上跑着 PassWall / OpenClash，想让代理节点的 CF 出口 IP 也是优选的。

---

## 四、方案一：cf-optimizer（本地 DNS 优选）

### 4.1 它做什么

1. 用 `cfst`（XUII2/CloudflareSpeedTest）测出你这条宽带最优的 CF IP
2. 把最优 IP 写进路由器 dnsmasq：`www.example.com` → `104.18.x.x`
3. 局域网设备解析到这个 IP，浏览器连上去时 TLS SNI 仍是 `www.example.com`，CF 边缘按 SNI 找到你的站点并正常服务

### 4.2 为什么这个方案可行

- **不用改 Cloudflare 后台任何东西**，橙云可以继续开着，缓存和 WAF 都还在
- **只影响你自己家的网络**，公网其他访客不受影响，不影响 SEO
- 绕开了「灰云指向 CF IP 会触发 Error 1000」这个坑

### 4.3 安装

```sh
scp cf-optimizer/cf-optimizer.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1
chmod +x /tmp/cf-optimizer.sh
sh /tmp/cf-optimizer.sh install
```

安装会做四件事：

- 把脚本装到 `/usr/bin/cf-optimizer`
- 生成配置文件 `/etc/cf-optimizer.conf`
- 加一条 cron：每天 04:00 跑一次
- 检查 dnsmasq 配置是否存在

### 4.4 配置

```sh
vi /etc/cf-optimizer.conf
```

最少只要改一行：

```sh
DOMAINS="www.example.com example.com"
```

完整配置项：

| 配置项           | 默认值         | 说明                                  |
| ------------- | ----------- | ----------------------------------- |
| `ENABLED`     | `1`         | 总开关，0 = 只保留配置不执行                    |
| `DOMAINS`     | 空           | 要劫持的域名，空格分隔，子域名自动生效                 |
| `APPLY_MODE`  | `dnsmasq`   | `dnsmasq` / `hosts` / `none`        |
| `TOP_N`       | `1`         | 保留几个最优 IP                           |
| `MAX_LATENCY` | `200`       | 平均延迟上限（ms）                          |
| `PACKET_LOSS` | `0.2`       | 丢包率上限                               |
| `MIN_SPEED`   | `1`         | 下载速度下限（MB/s）                        |
| `THREADS`     | `100`       | 测速线程，弱路由器改 30~50                    |
| `GH_PROXY`    | 空           | GitHub 加速前缀，如 `https://ghfast.top/` |
| `CRON_SPEC`   | `0 4 * * *` | 定时任务                                |

### 4.5 先试跑

```sh
cf-optimizer test
```

输出类似：

```
=========== 可用 IP（按下载速度排序）===========
IP                 延迟(ms)     速度(MB/s)
104.18.2.3         45.23        12.34
172.67.1.2         88.10        3.20
===============================================
```

一个 IP 都没有？说明筛选条件太严，把 `MIN_SPEED` 调到 `0.5`、`MAX_LATENCY` 调到 `300` 再试。

### 4.6 正式应用

```sh
cf-optimizer run
```

看到 `已把 2 个域名指向 104.18.2.3（dnsmasq 已重载）` 就成功了。

### 4.7 常用命令

| 命令                       | 作用                |
| ------------------------ | ----------------- |
| `cf-optimizer install`   | 安装                |
| `cf-optimizer test`      | 只测速，不改配置          |
| `cf-optimizer run`       | 测速 + 验证 + 自动应用    |
| `cf-optimizer apply`     | 用上一次的最优 IP 重新应用   |
| `cf-optimizer status`    | 查看配置、生效规则、最近结果、日志 |
| `cf-optimizer update`    | 重新下载测速核心          |
| `cf-optimizer uninstall` | 卸载并清除所有规则         |

### 4.8 验证生效

```sh
# 1. 路由器返回的 IP 变了吗
nslookup www.example.com 192.168.1.1

# 2. 实际连的是哪个 IP
curl -o /dev/null -w 'ttfb:%{time_starttransfer}s total:%{time_total}s ip:%{remote_ip}\n' \
  --max-time 20 https://www.example.com/
```

### 4.9 设计上的安全措施

- **失败不覆盖**：测速失败、没有达标 IP、`curl --resolve` 验证不通过，一律保持现状，不会把你原本能用的配置搞坏
- **先删后加**：每次应用前先 `uci del_list` 掉上一轮写的规则，UCI 里不会越堆越多
- **原子状态**：当前生效的映射记在 `/etc/cf-optimizer/current`，卸载和更新靠它精确回滚
- **文件锁**：`/var/run/cf-optimizer.lock`，cron 和手动执行撞车时不会互相干扰

---

## 五、方案二：修复并汉化 LuCI 插件

这部分是给 `stevenjoezhang/luci-app-cloudflarespeedtest` 打的补丁。**在标准 OpenWrt 上你可能一层都遇不到；在定制固件上可能三层全中。**

### 5.1 先看结论：三层坑

| 层 | 现象      | 原因                                   | 解法                                   |
| - | ------- | ------------------------------------ | ------------------------------------ |
| 1 | 包装不上    | ipk 格式（ar vs gzip）、文件冲突、版本降级         | 用对格式的包，或直接装上游 release                |
| 2 | 菜单不显示   | `depends.acl` 判定失败，节点被 dispatcher 删掉 | 摘掉 `depends`，或补 ACL                  |
| 3 | 页面打不开   | 缺 `rpcd-mod-ucode`，ucode RPC 插件从未加载  | 装 `rpcd-mod-ucode` + `ucode-mod-uci` |
| 4 | 菜单永远不出现 | LuCI 是纯 Lua 版，不读 `menu.d/*.json`     | 自己写 Lua CBI 界面                       |

**第 3 层和第 4 层是最容易被忽略的**，也是为什么很多人「包装了、菜单点了、页面空白」。

### 5.2 步骤 1：装上游包

```sh
opkg install luci-app-cloudflarespeedtest_1.21.0_all.ipk
opkg install luci-i18n-cloudflarespeedtest-zh-cn_*.ipk
```

> 中文翻译本来就是 100% 完整的（po 文件 109 条，未翻译的 7 条全是插件名如 PassWall / MosDNS / Vssr，本就不该翻译），不用另外找汉化包。

### 5.3 步骤 2：补 RPC 依赖（第 3 层坑）

先确认缺不缺：

```sh
sh luci-plugin/diagnose/check-rpc.sh
```

如果看到 `/usr/lib/rpcd/` 下没有 `ucode.so`、`ubus list` 里也没有 `cloudflarespeedtest`，就是这个问题。

**原因**：这个插件是「JS 前端 + ucode RPC 后端」架构，后端那个 `.uc` 文件需要 `rpcd-mod-ucode` 才能被 rpcd 加载。精简固件经常裁掉这个包。

```sh
opkg update
opkg install rpcd-mod-ucode ucode-mod-uci
/etc/init.d/rpcd restart
sleep 2
ubus list | grep -i cloudflare      # 应该输出 cloudflarespeedtest
```

> ⚠️ 装 `ucode-mod-uci` 会顺带拉 `libuci20250120`。个别固件上这可能导致别的老插件（如 `luci-app-ddns`）出问题。如果遇到，可以 `opkg remove ucode-mod-uci libuci20250120` 回退——本仓库的 Lua 界面不依赖它。

### 5.4 步骤 3：判断你的 LuCI 是不是纯 Lua 版（第 4 层坑）

```sh
sh luci-plugin/diagnose/check-menu.sh
```

关键看两项：

- **`menu.d` 目录里有几个 JSON**：如果只有 1 个（就是本插件那个），而 passwall / openclash 等能正常显示的应用全是 `/usr/lib/lua/luci/controller/*.lua`，说明菜单只从 Lua 控制器来
- **`dispatcher.lua` 里有没有 `menu.d` 字样**：完全没有 = 这版 LuCI 不读 JSON 菜单

**如果是纯 Lua 版，改 JSON 永远无效**，必须自己写 Lua 界面。跳到步骤 4。

如果 `dispatcher.lua` 里有 `menu.d`，说明只是 ACL 问题，跑这个就行：

```sh
sh luci-plugin/fix-menu.sh
```

它会把菜单 JSON 里的 `depends.acl` 摘掉（备份成 `.bak`），清缓存，重启 rpcd/uhttpd。

### 5.5 步骤 4：安装 Lua CBI 界面

```sh
sh luci-plugin/install-lua-ui.sh
```

会写四个文件：

| 文件                                                            | 作用       |
| ------------------------------------------------------------- | -------- |
| `/usr/lib/lua/luci/controller/cloudflarespeedtest.lua`        | 菜单入口     |
| `/usr/lib/lua/luci/model/cbi/cloudflarespeedtest/general.lua` | CBI 配置表单 |
| `/usr/lib/lua/luci/view/cloudflarespeedtest/status.htm`       | 状态区      |
| `/usr/lib/lua/luci/view/cloudflarespeedtest/log.htm`          | 日志页      |

后端完全复用插件自带的 `cloudflarespeedtest.sh`。

刷新浏览器，**服务 → Cloudflare Speed Test**（装过中文语言包的话会显示「Cloudflare 速度测试」）。

> 如果菜单出来了但点进去报错，跑 `sh luci-plugin/fix-controller.sh`。它会用标准写法重写控制器。

### 5.6 步骤 5：修「测速参数不生效」（重要）

**这是插件上游的一个设计缺陷**，主脚本里：

```sh
if [ "${advanced:-0}" -eq "1" ] ; then
    command="${command} -tl ${tl:-200} ... -n ${threads:-200} ..."
else
    # Default param: -tl 200 -tll 40 -n 200 -t 4 -dt 10
    command="${command} -dn 5"
fi
```

**`advanced` 不开，界面上填的线程数、延迟上下限、下载时间全部被忽略，永远用内置的 200 线程。** 四核 ARM 跑 200 线程必然 CPU 100%。

```sh
sh luci-plugin/fix-advanced.sh
```

它会：

- 在界面上补出「启用高级参数」和「只测延迟」两个开关
- 把 uci 调成 `advanced=1 / threads=30 / speed_limit=3`

**推荐参数（四核 ARM 路由器）：**

| 参数     | 原值      | 建议     | 说明               |
| ------ | ------- | ------ | ---------------- |
| 测速线程   | 200（写死） | **30** | 主要元凶             |
| 下载速度下限 | 10 MB/s | **3**  | 设太高会扫完整个 IP 段都不停 |
| 只测延迟   | 关       | 先开着试   | 最省资源，但结果没有速度数据   |

### 5.7 步骤 6：下载测速核心

首次运行会从 GitHub 下载 `cfst_linux_<arch>.tar.gz`（约 2.75 MB，解压后 ~8 MB）。

**脚本不走系统代理**——它的 `wget`/`curl` 是裸调用，不读 `http_proxy`。而 PassWall/OpenClash 默认只劫持 LAN→WAN 转发流量，**不含路由器自身发起的请求**。

所以在国内必须先设镜像：

界面 →「设置」→ **GitHub 代理** → 选 `ghfast.top` 或 `ghproxy.cc`

或者命令行：

```sh
uci set cloudflarespeedtest.global.github_proxy='ghfast'
uci commit cloudflarespeedtest
```

**核心只下一次**，脚本里有守卫：

```sh
if [ ! -e /usr/bin/cdnspeedtest ]; then
    download_core ...
fi
```

装在 `/usr/bin/cdnspeedtest`，overlay 持久化，重启不丢，opkg 重装也不会删。

手动放置（下载实在不行时）：

```sh
# 浏览器下载 cfst_linux_arm64.tar.gz（按架构选）
scp cfst_linux_arm64.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1
cd /tmp && tar -xzf cfst_linux_arm64.tar.gz
mv cfst /usr/bin/cdnspeedtest && chmod +x /usr/bin/cdnspeedtest
```

架构对照：

| `uname -m`          | 包名                                                    |
| ------------------- | ----------------------------------------------------- |
| `aarch64`           | `cfst_linux_arm64.tar.gz`                             |
| `armv7l` / `armv8l` | `cfst_linux_armv7.tar.gz`                             |
| `x86_64`            | `cfst_linux_amd64.tar.gz`                             |
| `mips` / `mipsel`   | `cfst_linux_mips.tar.gz` / `cfst_linux_mipsel.tar.gz` |

### 5.8 步骤 7（可选）：Cloudflare 域名解析

> ⚠️ **先读这段再决定要不要用。**
>
> 如果你的域名 NS 托管在 Cloudflare（绝大多数情况），这个功能**基本无效**：
>
> - **橙云（Proxied）**：CF 返回自己的任播 IP，A 记录里填什么都被忽略
> - **灰云（DNS only）**：A 记录指向 CF 自己的 IP 会触发 `Error 1000: DNS points to prohibited IP`，站点直接打不开
>
> 真正能用的场景是：域名 NS 不在 Cloudflare（如 DNSPod），A 记录指向 CF IP；或用 Cloudflare for SaaS 的自定义主机名。
>
> **想验证？先建一个灰云的测试子域（如 `cf-test.example.com`），别拿主站试。**

```sh
sh luci-plugin/install-cf-dns.sh
```

会：

1. 写 `/usr/bin/cloudflarespeedtest/cloudflare.sh`
2. 给主脚本打三个补丁（备份 `.orig`、`sh -n` 校验、失败自动放弃、可重复执行）
3. 补 uci 默认值
4. 重写 CBI 表单，加出 6 个选项

界面上的选项：

| 选项              | 说明                                             |
| --------------- | ---------------------------------------------- |
| Cloudflare 域名解析 | 总开关                                            |
| API Token       | CF 后台 → 我的个人资料 → API 令牌，权限只需 `Zone → DNS → 编辑` |
| 域名（Zone）        | 主域名，不带 www                                     |
| 要更新的记录          | 可填多个，英文逗号分隔，记录必须已存在                            |
| TTL（秒）          | 默认 120                                         |
| 橙云记录也强制写入       | 默认关，橙云改了也不生效                                   |

用 API 查你的域名和记录（推荐先跑）：

```sh
# 列出账号下所有域名
/usr/bin/cloudflarespeedtest/cloudflare.sh --token <TOKEN> --list

# 列出某域名下的 A 记录
/usr/bin/cloudflarespeedtest/cloudflare.sh --token <TOKEN> --zone example.com --list

# 预演，看会改成什么（不实际写入）
/usr/bin/cloudflarespeedtest/cloudflare.sh --token <TOKEN> \
  --zone example.com --record www.example.com --dry-run
```

---

## 六、诊断工具

`luci-plugin/diagnose/` 下三个脚本，按顺序用：

### `check-rpc.sh` — 查 RPC 插件有没有加载

```sh
sh check-rpc.sh
```

检查 ucode 版本、rpcd 包、`/usr/lib/rpcd/*ucode*` 模块、插件目录、手动执行插件看报错、用 `luci` 对象做对照组。

**核心判据**：`ubus list | grep <插件名>` 有没有输出。

### `check-menu.sh` — 查菜单来源机制

```sh
sh check-menu.sh
```

对比「能显示的应用」和「不能显示的」，判断菜单是从 `menu.d` JSON 来的还是 Lua 控制器来的。

**核心判据**：`dispatcher.lua` 里有没有 `menu.d`。

### `diagnose.sh` — 综合诊断

```sh
sh diagnose.sh
```

一次性检查文件落地、JSON 合法性、uci 可读、ubus 注册、菜单树、缓存、opkg 文件清单、日志。

---

## 七、踩坑记录

详细的技术分析见 [`docs/PITFALLS.md`](docs/PITFALLS.md)，这里列结论：

### 坑 1：`workers.dev` 域名被污染

顺带发现的：`blog.xxx.workers.dev` 这类域名在国内被 DNS 污染，多个公共 DNS 返回的是 Twitter / Dropbox / Facebook 的 IP（IPv6 里带 `face:b00c` 是 Facebook 的特征）。直连 21 秒超时，必须挂代理。


**解法**：给 Worker 绑自定义域，别用 `workers.dev` 子域。

### 坑 2：ipk 有两种封装格式

```
标准 OpenWrt：b'!<arch>\n'  → ar 归档
某些固件：    b'\x1f\x8b'    → gzip 压缩的 tar
```

标准 opkg 两种都吃，但有些定制固件只认后者。打包时两种都出。

### 坑 3：主包内嵌 `.lmo` 会和官方语言包文件冲突

```
/usr/lib/lua/luci/i18n/cloudflarespeedtest.zh-cn.lmo
```

两个包都想装同一个文件，opkg 报 `check_data_file_clashes` 直接拒绝安装。

### 坑 4：`depends.acl` 会把菜单节点删掉

LuCI 的 `dispatcher.uc` 里：

```ucode
switch (check_acl_depends(node.depends.acl, acl["access-group"])) {
case null:  node.satisfied = false; break;   // ← 节点被标记为不满足
}
```

之后 `if (!child.satisfied)` 直接把它从菜单树里过滤掉。所以直接敲 URL 会看到：

```
No page is registered at '/admin/services/cloudflarespeedtest'.
```

**而 opkg 装完不会重启 rpcd**，ACL 组没加载，就必然触发。

### 坑 5：LuCI 的 `index()` 被 `setfenv` 过

`dispatcher.lua` 第 117-119 行：

```lua
setfenv(idx, setmetatable({}, { __index = luci.dispatcher }))()
```

**只对 `index()` 这一个函数换环境，且 `__index` 只指向 `luci.dispatcher`，没有 `_G` 兜底。**

推论（写 LuCI Lua 控制器必须遵守）：

| 位置 | `entry`/`cbi`/`template`/`call` | `pcall`/`os`/`io`/`_`/`string`/`type` |
|---|---|---|
| `index()` 里 | ✅ 能用 | ❌ 全是 nil |
| 其它函数里 | ❌ 是 nil | ✅ 能用 |

所以：

1. **所有 `entry()` 调用必须直接写在 `index()` 里**，不能塞进 helper 函数
2. `index()` 里不能用 `pcall` 兜底（它自己就是 nil）
3. 需要 `io`/`os` 时在模块顶层取成 upvalue

### 坑 6：这个固件把 Lua 的 `io` 库摘掉了

`local io = io` 在模块顶层取到的也是 `nil`。所以任何文件读写都得改用 `luci.sys.call("...")` 走 shell。

### 坑 7：`advanced` 开关控制一切

见 [5.6](#56-步骤-5修测速参数不生效重要)。

---

## 八、FAQ

**Q：装完还是英文？**

去 **System → System → Language** 选简体中文。LuCI 的语言是全局设置，单个插件强制不了。

**Q：菜单补丁会不会被覆盖？**

会。重装插件或升级固件时 `/usr/share/luci/menu.d/*.json` 会恢复成原版。重跑 `fix-menu.sh` 即可（Lua 控制器那几个文件不会被动）。

**Q：`opkg remove` 之后菜单还在？**

因为 Lua 界面文件是独立写入的，不属于任何包，opkg 不知道它们存在。手动删：

```sh
rm -f  /usr/lib/lua/luci/controller/cloudflarespeedtest.lua
rm -rf /usr/lib/lua/luci/model/cbi/cloudflarespeedtest
rm -rf /usr/lib/lua/luci/view/cloudflarespeedtest
rm -f  /usr/share/luci/menu.d/luci-app-cloudflarespeedtest.json*
rm -f  /etc/config/cloudflarespeedtest
rm -f  /tmp/luci-indexcache
```

**Q：测速时 CPU 100%？**

先看是谁：

```sh
top -bn1 | head -12
```

是 `cdnspeedtest` → 跑 `fix-advanced.sh` 降线程。不是它 → 跟本插件无关。

**Q：浏览器开了 DoH 会影响 cf-optimizer 吗？**

会。DoH/DoT 会让 DNS 查询绕过路由器，劫持失效。要么在浏览器里关掉「安全 DNS」，要么在路由器上拦截。

**Q：能不能用来加速 `workers.dev` 域名？**

不能。那个域名本身在国内被污染，DNS 层就被劫持了，换 IP 没用。给 Worker 绑自定义域才行。

---

## 许可

脚本部分 MIT。`luci-plugin/` 下的补丁针对 [stevenjoezhang/luci-app-cloudflarespeedtest](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest)（AGPL-3.0），未修改上游代码，仅新增文件与运行时补丁。

`cfst` 二进制来自 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)，运行时下载，不随本仓库分发。
