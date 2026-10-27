#!/bin/sh
# ==============================================================================
# fix-controller.sh  v3 —— 最终版
#
# 历次踩坑：
#   v1  require "nixio.fs"        -> 返回 nil，index() 抛错，整个 LuCI 崩
#   v2  把逻辑挪进 build_menu()    -> index() 被 setfenv 过，helper 里 entry 是 nil
#       + 用 pcall 包             -> pcall 在 index() 里也是 nil
#   v3  local io = io            -> 这个固件把 Lua 的 io 库摘掉了，io 是 nil
#
# 结论：index() 里只能出现 luci.dispatcher 提供的成员（entry/cbi/template/call）。
#       不碰 io / os / pcall / _ / string / type 任何全局。
#       命令执行放到 action_* 里，用 luci.sys（LuCI 自己的模块，保证可用）。
#
# 用法： sh fix-controller.sh
# ==============================================================================

CTRL=/usr/lib/lua/luci/controller/cloudflarespeedtest.lua

echo "================================================"
echo " 重写控制器 v3（零全局依赖）"
echo "================================================"

if [ ! -f /etc/config/cloudflarespeedtest ]; then
	echo "!! 没有 uci 配置，先装主包"
	exit 1
fi
if [ ! -f /usr/lib/lua/luci/model/cbi/cloudflarespeedtest/general.lua ]; then
	echo "!! CBI 表单不存在，先跑 install-lua-ui.sh"
	exit 1
fi

mkdir -p /usr/lib/lua/luci/controller

cat >"$CTRL" <<'LUA_CTRL'
module("luci.controller.cloudflarespeedtest", package.seeall)

-- index() 会被 dispatcher 用 setfenv 换环境，__index 只指向 luci.dispatcher，
-- 没有 _G 兜底。所以这里只允许出现 entry / cbi / template / call，
-- 不要用 io / os / pcall / string / type 这些全局，否则全是 nil。

function index()
	local page = entry({"admin", "services", "cloudflarespeedtest"},
		cbi("cloudflarespeedtest/general"), "Cloudflare Speed Test", 99)
	page.dependent = false

	entry({"admin", "services", "cloudflarespeedtest", "log"},
		template("cloudflarespeedtest/log"), "运行日志", 10).leaf = true

	entry({"admin", "services", "cloudflarespeedtest", "run"},
		call("action_run")).leaf = true

	entry({"admin", "services", "cloudflarespeedtest", "stop"},
		call("action_stop")).leaf = true
end

-- 下面两个不会被 setfenv，环境是模块表（__index = _G），可以用 luci。
-- 但为保险，仍然不用 os / io，统一走 luci.sys。

function action_run()
	if luci and luci.sys then
		luci.sys.call("/usr/bin/cloudflarespeedtest/cloudflarespeedtest.sh start >/dev/null 2>&1 &")
	end
	if luci and luci.http and luci.dispatcher then
		luci.http.redirect(luci.dispatcher.build_url(
			"admin", "services", "cloudflarespeedtest", "log"))
	end
end

function action_stop()
	if luci and luci.sys then
		luci.sys.call("pgrep cdnspeedtest | xargs kill -9 >/dev/null 2>&1")
	end
	if luci and luci.http and luci.dispatcher then
		luci.http.redirect(luci.dispatcher.build_url(
			"admin", "services", "cloudflarespeedtest", "log"))
	end
end
LUA_CTRL

echo "[OK] 已写入 $CTRL"

echo "[..] 清缓存"
rm -f /tmp/luci-indexcache /tmp/cf-menu-error.txt /tmp/cf-menu-ok.txt 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null

echo
echo "================================================"
echo " 刷新浏览器（Ctrl+Shift+R）"
echo " 菜单：服务 → Cloudflare Speed Test（列表最后，往下滚）"
echo ""
echo " 这次控制器里没有任何 io / os / pcall 了，"
echo " 只剩 entry / cbi / template / call 四个 dispatcher 成员。"
echo ""
echo " 万一还不行，回滚："
echo "   rm -f /usr/lib/lua/luci/controller/cloudflarespeedtest.lua; rm -f /tmp/luci-indexcache"
echo "================================================"
