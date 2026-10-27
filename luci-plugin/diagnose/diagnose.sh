#!/bin/sh
# ==============================================================================
# diagnose.sh —— luci-app-cloudflarespeedtest 装上了但看不到菜单，一键定位
#
# 用法：把本文件传到路由器，然后
#     sh /tmp/diagnose.sh
# ==============================================================================

PKG=luci-app-cloudflarespeedtest
MENU=/usr/share/luci/menu.d/$PKG.json
ACL=/usr/share/rpcd/acl.d/$PKG.json
VIEW=/www/luci-static/resources/view/cloudflarespeedtest/general.js

ok()   { printf '  [OK]   %s\n' "$*"; }
bad()  { printf '  [!!]   %s\n' "$*"; }
info() { printf '         %s\n' "$*"; }
head_() { printf '\n===== %s =====\n' "$*"; }

echo "================================================"
echo " LuCI 应用菜单诊断：$PKG"
echo "================================================"

head_ "0. 系统与 LuCI 版本"
info "$(cat /etc/openwrt_release 2>/dev/null | grep -E 'DISTRIB_(ID|RELEASE|DESCRIPTION)' | tr '\n' ' ')"
info "内核 $(uname -r) / 架构 $(uname -m)"
if [ -f /usr/lib/lua/luci/version.lua ]; then
	grep -hE 'major|minor|release|revision' /usr/lib/lua/luci/version.lua 2>/dev/null | tr -d '\t ' | tr '\n' ' '
	echo
fi
[ -f /etc/uci-defaults/luci-theme-argon ] && info "主题：argon"
if [ -x /usr/bin/ucode ]; then
	info "ucode 版本：$(ucode -v 2>/dev/null | head -n1)"
else
	bad "没有 ucode！新版 LuCI 必须依赖它"
fi

head_ "1. 文件是否真的落到磁盘"
if [ -f "$MENU" ]; then ok "菜单定义存在：$MENU ($(wc -c <"$MENU") 字节)"
else bad "菜单定义缺失：$MENU  ← 这就是看不到菜单的直接原因"; fi

if [ -f "$ACL" ]; then ok "ACL 文件存在：$ACL ($(wc -c <"$ACL") 字节)"
else bad "ACL 文件缺失：$ACL"; fi

if [ -f "$VIEW" ]; then ok "视图文件存在：$VIEW ($(wc -c <"$VIEW") 字节)"
else bad "视图文件缺失：$VIEW"; fi

[ -f /etc/config/cloudflarespeedtest ] \
	&& ok "uci 配置存在：/etc/config/cloudflarespeedtest" \
	|| bad "uci 配置缺失：/etc/config/cloudflarespeedtest  ← 菜单的 depends.uci 会不满足"

# 那些 0 字节的 .js.o 是构建垃圾
_junk=$(find /www/luci-static/resources/view/cloudflarespeedtest -name '*.js.o' -size 0 2>/dev/null)
if [ -n "$_junk" ]; then
	bad "发现 0 字节构建垃圾（建议删掉）："
	echo "$_junk" | while read -r f; do info "$f"; done
fi

head_ "2. JSON 语法是否合法"
for f in "$MENU" "$ACL"; do
	[ -f "$f" ] || continue
	if command -v jsonfilter >/dev/null 2>&1; then
		if jsonfilter -i "$f" -e '@' >/dev/null 2>&1; then ok "$(basename "$f") 语法合法"
		else bad "$(basename "$f") JSON 语法错误！"; fi
	else
		info "没有 jsonfilter，跳过 $(basename "$f")"
	fi
done

head_ "3. uci 配置能否读取"
if command -v uci >/dev/null 2>&1; then
	if uci -q show cloudflarespeedtest >/dev/null 2>&1; then
		ok "uci show cloudflarespeedtest 正常"
		info "$(uci -q get cloudflarespeedtest.global.enabled >/dev/null 2>&1 && echo 'global 段可读' || echo 'global 段读不到')"
	else
		bad "uci 读不到 cloudflarespeedtest，菜单会被 depends.uci 挡掉"
	fi
fi

head_ "4. rpcd 与 ACL 是否生效"
if ubus list 2>/dev/null | grep -qx 'luci'; then ok "ubus 有 luci 对象"
else bad "ubus 没有 luci 对象，LuCI 后端没起来"; fi

if ubus list 2>/dev/null | grep -qx 'cloudflarespeedtest'; then
	ok "ubus 已注册 cloudflarespeedtest（ucode RPC 插件加载成功）"
	info "$(ubus -v list cloudflarespeedtest 2>/dev/null | head -n3 | tr '\n' ' ')"
else
	bad "ubus 没有 cloudflarespeedtest，说明 /usr/share/rpcd/ucode/cloudflarespeedtest.uc 没加载"
	info "文件是否存在：$([ -f /usr/share/rpcd/ucode/cloudflarespeedtest.uc ] && echo 是 || echo 否)"
	info "rpcd 状态：$([ -x /etc/init.d/rpcd ] && echo 有 init.d/rpcd || echo 无)"
fi

head_ "5. 菜单树里到底有没有这个节点"
if ubus call luci getMenu >/tmp/_menu.json 2>/dev/null; then
	if grep -q cloudflarespeedtest /tmp/_menu.json; then
		ok "getMenu 里有 cloudflarespeedtest 节点"
		info "$(grep -o '"cloudflarespeedtest"[^}]*' /tmp/_menu.json | head -n1)"
		info "→ 菜单是存在的，问题在浏览器缓存或主题渲染，先 Ctrl+F5 强刷"
	else
		bad "getMenu 里没有 cloudflarespeedtest 节点"
		info "→ 说明被 depends 条件挡掉了（acl 或 uci 不满足），或菜单缓存未刷新"
	fi
else
	bad "ubus call luci getMenu 失败，LuCI 后端异常"
fi

head_ "6. 缓存文件"
ls -l /tmp/luci-indexcache* 2>/dev/null && info "↑ 这些缓存要删掉" || info "没有 luci-indexcache 缓存文件（新版 LuCI 可能不落盘）"
ls -l /tmp/luci-* 2>/dev/null | head -n5

head_ "7. opkg 认为装了哪些文件"
if command -v opkg >/dev/null 2>&1; then
	opkg files $PKG 2>/dev/null | head -n 25
else
	info "没有 opkg"
fi

head_ "8. 相关日志"
logread 2>/dev/null | grep -iE 'luci|rpcd|cloudflare' | tail -n 15

head_ "结论"
cat <<'TIP'

如果第 1 项全 OK、第 5 项说"没有节点"，按顺序试：

  1) rm -rf /tmp/luci-indexcache*; /etc/init.d/rpcd restart; /etc/init.d/uhttpd restart
     然后浏览器 Ctrl+F5 强刷（或换无痕窗口）

  2) 还不行就看 ACL 有没有被 rpcd 吃到：
     ubus call session access '{"ubus":"luci","method":"getMenu"}'

  3) 确认菜单依赖的 uci 配置真的存在：
     uci show cloudflarespeedtest | head

  4) 实在不行，手动验证后端是否活着：
     ubus call cloudflarespeedtest status

TIP
