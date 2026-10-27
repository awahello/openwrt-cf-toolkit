#!/bin/sh
# ==============================================================================
# fix-advanced.sh —— 补上「高级模式」和「只测延迟」两个开关
#
# 问题：主脚本里只有 advanced=1 时才把 -n/-t/-tl 这些参数传给 cfst，
#       否则固定用 200 线程。而 CBI 表单里没有 advanced 开关，
#       导致「测速线程」等设置全部无效，弱路由器直接 CPU 100%。
#
# 用法： sh fix-advanced.sh
# ==============================================================================

MODEL=/usr/lib/lua/luci/model/cbi/cloudflarespeedtest/general.lua

echo "================================================"
echo " 补「高级模式」开关"
echo "================================================"

if [ ! -f "$MODEL" ]; then
	echo "!! CBI 表单不存在：$MODEL"
	exit 1
fi

if grep -q '"advanced"' "$MODEL" 2>/dev/null; then
	echo "[跳过] 已经有 advanced 开关了"
else
	cp "$MODEL" "$MODEL.bak2" 2>/dev/null
	echo "[..] 已备份 $MODEL.bak2"

	BLOCK=/tmp/_adv.$$
	cat >"$BLOCK" <<'LUA'
o = s:option(Flag, "advanced", translate("启用高级参数"))
o.rmempty = false
o.default = "0"
o.description = translate("不打开的话，下面这些测速参数全部不生效，固定用 cfst 默认的 200 线程")

o = s:option(Flag, "dd", translate("只测延迟（不测下载速度）"))
o.rmempty = false
o.default = "0"
o:depends("advanced", "1")
o.description = translate("弱路由器建议打开，CPU 和带宽占用都低很多，但结果只有延迟没有速度")

LUA

	awk -v bf="$BLOCK" '
		/^o = s:option\(Value, "threads"/ && !done {
			while ((getline line < bf) > 0) print line
			close(bf)
			done = 1
		}
		{ print }
	' "$MODEL" > /tmp/_adv_model.$$

	if grep -q '"advanced"' /tmp/_adv_model.$$; then
		cat /tmp/_adv_model.$$ > "$MODEL"
		echo "[OK] 已插入两个开关"
	else
		echo "[!!] 插入失败，原文件未改动"
		rm -f "$BLOCK" /tmp/_adv_model.$$
		exit 1
	fi
	rm -f "$BLOCK" /tmp/_adv_model.$$
fi

# 顺手把 advanced 打开，并把线程降到 30、速度下限降到 3
echo
echo "[..] 调低默认参数（advanced=1, threads=30, speed_limit=3）"
uci -q set cloudflarespeedtest.global.advanced='1'
uci -q set cloudflarespeedtest.global.threads='30'
uci -q set cloudflarespeedtest.global.speed_limit='3'
uci -q commit cloudflarespeedtest
echo "[OK]"

echo
echo "[..] 清缓存"
rm -f /tmp/luci-indexcache 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null

echo
echo "================================================"
echo " 完成。刷新浏览器 → 服务 → Cloudflare 速度测试"
echo ""
echo " 现在「测速参数」那一块才真正生效："
echo "   启用高级参数 = 开（已帮你打开）"
echo "   测速线程     = 30（原来写 200 但没生效，实际一直跑 200）"
echo "   下载速度下限 = 3 MB/s"
echo ""
echo " 如果还是卡，把「只测延迟」也打开 —— 完全不测下载，"
echo " 只做 TCP 延迟探测，CPU 和带宽几乎无感。"
echo "================================================"
