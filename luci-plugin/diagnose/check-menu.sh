#!/bin/sh
# ==============================================================================
# check-menu.sh —— 查菜单为什么没出现
#
# 核心思路：对比「能显示的应用」和「不能显示的我们」，看菜单来源是否同一套机制。
# 用法： sh check-menu.sh
# ==============================================================================

M=/usr/share/luci/menu.d/luci-app-cloudflarespeedtest.json

echo "=============== 菜单来源诊断 ==============="

echo
echo "[1] 我们的菜单文件现在长什么样"
if [ -f "$M" ]; then
	ls -l "$M" | sed 's/^/    /'
	echo "    --- 内容 ---"
	sed 's/^/    /' "$M"
else
	echo "    !! 文件不存在"
fi

echo
echo "[2] 还有 depends 吗"
if grep -q '"depends"' "$M" 2>/dev/null; then
	echo "    !! 还有 depends —— 补丁没生效"
else
	echo "    [OK] 没有 depends —— 补丁生效了"
fi

echo
echo "[3] menu.d 目录总共几个文件"
if [ -d /usr/share/luci/menu.d ]; then
	echo "    数量: $(ls /usr/share/luci/menu.d/*.json 2>/dev/null | wc -l)"
	ls /usr/share/luci/menu.d/*.json 2>/dev/null | sed 's/^/    /' | head -30
else
	echo "    !! /usr/share/luci/menu.d 目录不存在"
fi

echo
echo "[4] 对比：能显示的应用走的是哪条路"
for a in passwall openclash mwan3 upnp; do
	f=$(ls /usr/share/luci/menu.d/*"$a"* 2>/dev/null | head -n1)
	l=$(ls /usr/lib/lua/luci/controller/*"$a"* 2>/dev/null | head -n1)
	if [ -n "$f" ]; then
		echo "    $a : menu.d -> $f"
	elif [ -n "$l" ]; then
		echo "    $a : Lua 控制器 -> $l"
	else
		echo "    $a : 两种都没找到"
	fi
done

echo
echo "[5] LuCI 是哪一代"
if [ -f /usr/lib/lua/luci/dispatcher.lua ]; then
	echo "    [Lua] 有 /usr/lib/lua/luci/dispatcher.lua"
	echo "    Lua 控制器数量: $(ls /usr/lib/lua/luci/controller/*.lua 2>/dev/null | wc -l)"
else
	echo "    没有 Lua dispatcher"
fi
if [ -d /usr/share/ucode/luci ]; then
	echo "    [ucode] 有 /usr/share/ucode/luci 目录"
	ls /usr/share/ucode/luci/ 2>/dev/null | sed 's/^/       /' | head
fi

echo
echo "[6] Lua dispatcher 里有没有 menu.d 的加载代码"
if [ -f /usr/lib/lua/luci/dispatcher.lua ]; then
	if grep -q 'menu.d' /usr/lib/lua/luci/dispatcher.lua 2>/dev/null; then
		echo "    [OK] dispatcher.lua 里提到 menu.d"
		grep -n 'menu.d' /usr/lib/lua/luci/dispatcher.lua 2>/dev/null | head -5 | sed 's/^/       /'
	else
		echo "    !! dispatcher.lua 里完全没有 menu.d"
		echo "    -> 说明这版 LuCI 的菜单只从 Lua 控制器来，JSON 根本没被读"
	fi
fi

echo
echo "[7] 缓存"
ls -l /tmp/luci-indexcache* 2>/dev/null | sed 's/^/    /' || echo "    没有 luci-indexcache 文件"

echo
echo "[8] ubus 对象"
ubus list 2>/dev/null | grep -iE 'cloudflare|^luci$' | sed 's/^/    /' || echo "    没有相关对象"

echo
echo "============================================"
echo " 把整段输出发出来"
echo "============================================"
