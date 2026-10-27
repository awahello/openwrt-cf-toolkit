# 踩坑记录（技术细节）

这份文档记录排查过程和技术细节，给需要深挖的人。结论性的内容在 [README](../README.md) 里。

测试环境：

```
设备    Radxa E20C（ARMv8 四核 1416MHz）
固件    bleachwrt plus 20250629 @ R25.5.25
LuCI    LuCI Master (git-25.168.74228-d985fad)
底层    OpenWrt 24.10.1 / aarch64_generic
内核    6.12.34
主题    ArgonTheme v1.8.4
```

---

## 一、ipk 封装格式

同一个 `.ipk` 后缀，实际有两种完全不同的封装。

**标准 ar 归档：**

```
00000000  21 3c 61 72 63 68 3e 0a  !<arch>.        ← 魔数
00000008  64 65 62 69 61 6e 2d 62  debian-b
00000010  69 6e 61 72 79 2f 20 20  inary/
...
```

**gzip 压缩的 tar：**

```
00000000  1f 8b 08 00 00 00 00 00  ........        ← gzip 魔数
```

解开来是 `./debian-binary` + `./data.tar.gz` + `./control.tar.gz`。

标准 OpenWrt 的 opkg 用 libarchive 自动探测，两种都认。但部分定制固件只接受其中一种。

**判断方法：**

```sh
hexdump -C 包名.ipk | head -1
```

- `21 3c 61 72 63 68` → ar
- `1f 8b` → gzip

**打 ar 包的注意事项：**

- 成员名要带 `/` 结尾（GNU 风格），长度不超过 16 字节
- 60 字节头：`name(16) + mtime(12) + uid(6) + gid(6) + mode(8) + size(10) + "`\n"(2)`
- 数据长度为奇数时补一个 `\n`

---

## 二、opkg 的三种拒绝

### 2.1 文件冲突

```
check_data_file_clashes: Package A wants to install file /path but that
file is already provided by package B
```

最常见的是语言包：

```
/usr/lib/lua/luci/i18n/cloudflarespeedtest.zh-cn.lmo
/etc/uci-defaults/luci-i18n-cloudflarespeedtest-zh-cn
```

如果主包内嵌了 `.lmo`，又同时装了官方的 `luci-i18n-*` 包，就会撞。

**解法**：主包不要内嵌 `.lmo`，交给官方语言包。

### 2.2 版本降级

```
opkg: downgrade refused
```

官方包 `1.21.0`，自打包 `1.21.0-0`，opkg 可能判定为降级。加个 release 号 `1.21.1-0` 就明确是升级。

### 2.3 依赖无法满足

```
Depends: libc, ucode
```

如果 `ucode` 这个包名在目标固件的 opkg 数据库里不存在（虽然实际装了），会直接拒绝安装。**跟能装上的包保持完全一致的 Depends 最安全。**

---

## 三、LuCI 菜单不显示的两种机制

### 3.1 `depends.acl` 过滤（ucode dispatcher）

`modules/luci-base/ucode/dispatcher.uc`：

```ucode
function check_acl_depends(require_groups, groups) {
	if (length(require_groups)) {
		for (let group in require_groups) {
			let read = ('read' in groups?.[group]);
			let write = ('write' in groups?.[group]);
			if (!read && !write)
				return null;          // ← ACL 组不存在
```

```ucode
function apply_tree_acls(node, acl) {
	...
	if (node?.depends?.acl) {
		switch (check_acl_depends(node.depends.acl, acl["access-group"])) {
		case null:  node.satisfied = false; break;   // ← 标记不满足
		case false: node.readonly = true;   break;
		}
	}
}
```

之后建树时：

```ucode
if (!child.satisfied)   // ← 直接跳过
	...
```

**注意**：这个 dispatcher 的缓存是**按文件列表哈希命名**的，新增 `menu.d` 文件会自动失效：

```ucode
let indexcache = "/tmp/luci-indexcache";
cachefile = sprintf('%s.%08x.json', indexcache, hash_filelist(files));
```

所以「删 `/tmp/luci-indexcache`」对这种情况是**无效**的，别在这上面浪费时间。

### 3.2 纯 Lua 版 LuCI 根本不读 `menu.d`

`luci-lua-runtime/luasrc/dispatcher.lua`：

```lua
function process_lua_controller(path)
	local base = "/usr/lib/lua/luci/controller/"
	local modname = "luci.controller." .. path:sub(#base+1, #path-4):gsub("/", ".")
	local mod = require(modname)
	assert(mod ~= true, "Invalid controller file found\n" ...)

	local idx = mod.index
	if type(idx) ~= "function" then
		return nil
	end

	local entries = {}
	__entries = entries
	__controller = modname

	setfenv(idx, setmetatable({}, { __index = luci.dispatcher }))()

	__entries = nil
	__controller = nil
	...
```

这段代码**只处理 `/usr/lib/lua/luci/controller/*.lua`**，完全没有 `menu.d` 相关逻辑。

判断方法：

```sh
grep -c 'menu.d' /usr/lib/lua/luci/dispatcher.lua
```

返回 0 就是纯 Lua 版，**改 JSON 永远无效**。

---

## 四、LuCI Lua 控制器的环境隔离（最容易踩）

还是上面那段：

```lua
setfenv(idx, setmetatable({}, { __index = luci.dispatcher }))()
```

三个关键点：

**1. 只对 `index` 这一个函数换环境**

`idx = mod.index`，`setfenv` 作用在 `idx` 上。同一个模块里的其它函数**不受影响**，它们的 `__index` 是 `_G`。

**2. `__index` 只指向 `luci.dispatcher`，没有 `_G` 兜底**

```lua
setmetatable({}, { __index = luci.dispatcher })
```

所以 `index()` 里能用的只有 `luci.dispatcher` 的成员：

```lua
entry()  cbi()  template()  call()  alias()  rewrite()  firstchild()
build_url()  menu_json()  error404()  error500()  is_authenticated()
```

`pcall`、`os`、`io`、`string`、`type`、`_`、`require` **全都是 nil**。

**3. helper 函数里反过来**

```lua
function index()
	pcall(build_menu)      -- ❌ pcall 是 nil
end

function build_menu()
	entry({...})           -- ❌ entry 是 nil（这里 __index 是 _G）
end
```

两个坑同时踩中，报错就是：

```
attempt to call a nil value
```

**正确写法**：所有 `entry()` 直接写在 `index()` 里。

```lua
module("luci.controller.cloudflarespeedtest", package.seeall)

function index()
	local page = entry({"admin", "services", "cloudflarespeedtest"},
		cbi("cloudflarespeedtest/general"), "Cloudflare Speed Test", 99)
	page.dependent = false

	entry({"admin", "services", "cloudflarespeedtest", "log"},
		template("cloudflarespeedtest/log"), "运行日志", 10).leaf = true
end
```

需要 `io`/`os` 时，在**模块顶层**（环境是 `_G`）取成 upvalue：

```lua
local io = io    -- 但见下一节，这个固件里 io 也是 nil
```

---

## 五、`io` 库被裁剪

在某些精简固件上，Lua 的 `io` 标准库被移除（安全考虑，防止模板随便写文件）。

表现：

```lua
local io = io
-- io == nil
```

在 `index()` 里用 `io.open(...)` 会报：

```
attempt to index upvalue 'io' (a nil value)
```

同理 `require "nixio.fs"` 也可能返回 nil。

**结论**：在 LuCI Lua 代码里，文件操作一律改用 `luci.sys.call()` 走 shell：

```lua
luci.sys.call("test -x /usr/bin/cdnspeedtest")   -- 返回 exit code
luci.sys.exec("tail -n 100 /var/log/xxx.log")    -- 返回输出
```

---

## 六、ucode RPC 插件加载链

插件是「JS 前端 + ucode RPC 后端」，后端文件在 `/usr/share/rpcd/ucode/*.uc`。

加载条件：

1. `rpcd` 必须装有 **`rpcd-mod-ucode`**（提供 `/usr/lib/rpcd/ucode.so`）
2. 插件里 `require` 的模块要存在（`fs`、`uci` 等，由 `ucode-mod-*` 提供）
3. `rpcd` 必须重启过

排查顺序：

```sh
# 1. ubus 里有没有对象
ubus list | grep -i cloudflarespeedtest

# 2. rpcd 有没有 ucode 支持
ls /usr/lib/rpcd/*ucode*

# 3. 插件能不能手动跑
ucode /usr/share/rpcd/ucode/cloudflarespeedtest.uc

# 4. 对照组：luci 对象在不在
ubus list | grep -qx luci
```

如果连 `luci` 对象都没有，说明整个 ucode 插件机制是关的——基本就是缺 `rpcd-mod-ucode`。

**注意 `ucode-mod-uci` 会拉 `libuci20250120`**，个别固件上可能影响老的 Lua 插件（如 `luci-app-ddns` 报 `attempt to index field '?' (a nil value)`）。本仓库的 Lua 界面不依赖它，可以回退。

---

## 七、cfst 下载与 `advanced` 开关

### 7.1 下载不走系统代理

主脚本里搜不到任何 `http_proxy` / `https_proxy`：

```sh
downloader="wget --no-check-certificate -T 20 -O"
downloader="curl -L -k --retry 2 --connect-timeout 20 -o"
```

裸调用。而 PassWall / OpenClash 默认只劫持 PREROUTING / FORWARD 链，**路由器自身发起的请求（OUTPUT 链）不走代理**。

验证：

```sh
curl -s -m 10 https://myip.ipip.net    # 看出口 IP 是国内还是国外
```

只能用脚本自带的镜像前缀：

```sh
raw_link="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.4/cfst_linux_$Arch.tar.gz"
github_mirror_prefix="$(get_github_mirror_prefix)"
link="${github_mirror_prefix}${raw_link}"
```

`get_github_mirror_prefix` 支持 `ghfast` / `ghproxy` / `custom`。

### 7.2 只下一次

```sh
if [ ! -e /usr/bin/cdnspeedtest ]; then
    download_core >>$LOG_FILE || { ... }
fi
```

装到 `/usr/bin/cdnspeedtest`，overlay 持久化，重启不丢，opkg 也不管（不在包清单里）。

### 7.3 `advanced` 控制所有测速参数

```sh
command="/usr/bin/cdnspeedtest -sl ${speed_limit} -url ${custom_url} -o ${result_tmp}"
command="${command} -f ${selected_ip_file}"

if [ "${advanced:-0}" -eq "1" ] ; then
    command="${command} -tl ${tl:-200} -tll ${tll:-40} -n ${threads:-200} -t ${t:-4} -dt ${dt:-10} -dn ${dn:-10}"
    if [ "${dd:-0}" -eq "1" ] ; then
        command="${command} -dd"
    fi
    ...
else
    # Default param: -tl 200 -tll 40 -n 200 -t 4 -dt 10
    command="${command} -dn 5"
fi
```

注意 `-sl ${speed_limit}` 在 `if` **外面**，所以 `speed_limit` 一直生效；但 `-n`（线程）、`-tl`、`-dt`、`-dn` 全在 `if` 里面。

**`advanced=0` 时 cfst 用内置默认的 200 线程**，四核 ARM 直接跑满。

### 7.4 `speed_limit` 设太高的陷阱

cfst 的 `-sl` 语义是「凑够 `-dn` 个速度高于此值的 IP 才停」。如果线路跑不到这个速度，它会**扫完整个 IP 段都不停**。

所以 `-sl 10` 配 `-n 200` 是最坏组合：200 线程、无限期扫描、CPU 100%。

---

## 八、Cloudflare DNS 与优选 IP 的死结

想通过改 A 记录让 CF 站点走优选 IP，会撞上两堵墙：

**橙云（Proxied）**

```sh
curl -sI https://www.example.com | grep -i 'server\|cf-ray'
# Server: cloudflare
# CF-Ray: a512277d6b13585e-LAX
```

有 `CF-Ray` 就是橙云。此时 DNS 应答由 CF 生成，**A 记录内容被完全忽略**。

**灰云（DNS only）**

A 记录指向 CF 自己的 IP 会触发：

```
Error 1000: DNS points to prohibited IP
```

CF 认为你在让它的边缘回源到它自己。

**能用的场景只有：**

1. 域名 NS **不在** Cloudflare（如 DNSPod），A 记录指向 CF IP
2. Cloudflare for SaaS 自定义主机名 + CNAME 到优选域名

**如果只想让自己访问变快**，用 [cf-optimizer](../cf-optimizer/) 的本地 DNS 劫持，橙云不用关，也不用改 CF 后台。

---

## 九、`workers.dev` 域名污染

顺带记录的另一个发现。

`xxx.workers.dev` 在国内被 DNS 污染，多个公共 DNS 返回的地址完全不相关：

```
223.5.5.5    → 199.59.149.203    (Twitter 段)
119.29.29.29 → 108.160.172.200   (Dropbox 段)
8.8.8.8      → 108.160.165.53    (Dropbox 段)
IPv6         → 2a03:2880:f11a:83:face:b00c:0:25de
                                  ↑ face:b00c 是 Facebook 的特征
```

直连 21 秒超时。**解法是给 Worker 绑自定义域名**，用自定义域访问就正常了（自定义域解析到正常的 CF 任播 IP）。
