# cf-optimizer —— OpenWrt Cloudflare 优选 IP 自动化

一个单文件脚本，装在 OpenWrt 路由器上，定时测出你这条宽带访问 Cloudflare
最快的那几个 IP，然后自动写进 dnsmasq，让局域网里所有设备访问指定域名时
都走最快的那个 IP。

专为「自己的博客/站点挂在 Cloudflare 上、国内访问慢」这种场景写的。

---

## 它解决什么问题

Cloudflare 的任播会把国内用户调度到某个机房，但**这个调度结果不一定是最优的**。
比如实测中 `www.akkdiy.cn` 被调度到了洛杉矶（`colo=LAX`），而香港、日本节点
往往快得多。

本工具做的事：

1. 用 `cfst`（CloudflareSpeedTest）把 Cloudflare 公布的 IP 段全测一遍，
   找出**你这根宽带**真正快、丢包低的 IP
2. 把最优 IP 写进路由器的 dnsmasq：`www.akkdiy.cn` → `104.18.x.x`
3. 局域网设备解析到该 IP，浏览器连上去时 TLS SNI 依然是 `www.akkdiy.cn`，
   Cloudflare 边缘按 SNI 找到你的站点并正常服务

因为 Cloudflare 的任播 IP 是**共享**的，任何一个 CF 边缘 IP 都能服务任何
CF 站点，所以这个办法成立。

### 相比其他方案的好处

- **不用改 Cloudflare 后台任何东西**，橙云（Proxied）可以继续开着，
  缓存和 WAF 都还在
- **只影响你自己家的网络**，公网其他访客不受影响，不会影响 SEO
- 不用担心灰云指向 CF IP 触发的 `Error 1000`
- 换 IP 是自动的，网络环境变了会自己重新选

---

## 安装

### 1. 把脚本传到路由器

```sh
scp cf-optimizer.sh root@192.168.1.1:/tmp/
```

### 2. 登录路由器执行安装

```sh
ssh root@192.168.1.1
chmod +x /tmp/cf-optimizer.sh
sh /tmp/cf-optimizer.sh install
```

安装会做四件事：

- 把脚本装到 `/usr/bin/cf-optimizer`
- 生成配置文件 `/etc/cf-optimizer.conf`
- 加一条 cron：每天 04:00 跑一次
- 检查 dnsmasq 配置是否存在

### 3. 改配置

```sh
vi /etc/cf-optimizer.conf
```

最少只要改一行：

```sh
DOMAINS="www.akkdiy.cn akkdiy.cn"
```

### 4. 先试跑，看能不能测出好 IP

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

如果这里一个 IP 都没有，说明筛选条件太严，去配置里把 `MIN_SPEED` 调小
（比如 `0.5`）、`MAX_LATENCY` 调大（比如 `300`）。

### 5. 正式跑一次

```sh
cf-optimizer run
```

看到 `已把 2 个域名指向 104.18.2.3（dnsmasq 已重载）` 就成功了。

---

## 常用命令

| 命令 | 作用 |
|---|---|
| `cf-optimizer install` | 安装主程序 + 定时任务 + 生成默认配置 |
| `cf-optimizer test` | 只测速并列出可用 IP，不改任何配置 |
| `cf-optimizer run` | 测速 + 验证 + 自动应用到 dnsmasq |
| `cf-optimizer apply` | 用上一次的最优 IP 重新应用一次 |
| `cf-optimizer status` | 查看配置、当前生效规则、最近结果和日志 |
| `cf-optimizer update` | 重新下载测速核心 cfst |
| `cf-optimizer uninstall` | 卸载并清除所有规则 |

---

## 配置项说明

```sh
ENABLED=1                 # 总开关，0 = 只保留配置但不执行
DOMAINS="www.akkdiy.cn"   # 要劫持的域名，空格分隔，子域名自动生效
APPLY_MODE="dnsmasq"      # dnsmasq / hosts / none
TOP_N=1                   # 保留几个最优 IP（dnsmasq 模式只用第 1 个）
MAX_LATENCY=200           # 平均延迟上限(ms)
PACKET_LOSS=0.2           # 丢包率上限，0~1
MIN_SPEED=1               # 下载速度下限(MB/s)
THREADS=100               # 测速线程，弱路由器改成 30~50
PING_TIMES=4              # 单 IP 延迟测速次数
DL_COUNT=5                # 下载测速的 IP 数量
DL_TIME=5                 # 单个 IP 下载测速时长(秒)
TEST_URL="https://speed.cloudflare.com/__down?bytes=20000000"
GH_PROXY=""               # GitHub 加速前缀，国内拉不动核心时填
CRON_SPEC="0 4 * * *"     # 定时任务，默认每天 04:00
```

### APPLY_MODE 怎么选

- **`dnsmasq`（推荐）**：写进 UCI 的 `dhcp.@dnsmasq[0].address`，重启不丢，
  全屋生效
- **`hosts`**：写 `/etc/hosts`。OpenWrt 上 `/etc/hosts` 是 `/tmp` 的软链，
  重启会丢，只适合临时调试
- **`none`**：只测速、只记录，不动配置。适合你只想看看哪些 IP 快

### 关于 GH_PROXY

脚本首次运行需要从 GitHub Releases 下载 `cfst` 核心。国内经常拉不动，
这时在配置里填一个加速前缀即可：

```sh
GH_PROXY="https://ghproxy.net/"
```

脚本会自动拼成 `https://ghproxy.net/https://github.com/...`。
也可以手动把核心放进去：

```sh
# 在电脑上下载 cfst_linux_arm64.tar.gz（按路由器架构选）
scp cfst_linux_arm64.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1
cd /tmp && tar -xzf cfst_linux_arm64.tar.gz
mv cfst /usr/bin/cfst && chmod +x /usr/bin/cfst
```

架构对照：`uname -m` 输出 → 下载哪个包

| uname -m | 包名 |
|---|---|
| `x86_64` | `cfst_linux_amd64.tar.gz` |
| `aarch64` | `cfst_linux_arm64.tar.gz` |
| `armv7l` | `cfst_linux_armv7.tar.gz` |
| `mips` / `mipsel` | `cfst_linux_mips.tar.gz` / `cfst_linux_mipsle.tar.gz` |

---

## 怎么验证生效了

### 1. 看路由器返回的 IP

```sh
nslookup www.akkdiy.cn 192.168.1.1
```

应该返回你优选出来的那个 IP，而不是 Cloudflare 原来的。

### 2. 看浏览器实际连的 IP

打开 `chrome://net-internals/#dns` 清一下缓存，再访问网站，
或者直接 `curl -v https://www.akkdiy.cn/ 2>&1 | grep 'Connected to'`。

### 3. 看是否真的变快了

```sh
curl -o /dev/null -w 'ttfb:%{time_starttransfer}s total:%{time_total}s ip:%{remote_ip}\n' \
  --max-time 20 https://www.akkdiy.cn/
```

对比优选前后的 `ttfb` 和 `remote_ip`。

---

## 注意事项（重要）

**1. 客户端开了 DoH/DoT 会绕过这个方案**

Chrome、Edge、Firefox 默认可能开着「安全 DNS」，那样 DNS 查询根本不走路由器，
劫持就失效了。要么在浏览器里关掉，要么在路由器上把 53 端口以外的 DoH 也拦掉。

**2. 只优选 IPv4**

脚本只处理 IPv4。如果域名有 AAAA 记录且客户端优先用 IPv6，
`dnsmasq` 的 `address=` 规则通常会让该域名的 AAAA 查询返回空，客户端回落到
IPv4，所以一般没问题。如果发现没生效，检查一下客户端是不是走了 IPv6。

**3. 清缓存**

改完之后手机/电脑有 DNS 缓存，浏览器还可能有 `alt-svc`（HTTP/3）缓存指向旧 IP。
等一两分钟，或者重启一下浏览器。

**4. 和代理插件冲突**

如果路由器上跑着 Passwall / OpenClash 并开启了 fake-ip 或 DNS 劫持，
它们的 DNS 优先级可能盖过 dnsmasq。这时候要么把本站域名加进代理插件的
直连名单，要么让代理插件不要接管 DNS。

**5. 弱路由器把线程调小**

`THREADS=100` 对 MT7621 这类 CPU 有点吃力，改成 `30`。测速本身会占满带宽
几分钟，建议放在凌晨跑（默认 04:00）。

---

## 工作原理（给想改代码的人）

```
cron 04:00
   └─ cf-optimizer run
        ├─ 检查/下载 /usr/bin/cfst
        ├─ cfst 测速 → /etc/cf-optimizer/result.csv
        ├─ awk 挑出延迟达标、速度最快的 IPv4
        ├─ curl --resolve 验证这个 IP 能否正常服务目标域名
        ├─ 验证通过 → 写 UCI
        │    uci del_list dhcp.@dnsmasq[0].address=/旧域名/旧IP
        │    uci add_list dhcp.@dnsmasq[0].address=/新域名/新IP
        │    uci commit dhcp && /etc/init.d/dnsmasq reload
        └─ 验证失败 → 什么都不改，保留上一次可用的配置
```

关键设计：

- **失败不覆盖**：测速失败、没有达标 IP、验证不通过，一律保持现状，
  不会把你原本能用的配置搞坏
- **先删后加**：每次应用前先撤掉上一轮写的规则，UCI 里不会越堆越多
- **原子状态**：当前生效的 `域名 IP` 记在 `/etc/cf-optimizer/current`，
  卸载和更新都靠它精确回滚
- **文件锁**：`/var/run/cf-optimizer.lock`，cron 和手动执行撞车时不会互相干扰

---

## 文件位置

| 路径 | 内容 |
|---|---|
| `/usr/bin/cf-optimizer` | 主程序 |
| `/usr/bin/cfst` | 测速核心（自动下载） |
| `/etc/cf-optimizer.conf` | 配置文件 |
| `/etc/cf-optimizer/current` | 当前生效的域名→IP 映射 |
| `/etc/cf-optimizer/result.csv` | 最近一次测速结果 |
| `/etc/cf-optimizer/ip.txt` | Cloudflare IP 段列表 |
| `/var/log/cf-optimizer.log` | 日志（超 800 行自动截断） |

---

## 卸载

```sh
cf-optimizer uninstall
```

会清掉 UCI 里的规则、cron 任务、程序和所有配置文件，不留痕迹。

如果只想临时停用而不卸载：

```sh
sed -i 's/^ENABLED=1/ENABLED=0/' /etc/cf-optimizer.conf
```

---

## 排错

**测不出任何 IP**

```sh
cf-optimizer test
tail -50 /var/log/cf-optimizer.log
```

常见原因：`MIN_SPEED` 定太高、`TEST_URL` 不可达、路由器到 CF 本身就不通。
先把 `MIN_SPEED=0`、`MAX_LATENCY=500` 放宽试一次。

**测出来了但网站打不开**

说明选中的 IP 虽然速度快，但不服务你这个域名。脚本里有 `curl --resolve`
验证会拦住这种情况；如果你的固件没装 `curl`，验证会被跳过，这时候手动验一下：

```sh
curl -v --resolve www.akkdiy.cn:443:104.18.2.3 https://www.akkdiy.cn/ 2>&1 | head -20
```

**改了没反应**

按上面「注意事项」第 1、3、4 条排查：DoH、缓存、代理插件抢 DNS。
