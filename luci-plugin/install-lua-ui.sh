#!/bin/sh
# ==============================================================================
# install-lua-ui.sh  v2 —— 给纯 Lua 版 LuCI 补一个 CBI 界面
#
# v1 的问题：控制器里用了 require "nixio.fs"，在这个固件上返回 nil，
#           导致 index() 抛错 -> dispatcher.createtree 整体失败 -> 整个 LuCI 打不开。
#
# v2 的改法：
#   - 控制器里彻底不用 require、不用 nixio，只用 os.execute + luci.http/luci.dispatcher 全局
#   - index() 用 pcall 包住，即使出错也只丢菜单，不会拖垮整个 LuCI
#   - 模板里改用 luci.sys.call() 判断状态，不再依赖 nixio.fs
#
# 用法： sh install-lua-ui.sh
# ==============================================================================

CTRL=/usr/lib/lua/luci/controller/cloudflarespeedtest.lua
MODELD=/usr/lib/lua/luci/model/cbi/cloudflarespeedtest
VIEWD=/usr/lib/lua/luci/view/cloudflarespeedtest
MODEL=$MODELD/general.lua

echo "================================================"
echo " 安装 Lua CBI 界面 (v2)"
echo "================================================"

# ---------------------------------------------------------------- 前置
echo
echo "[0] 清理 v1 残留"
rm -f "$CTRL"
echo "    [OK] 已删除旧控制器（先保证 LuCI 能打开）"

if [ ! -f /usr/lib/lua/luci/dispatcher.lua ]; then
	echo "    !! 没有 Lua dispatcher，脚本不适用"
	exit 1
fi
if [ ! -f /etc/config/cloudflarespeedtest ]; then
	echo "    !! 没有 /etc/config/cloudflarespeedtest，先装主包"
	exit 1
fi
if [ ! -x /usr/bin/cloudflarespeedtest/cloudflarespeedtest.sh ]; then
	echo "    !! 后端脚本不存在"
	exit 1
fi
echo "    [OK] 环境检查通过"

mkdir -p /usr/lib/lua/luci/controller "$MODELD" "$VIEWD"

# ---------------------------------------------------------------- 控制器
echo
echo "[1] 写控制器（无 require / 无 nixio / pcall 保护）"
cat >"$CTRL" <<'LUA_CTRL'
module("luci.controller.cloudflarespeedtest", package.seeall)

function index()
	-- 用 pcall 包住：即使建菜单出错，也只是这个插件不显示，
	-- 不会让 dispatcher.createtree 整体失败、把整个 LuCI 拖垮
	pcall(build_menu)
end

function build_menu()
	entry({"admin", "services", "cloudflarespeedtest"},
		cbi("cloudflarespeedtest/general"),
		_("Cloudflare Speed Test"), 99).dependent = false

	entry({"admin", "services", "cloudflarespeedtest", "log"},
		template("cloudflarespeedtest/log"),
		_("运行日志"), 10).leaf = true

	entry({"admin", "services", "cloudflarespeedtest", "run"},
		call("action_run")).leaf = true

	entry({"admin", "services", "cloudflarespeedtest", "stop"},
		call("action_stop")).leaf = true
end

function action_run()
	os.execute("/usr/bin/cloudflarespeedtest/cloudflarespeedtest.sh start >/dev/null 2>&1 &")
	luci.http.redirect(luci.dispatcher.build_url(
		"admin", "services", "cloudflarespeedtest", "log"))
end

function action_stop()
	os.execute("pgrep cdnspeedtest | xargs kill -9 >/dev/null 2>&1")
	luci.http.redirect(luci.dispatcher.build_url(
		"admin", "services", "cloudflarespeedtest", "log"))
end
LUA_CTRL
echo "    [OK] 已写入"

# ---------------------------------------------------------------- CBI 模型
echo
echo "[2] 写 CBI 表单"
cat >"$MODEL" <<'LUA_MODEL'
local m, s, o

m = Map("cloudflarespeedtest",
	translate("Cloudflare Speed Test"),
	translate("定时测速并把最快的 Cloudflare IP 应用到代理或 DNS 插件。"))

m:section(SimpleSection).template = "cloudflarespeedtest/status"

-- ---------------------------------------------------------------- 基础
s = m:section(NamedSection, "global", "global", translate("基础设置"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"))
o.rmempty = false
o.default = "0"
o.description = translate("关闭后定时任务不会执行")

o = s:option(ListValue, "hour", translate("执行间隔"))
o:value("1",  translate("每小时"))
o:value("2",  translate("每 2 小时"))
o:value("4",  translate("每 4 小时"))
o:value("6",  translate("每 6 小时"))
o:value("12", translate("每 12 小时"))
o:value("24", translate("每天"))
o.default = "24"

o = s:option(Flag, "ipv6_enabled", translate("启用 IPv6 测速"))
o.rmempty = false
o.default = "0"

o = s:option(ListValue, "ip_source", translate("IP 来源"))
o:value("builtin_ipv4", translate("内置 IPv4 列表"))
o:value("builtin_ipv6", translate("内置 IPv6 列表"))
o:value("custom",       translate("自定义文件"))
o.default = "builtin_ipv4"

o = s:option(Value, "custom_ip_file", translate("自定义 IP 文件"))
o:depends("ip_source", "custom")
o.placeholder = "/etc/ip.txt"

o = s:option(ListValue, "github_proxy", translate("GitHub 代理"))
o:value("direct",  translate("不使用"))
o:value("ghfast",  "ghfast.top")
o:value("ghproxy", "ghproxy.cc")
o:value("custom",  translate("自定义"))
o.default = "direct"
o.description = translate("首次运行要从 GitHub 下载测速核心，国内建议选前两个")

o = s:option(Value, "github_proxy_custom", translate("自定义代理前缀"))
o:depends("github_proxy", "custom")
o.placeholder = "https://example.com/"

-- ---------------------------------------------------------------- 测速参数
o = s:option(Value, "threads", translate("测速线程"))
o.datatype = "uinteger"
o.default = "200"
o.description = translate("路由器性能弱就调到 50 或 30")

o = s:option(Value, "tl", translate("平均延迟上限 (ms)"))
o.datatype = "uinteger"
o.default = "200"

o = s:option(Value, "tll", translate("平均延迟下限 (ms)"))
o.datatype = "uinteger"
o.default = "40"

o = s:option(Value, "speed_limit", translate("下载速度下限 (MB/s)"))
o.datatype = "float"
o.default = "10"

o = s:option(Flag, "httping", translate("使用 HTTPing 模式"))
o.rmempty = false
o.default = "0"

o = s:option(Value, "cfcolo", translate("指定机房代码"))
o.placeholder = "HKG,NRT,LAX"
o.description = translate("仅 HTTPing 模式有效，留空为不限")

-- ---------------------------------------------------------------- 第三方
s = m:section(NamedSection, "servers", "servers", translate("应用到哪些插件"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "ssr_enabled", translate("ShadowSocksR Plus+"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "passwall_enabled", translate("PassWall"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "passwall2_enabled", translate("PassWall2"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "bypass_enabled", translate("Bypass"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "vssr_enabled", translate("Vssr"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "DNS_enabled", translate("AliDNS 域名解析"))
o.rmempty = false
o.default = "0"

o = s:option(Value, "AliDNS_ip_count", translate("AliDNS 记录条数"))
o.datatype = "uinteger"
o.default = "1"
o:depends("DNS_enabled", "1")

o = s:option(Flag, "AstraDNS_enabled", translate("AstraDNS"))
o.rmempty = false
o.default = "0"

return m
LUA_MODEL
echo "    [OK] 已写入"

# ---------------------------------------------------------------- 视图
echo
echo "[3] 写状态页与日志页"
cat >"$VIEWD/status.htm" <<'HTM_STATUS'
<%
	local sys = luci.sys
	local running   = (sys.call("pgrep cdnspeedtest >/dev/null 2>&1") == 0)
	local core_ok   = (sys.call("test -x /usr/bin/cdnspeedtest") == 0)
	local has_res   = (sys.call("test -s /tmp/CloudflareSpeedTest/result.csv") == 0)
%>
<fieldset class="cbi-section">
	<legend><%:运行状态%></legend>

	<div class="cbi-value">
		<label class="cbi-value-title"><%:当前状态%></label>
		<div class="cbi-value-field">
			<% if running then %>
				<em style="color:#3b6d11;font-style:normal">测速进行中…</em>
			<% else %>
				空闲
			<% end %>
		</div>
	</div>

	<div class="cbi-value">
		<label class="cbi-value-title"><%:测速核心%></label>
		<div class="cbi-value-field">
			<% if core_ok then %>
				已就绪（/usr/bin/cdnspeedtest）
			<% else %>
				未下载，首次运行会自动下载
			<% end %>
		</div>
	</div>

	<div class="cbi-value">
		<label class="cbi-value-title"><%:最近结果%></label>
		<div class="cbi-value-field">
			<% if has_res then %>
				<textarea readonly rows="6" style="width:100%;font-family:monospace;font-size:12px"><%=sys.exec("head -n 6 /tmp/CloudflareSpeedTest/result.csv 2>/dev/null")%></textarea>
			<% else %>
				还没有测速结果
			<% end %>
		</div>
	</div>

	<div class="cbi-value">
		<label class="cbi-value-title"><%:操作%></label>
		<div class="cbi-value-field">
			<a class="cbi-button cbi-button-apply"
			   href="<%=luci.dispatcher.build_url("admin","services","cloudflarespeedtest","run")%>">立即测速</a>
			<a class="cbi-button cbi-button-reset"
			   href="<%=luci.dispatcher.build_url("admin","services","cloudflarespeedtest","stop")%>">停止</a>
			<a class="cbi-button"
			   href="<%=luci.dispatcher.build_url("admin","services","cloudflarespeedtest","log")%>">查看日志</a>
		</div>
	</div>
</fieldset>
HTM_STATUS

cat >"$VIEWD/log.htm" <<'HTM_LOG'
<%+header%>

<h2 name="content"><%:运行日志%></h2>

<div class="cbi-section">
	<p>
		<a class="cbi-button"
		   href="<%=luci.dispatcher.build_url("admin","services","cloudflarespeedtest")%>">返回设置</a>
		<a class="cbi-button cbi-button-apply"
		   href="<%=luci.dispatcher.build_url("admin","services","cloudflarespeedtest","run")%>">立即测速</a>
		<a class="cbi-button cbi-button-reset"
		   href="<%=luci.dispatcher.build_url("admin","services","cloudflarespeedtest","stop")%>">停止</a>
	</p>
	<textarea readonly style="width:100%;height:60vh;font-family:monospace;font-size:12px"><%=luci.sys.exec("tail -n 500 /tmp/cloudflarespeedtest.log 2>/dev/null")%></textarea>
</div>

<%+footer%>
HTM_LOG
echo "    [OK] 已写入"

# ---------------------------------------------------------------- 清缓存
echo
echo "[4] 清缓存"
rm -f /tmp/luci-indexcache 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null
echo "    [OK] 已清理"

echo
echo "================================================"
echo " 完成。刷新浏览器（Ctrl+Shift+R），"
echo " 菜单：服务 → Cloudflare Speed Test"
echo ""
echo " 如果 LuCI 还是打不开，直接删掉控制器即可恢复："
echo "   rm -f /usr/lib/lua/luci/controller/cloudflarespeedtest.lua"
echo "   rm -f /tmp/luci-indexcache"
echo "================================================"
