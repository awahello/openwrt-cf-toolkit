#!/bin/sh
# ==============================================================================
# install-cf-dns.sh v2 —— 给插件加「Cloudflare 域名解析」（API 版，域名可配置）
#
# 做的事：
#   1. 写 /usr/bin/cloudflarespeedtest/cloudflare.sh
#        支持 --list 列出账号下的域名 / 某个域名下的 A 记录
#        支持 --dry-run 预演，不实际写入
#        支持多个记录，逗号分隔
#   2. 给主脚本打三个补丁（备份 .orig、sh -n 校验、失败放弃、可重复执行）
#   3. uci 补默认值
#   4. 重写 CBI 表单，加出对应选项
#   5. 清 LuCI 缓存
#
# 用法： sh install-cf-dns.sh
# ==============================================================================

WORKER=/usr/bin/cloudflarespeedtest/cloudflare.sh
MAIN=/usr/bin/cloudflarespeedtest/cloudflarespeedtest.sh
MODEL=/usr/lib/lua/luci/model/cbi/cloudflarespeedtest/general.lua

echo "================================================"
echo " 添加 Cloudflare 域名解析（API 版）"
echo "================================================"

if [ ! -f "$MAIN" ]; then
	echo "!! 主脚本不存在：$MAIN"
	exit 1
fi
if [ ! -f /etc/config/cloudflarespeedtest ]; then
	echo "!! 没有 /etc/config/cloudflarespeedtest"
	exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
	echo "!! 没有 curl，Cloudflare API 需要它"
	echo "   opkg update && opkg install curl"
	exit 1
fi
echo "[OK] 环境检查通过"

# ---------------------------------------------------------------- 1. worker
echo
echo "[1] 写 cloudflare.sh"
cat >"$WORKER" <<'SH_WORKER'
#!/bin/sh
# 把测速结果里的最优 IP 写进 Cloudflare DNS 的 A 记录
#
# 用法：
#   cloudflare.sh --token T --list                     列出账号下的域名
#   cloudflare.sh --token T --zone Z --list            列出某域名下的 A 记录
#   cloudflare.sh --token T --zone Z --record R[,R2] [--ttl 120] [--dry-run] [--force]
#   cloudflare.sh ... --result-csv /path/result.csv

RESULT="/tmp/CloudflareSpeedTest/result.csv"
TOKEN=""; ZONE=""; RECORD=""; TTL="120"; FORCE="0"; DRY="0"; MODE="apply"
API="https://api.cloudflare.com/client/v4"
TMP="/tmp/cf-dns.$$"

while [ $# -gt 0 ]; do
	case "$1" in
		--result-csv) RESULT="$2"; shift 2 ;;
		--token)      TOKEN="$2";  shift 2 ;;
		--zone)       ZONE="$2";   shift 2 ;;
		--record)     RECORD="$2"; shift 2 ;;
		--ttl)        TTL="$2";    shift 2 ;;
		--force)      FORCE="1";   shift ;;
		--dry-run)    DRY="1";     shift ;;
		--list)       MODE="list"; shift ;;
		*) shift ;;
	esac
done

log() { echo "cloudflare: $*"; }
cleanup() { rm -f "$TMP".* 2>/dev/null; }
fail() { log "失败: $*"; cleanup; exit 1; }

[ -n "$TOKEN" ] || fail "没配置 API Token"

case "$TTL" in ''|*[!0-9]*) TTL=120 ;; esac

api_get() {
	curl -sS -m 30 -H "Authorization: Bearer $TOKEN" \
		-H "Content-Type: application/json" "$1"
}

# 取 JSON 里的字段列表：优先 jsonfilter，退化成 grep
jlist() {
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$1" -e "$2" 2>/dev/null
	else
		grep -o "\"$3\":\"[^\"]*\"" "$1" 2>/dev/null | sed "s/\"$3\":\"//; s/\"$//"
	fi
}

jone() {
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$1" -e "$2" 2>/dev/null
	else
		grep -o "\"$3\":\"[^\"]*\"" "$1" 2>/dev/null | head -n1 | sed "s/\"$3\":\"//; s/\"$//"
	fi
}

# ------------------------------------------------------------------ list 模式
if [ "$MODE" = "list" ]; then
	if [ -z "$ZONE" ]; then
		api_get "$API/zones?per_page=50" > "$TMP.zones"
		grep -q '"success":true' "$TMP.zones" || { log "返回: $(head -c 300 "$TMP.zones")"; fail "Token 无效或没有 Zone 读取权限"; }
		echo "账号下的域名："
		jlist "$TMP.zones" '@.result[*].name' 'name' | sort -u | sed 's/^/  /'
		echo ""
		echo "拿到域名后，看它的 A 记录："
		echo "  cloudflare.sh --token <TOKEN> --zone <域名> --list"
	else
		api_get "$API/zones?name=$ZONE" > "$TMP.zone"
		ZID=$(jone "$TMP.zone" '@.result[0].id' 'id')
		[ -n "$ZID" ] || fail "查不到域名 $ZONE（Token 权限或域名拼写）"
		api_get "$API/zones/$ZID/dns_records?type=A&per_page=100" > "$TMP.recs"
		echo "$ZONE 下的 A 记录："
		jlist "$TMP.recs" '@.result[*].name' 'name' | sort -u | sed 's/^/  /'
		echo ""
		echo "注意：proxied=true 的是橙云，改 A 记录不会生效。"
	fi
	cleanup
	exit 0
fi

# ------------------------------------------------------------------ apply 模式
[ -n "$ZONE" ]   || fail "没配置域名（Zone）"
[ -n "$RECORD" ] || fail "没配置要更新的记录名"
[ -f "$RESULT" ] || fail "测速结果不存在: $RESULT"

BESTIP=$(awk -F',' '
	NR > 1 {
		ip = $1; gsub(/[ \t\r]/, "", ip)
		if (ip == "" || ip ~ /:/) next
		spd = $6; gsub(/[ \t\r]/, "", spd)
		if (spd + 0 <= 0) next
		print ip
		exit
	}' "$RESULT")

[ -n "$BESTIP" ] || fail "结果里没有可用 IPv4"

log "最优 IP: $BESTIP"
log "域名: $ZONE   记录: $RECORD   TTL: $TTL"

# 查 zone id
api_get "$API/zones?name=$ZONE" > "$TMP.zone"
ZID=$(jone "$TMP.zone" '@.result[0].id' 'id')
[ -n "$ZID" ] || { log "返回: $(head -c 300 "$TMP.zone")"; fail "查不到域名 $ZONE（Token 权限或域名拼写）"; }
log "zone id: $ZID"

sync_one() {
	_r="$1"
	api_get "$API/zones/$ZID/dns_records?type=A&name=$_r" > "$TMP.rec"
	RID=$(jone "$TMP.rec" '@.result[0].id' 'id')
	if [ -z "$RID" ]; then
		log "[$_r] 没有找到 A 记录，跳过"
		return 1
	fi

	if command -v jsonfilter >/dev/null 2>&1; then
		PROXIED=$(jsonfilter -i "$TMP.rec" -e '@.result[0].proxied' 2>/dev/null)
		CURIP=$(jsonfilter -i "$TMP.rec" -e '@.result[0].content' 2>/dev/null)
	else
		PROXIED=$(grep -o '"proxied":[a-z]*' "$TMP.rec" | head -n1 | cut -d: -f2)
		CURIP=$(grep -o '"content":"[^"]*"' "$TMP.rec" | head -n1 | cut -d'"' -f4)
	fi

	log "[$_r] 当前: ${CURIP:-?}  proxied=${PROXIED:-?}"

	if [ "$CURIP" = "$BESTIP" ]; then
		log "[$_r] 已经是最优 IP，无需改动"
		return 0
	fi

	if [ "$PROXIED" = "true" ] && [ "$FORCE" != "1" ]; then
		log "[$_r] 是橙云，改 A 记录不生效，已跳过（要强制请开「橙云记录也强制写入」）"
		return 0
	fi

	if [ "$DRY" = "1" ]; then
		log "[$_r] [预演] 会把 $CURIP 改成 $BESTIP，未实际写入"
		return 0
	fi

	curl -sS -m 30 -X PATCH "$API/zones/$ZID/dns_records/$RID" \
		-H "Authorization: Bearer $TOKEN" \
		-H "Content-Type: application/json" \
		--data "{\"content\":\"$BESTIP\",\"ttl\":$TTL}" > "$TMP.patch"

	if grep -q '"success":true' "$TMP.patch"; then
		log "[$_r] 已更新 -> $BESTIP"
		return 0
	else
		log "[$_r] 返回: $(head -c 300 "$TMP.patch")"
		return 1
	fi
}

RC=0
echo "$RECORD" | tr ',' '\n' | while read -r _one; do
	_one=$(echo "$_one" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	[ -n "$_one" ] || continue
	sync_one "$_one" || RC=1
done

cleanup
exit $RC
SH_WORKER
chmod +x "$WORKER"
echo "    [OK] $WORKER"

# ---------------------------------------------------------------- 2. 补丁
echo
echo "[2] 给主脚本打补丁"

if grep -q 'cloudflare_dns_ip' "$MAIN" 2>/dev/null; then
	echo "    [跳过] 已经打过了"
else
	cp "$MAIN" "$MAIN.orig" 2>/dev/null
	echo "    [OK] 已备份 $MAIN.orig"

	FUNCFILE=/tmp/_cf_func.$$
	cat >"$FUNCFILE" <<'SH_FUNC'
function cloudflare_dns_ip() {
    if [ "x${cloudflare_enabled}" == "x1" ] ;then
        if [ ! -x /usr/bin/cloudflarespeedtest/cloudflare.sh ]; then
            echolog "cloudflare 写入失败: cloudflare.sh 不存在"
            return
        fi
        if [ "x${cloudflare_force}" == "x1" ]; then
            /usr/bin/cloudflarespeedtest/cloudflare.sh --result-csv "$IP_FILE" --token "$cloudflare_token" --zone "$cloudflare_zone" --record "$cloudflare_record" --ttl "${cloudflare_ttl:-120}" --force >>$LOG_FILE 2>&1
        else
            /usr/bin/cloudflarespeedtest/cloudflare.sh --result-csv "$IP_FILE" --token "$cloudflare_token" --zone "$cloudflare_zone" --record "$cloudflare_record" --ttl "${cloudflare_ttl:-120}" >>$LOG_FILE 2>&1
        fi
        if [ $? -eq 0 ]; then
            echolog "cloudflare 域名解析已处理"
        else
            echolog "cloudflare 域名解析失败，详见日志"
        fi
    fi
}

SH_FUNC

	T1=/tmp/_cf_t1.$$
	T2=/tmp/_cf_t2.$$

	sed 's/"AstraDNS_enabled" "AstraDNS_config" "AstraDNS_bin"/"AstraDNS_enabled" "AstraDNS_config" "AstraDNS_bin" "cloudflare_enabled" "cloudflare_token" "cloudflare_zone" "cloudflare_record" "cloudflare_ttl" "cloudflare_force"/' "$MAIN" > "$T1"

	awk '/^        astra_dns_ip$/ { print; print "        cloudflare_dns_ip"; next } { print }' "$T1" > "$T2"

	awk -v fnf="$FUNCFILE" '
		/^function passwall_best_ip\(\)\{/ && !done {
			while ((getline line < fnf) > 0) print line
			close(fnf)
			done = 1
		}
		{ print }
	' "$T2" > "$T1"

	if sh -n "$T1" 2>/dev/null; then
		cat "$T1" > "$MAIN"
		echo "    [OK] 补丁已应用，语法校验通过"
	else
		echo "    [!!] 打补丁后语法错误，已放弃，原文件未改动"
		rm -f "$FUNCFILE" "$T1" "$T2"
		exit 1
	fi
	rm -f "$FUNCFILE" "$T1" "$T2"

	grep -q 'cloudflare_enabled' "$MAIN" && echo "    [OK] 配置项已加"
	grep -q '^        cloudflare_dns_ip$' "$MAIN" && echo "    [OK] 调用点已加"
	grep -q 'function cloudflare_dns_ip' "$MAIN" && echo "    [OK] 函数体已加"
fi

# ---------------------------------------------------------------- 3. uci
echo
echo "[3] 补 uci 默认值"
for kv in \
	"cloudflare_enabled=0" \
	"cloudflare_token=" \
	"cloudflare_zone=" \
	"cloudflare_record=" \
	"cloudflare_ttl=120" \
	"cloudflare_force=0"
do
	k=${kv%%=*}; v=${kv#*=}
	uci -q get "cloudflarespeedtest.servers.$k" >/dev/null 2>&1 || \
		uci -q set "cloudflarespeedtest.servers.$k=$v"
done
uci -q commit cloudflarespeedtest
echo "    [OK]"

# ---------------------------------------------------------------- 4. CBI
echo
echo "[4] 重写 CBI 表单"
if [ -f "$MODEL" ]; then
	cp "$MODEL" "$MODEL.bak" 2>/dev/null

	CFBLOCK=/tmp/_cf_cbi.$$
	cat >"$CFBLOCK" <<'LUA_BLOCK'

o = s:option(Flag, "cloudflare_enabled", translate("Cloudflare 域名解析"))
o.rmempty = false
o.default = "0"
o.description = translate("把测速得到的最优 IP 通过 API 写进 Cloudflare DNS 的 A 记录")

o = s:option(Value, "cloudflare_token", translate("API Token"))
o:depends("cloudflare_enabled", "1")
o.password = true
o.placeholder = "Cloudflare 后台 → 我的个人资料 → API 令牌"
o.description = translate("权限只需要 Zone → DNS → 编辑。填好后可以点下面的按钮列出域名")

o = s:option(Value, "cloudflare_zone", translate("域名（Zone）"))
o:depends("cloudflare_enabled", "1")
o.placeholder = "example.com"
o.description = translate("主域名，不带 www")

o = s:option(Value, "cloudflare_record", translate("要更新的记录"))
o:depends("cloudflare_enabled", "1")
o.placeholder = "www.example.com,example.com"
o.description = translate("可以填多个，用英文逗号分隔。记录必须已经存在")

o = s:option(Value, "cloudflare_ttl", translate("TTL（秒）"))
o.datatype = "uinteger"
o.default = "120"
o:depends("cloudflare_enabled", "1")

o = s:option(Flag, "cloudflare_force", translate("橙云记录也强制写入"))
o.rmempty = false
o.default = "0"
o:depends("cloudflare_enabled", "1")
o.description = translate("橙云记录改 A 记录不会生效，除非你清楚在做什么")

LUA_BLOCK

	awk -v bf="$CFBLOCK" '
		/^return m$/ && !done {
			while ((getline line < bf) > 0) print line
			close(bf)
			done = 1
		}
		{ print }
	' "$MODEL" > /tmp/_cf_model.$$
	cat /tmp/_cf_model.$$ > "$MODEL"
	rm -f "$CFBLOCK" /tmp/_cf_model.$$
	echo "    [OK] 已加 6 个选项（原文件备份为 general.lua.bak）"
else
	echo "    !! CBI 表单不存在，跳过（先跑 install-lua-ui.sh）"
fi

# ---------------------------------------------------------------- 5. 缓存
echo
echo "[5] 清缓存"
rm -f /tmp/luci-indexcache 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null
echo "    [OK]"

echo
echo "================================================"
echo " 完成。刷新浏览器 → 服务 → Cloudflare 速度测试"
echo " 最下面会多出「Cloudflare 域名解析」一组选项。"
echo ""
echo " 用 API 查你的域名和记录（推荐先跑这个）："
echo "   /usr/bin/cloudflarespeedtest/cloudflare.sh --token <TOKEN> --list"
echo "   /usr/bin/cloudflarespeedtest/cloudflare.sh --token <TOKEN> --zone 你的域名 --list"
echo ""
echo " 预演一次，看会改成什么（不实际写入）："
echo "   /usr/bin/cloudflarespeedtest/cloudflare.sh --token <TOKEN> \\"
echo "     --zone 你的域名 --record www.你的域名 --dry-run"
echo ""
echo " 注意：橙云（proxied）记录改 A 记录不生效，默认自动跳过并写日志。"
echo ""
echo " 回滚主脚本： cp $MAIN.orig $MAIN"
echo "================================================"
