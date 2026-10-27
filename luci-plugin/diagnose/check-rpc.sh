#!/bin/sh
# ==============================================================================
# check-rpc.sh —— 查为什么 ubus 里没有 cloudflarespeedtest 对象
#
# 用法： sh check-rpc.sh
# ==============================================================================

UCFILE=/usr/share/rpcd/ucode/cloudflarespeedtest.uc

echo "================= RPC 插件加载诊断 ================="

echo
echo "[1] ucode 是否存在"
if command -v ucode >/dev/null 2>&1; then
	echo "    $(ucode -v 2>&1 | head -n1)"
else
	echo "    !! 没有 ucode 命令，新版 LuCI 必需"
fi

echo
echo "[2] rpcd 相关已安装包"
opkg list-installed 2>/dev/null | grep -i rpcd | sed 's/^/    /'
[ -z "$(opkg list-installed 2>/dev/null | grep -i rpcd)" ] && echo "    !! 一个 rpcd 包都没有？"

echo
echo "[3] rpcd 的 ucode 支持模块（关键）"
if ls /usr/lib/rpcd/*ucode* >/dev/null 2>&1; then
	ls -l /usr/lib/rpcd/*ucode* | sed 's/^/    /'
	echo "    -> 有 ucode 模块，rpcd 支持 ucode 插件"
else
	echo "    !! /usr/lib/rpcd/ 下没有 ucode 模块"
	ls /usr/lib/rpcd/ 2>/dev/null | sed 's/^/       /'
	echo "    -> 很可能缺 rpcd-mod-ucode，装它："
	echo "       opkg update && opkg install rpcd-mod-ucode"
fi

echo
echo "[4] ucode 插件目录内容"
if [ -d /usr/share/rpcd/ucode ]; then
	ls -l /usr/share/rpcd/ucode/ | sed 's/^/    /'
else
	echo "    !! /usr/share/rpcd/ucode 目录不存在"
fi

echo
echo "[5] 本插件的文件"
if [ -f "$UCFILE" ]; then
	echo "    存在：$UCFILE  ($(wc -c <"$UCFILE") 字节)"
	echo "    手动执行一遍，看有没有报错："
	ucode "$UCFILE" 2>&1 | sed 's/^/       /'
	echo "    exit=$?"
else
	echo "    !! 文件不存在：$UCFILE"
	echo "    -> 包没把这个文件解出来，重装包："
	echo "       opkg install --force-reinstall /tmp/luci-app-cloudflarespeedtest_*.ipk"
fi

echo
echo "[6] 现有 ubus 对象里有没有对照组"
if ubus list 2>/dev/null | grep -qx luci; then
	echo "    [OK] 有 luci 对象 -> rpcd 的 ucode 插件机制本身是工作的"
	echo "         （所以问题只出在 cloudflarespeedtest.uc 这个文件上）"
else
	echo "    [!!] 连 luci 对象都没有 -> rpcd 根本没加载任何 ucode 插件"
	echo "         （缺 rpcd-mod-ucode，或 rpcd 版本太老）"
fi

echo
echo "[7] 其他 ucode 插件注册出来的对象（对照）"
ubus list 2>/dev/null | sort | sed 's/^/    /' | head -40

echo
echo "[8] 有没有 cloudflarespeedtest"
if ubus list 2>/dev/null | grep -i cloudflare; then
	echo "    [OK] 已注册"
else
	echo "    [!!] 没有"
fi

echo
echo "[9] rpcd 日志"
logread 2>/dev/null | grep -i rpcd | tail -20 | sed 's/^/    /'
[ -z "$(logread 2>/dev/null | grep -i rpcd | tail -5)" ] && echo "    （无 rpcd 日志）"

echo
echo "=================================================="
echo " 把上面整段输出发出来即可定位"
echo "=================================================="
