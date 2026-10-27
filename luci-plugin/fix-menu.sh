#!/bin/sh
# ==============================================================================
# fix-menu.sh —— 修复「No page is registered at '/admin/services/cloudflarespeedtest'」
#
# 原理：
#   菜单节点带了 depends.acl，而 LuCI 的 dispatcher.uc 里
#   check_acl_depends() 一旦返回 null（ACL 组不在会话权限里），
#   就把节点标成 satisfied=false 直接从菜单树删掉，
#   于是直接访问 URL 就报 "No page is registered"。
#
#   这个脚本做两件事：
#     1. 确认 ACL 文件在位并重启 rpcd，让它重新加载
#     2. 去掉菜单里的 depends.acl（单用户路由器上这个门禁没意义）
#
# 用法： sh /tmp/fix-menu.sh
# ==============================================================================

MENU=/usr/share/luci/menu.d/luci-app-cloudflarespeedtest.json
ACL=/usr/share/rpcd/acl.d/luci-app-cloudflarespeedtest.json
PKG=luci-app-cloudflarespeedtest

ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m[!!]\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
step() { printf '\n--- %s ---\n' "$*"; }

echo "================================================"
echo " 修复 LuCI 菜单：$PKG"
echo "================================================"

# ---------------------------------------------------------------- 前置检查
step "1. 检查文件是否真的装上了"

if [ ! -f "$MENU" ]; then
	bad "菜单文件不存在：$MENU"
	info "说明这个包根本没装成功，或者装到了别的地方。"
	info "先确认一下："
	info "  opkg list-installed | grep cloudflare"
	info "  ls -l /usr/share/luci/menu.d/ | grep -i cloud"
	exit 1
fi
ok "菜单文件存在：$MENU"

if [ -f "$ACL" ]; then
	ok "ACL 文件存在：$ACL"
else
	bad "ACL 文件缺失，正在补一份"
	mkdir -p /usr/share/rpcd/acl.d
	cat >"$ACL" <<'EOF'
{
	"luci-app-cloudflarespeedtest": {
		"description": "Grant UCI access for luci-app-cloudflarespeedtest",
		"read": {
			"ubus": {
				"cloudflarespeedtest": [ "status", "get_log", "get_history", "get_best_result", "list_nodes" ]
			},
			"uci": [ "cloudflarespeedtest" ]
		},
		"write": {
			"ubus": {
				"cloudflarespeedtest": [ "start", "stop" ]
			},
			"uci": [ "cloudflarespeedtest" ]
		}
	}
}
EOF
	ok "已补写 ACL"
fi

if [ ! -f /etc/config/cloudflarespeedtest ]; then
	bad "uci 配置缺失，菜单的 depends.uci 也会不满足"
	info "包里的 /etc/config/cloudflarespeedtest 应该在的，可能安装时被跳过了"
fi

# ---------------------------------------------------------------- 打补丁
step "2. 去掉菜单里的 depends.acl"

if grep -q '"acl"' "$MENU" 2>/dev/null; then
	cp "$MENU" "$MENU.bak" 2>/dev/null
	cat >"$MENU" <<'EOF'
{
	"admin/services/cloudflarespeedtest": {
		"title": "Cloudflare Speed Test",
		"order": 99,
		"action": {
			"type": "firstchild"
		}
	},

	"admin/services/cloudflarespeedtest/general": {
		"title": "Plugin Settings",
		"order": 1,
		"action": {
			"type": "view",
			"path": "cloudflarespeedtest/general"
		}
	},

	"admin/services/cloudflarespeedtest/third-party": {
		"title": "Third Party Settings",
		"order": 2,
		"action": {
			"type": "view",
			"path": "cloudflarespeedtest/third-party"
		}
	},

	"admin/services/cloudflarespeedtest/logread": {
		"title": "Logs",
		"order": 3,
		"action": {
			"type": "view",
			"path": "cloudflarespeedtest/logread"
		}
	}
}
EOF
	ok "已重写菜单文件（原文件备份为 $MENU.bak）"
else
	ok "菜单里已经没有 acl 依赖了，跳过"
fi

# ---------------------------------------------------------------- 刷新
step "3. 重启 rpcd / uhttpd 并清缓存"

rm -rf /tmp/luci-indexcache* 2>/dev/null
ok "已清理 /tmp/luci-indexcache*"

if [ -x /etc/init.d/rpcd ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1
	sleep 1
	ok "rpcd 已重启"
else
	bad "没有 /etc/init.d/rpcd"
fi

if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd restart >/dev/null 2>&1
	ok "uhttpd 已重启"
fi

# ---------------------------------------------------------------- 验证
step "4. 验证后端是否可用"

if ubus list 2>/dev/null | grep -qx cloudflarespeedtest; then
	ok "ubus 已注册 cloudflarespeedtest"
	ubus -v list cloudflarespeedtest 2>/dev/null | head -n 5 | sed 's/^/       /'
else
	bad "ubus 没有 cloudflarespeedtest 对象"
	info "ucode RPC 插件没加载，页面能开但功能会报错。检查："
	info "  ls -l /usr/share/rpcd/ucode/cloudflarespeedtest.uc"
	info "  logread | grep -i rpcd | tail -20"
fi

step "5. rpcd 日志里的 ACL 报错"
logread 2>/dev/null | grep -iE 'rpcd|acl' | tail -n 10

echo ""
echo "================================================"
echo " 完成。现在："
echo "   1. 浏览器 Ctrl+Shift+R 强制刷新（或开无痕窗口）"
echo "   2. 访问 服务 → Cloudflare Speed Test"
echo ""
echo " 如果菜单出来了但页面报「权限不足」："
echo "   ACL 还没被 rpcd 吃进去，执行 /etc/init.d/rpcd restart 后重启浏览器"
echo ""
echo " 如果还是没有菜单："
echo "   sh /tmp/diagnose.sh   把输出发出来"
echo "================================================"
