#!/bin/sh
# ==============================================================================
# cf-optimizer —— OpenWrt Cloudflare 优选 IP 自动化工具
#
# 功能：定时用 CloudflareSpeedTest(cfst) 测出当前网络最优的 CF IP，
#       然后写进 dnsmasq 的 address 规则，让局域网设备访问指定域名时
#       走这个最快的 IP。
#
# 特点：
#   - 不改动 Cloudflare 后台任何配置，不影响公网其他访客
#   - 橙云(Proxied)域名照样有效：DNS 由路由器劫持，TLS SNI 仍匹配
#   - 新 IP 验证不通过时自动放弃，保留上一次可用的配置
#   - 配置写进 UCI，重启不丢
#
# 用法： cf-optimizer install | run | test | status | apply | update | uninstall
# ==============================================================================

PROG="cf-optimizer"
CONF="/etc/cf-optimizer.conf"
STATEDIR="/etc/cf-optimizer"
CURRENT="$STATEDIR/current"
RESULT="$STATEDIR/result.csv"
BESTFILE="$STATEDIR/best"
IPFILE="$STATEDIR/ip.txt"
LOG="/var/log/cf-optimizer.log"
LOCK="/var/run/cf-optimizer.lock"
SELF="/usr/bin/cf-optimizer"
CORE="/usr/bin/cfst"
REPO="XIU2/CloudflareSpeedTest"
UCI_TARGET="dhcp.@dnsmasq[0]"

# ------------------------------------------------------------------ 基础工具

log() {
	_lvl="$1"; shift
	_line="$(date '+%Y-%m-%d %H:%M:%S') [$_lvl] $*"
	echo "$_line"
	mkdir -p "$(dirname "$LOG")" 2>/dev/null
	echo "$_line" >>"$LOG" 2>/dev/null
	if [ -f "$LOG" ]; then
		_n=$(wc -l <"$LOG" 2>/dev/null)
		if [ "${_n:-0}" -gt 800 ]; then
			tail -n 400 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
		fi
	fi
}

die() { log "ERROR" "$*"; exit 1; }

download() {
	_url="$1"; _out="$2"
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -T 30 -O "$_out" "$_url" >/dev/null 2>&1 && [ -s "$_out" ] && return 0
	fi
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 -m 300 -o "$_out" "$_url" >/dev/null 2>&1 && [ -s "$_out" ] && return 0
	fi
	if command -v wget >/dev/null 2>&1; then
		wget -q -T 30 -O "$_out" "$_url" >/dev/null 2>&1 && [ -s "$_out" ] && return 0
	fi
	return 1
}

acquire_lock() {
	if mkdir "$LOCK" 2>/dev/null; then
		echo $$ >"$LOCK/pid"
		trap 'release_lock' EXIT INT TERM
		return 0
	fi
	_old=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
		return 1
	fi
	rm -rf "$LOCK"
	if mkdir "$LOCK" 2>/dev/null; then
		echo $$ >"$LOCK/pid"
		trap 'release_lock' EXIT INT TERM
		return 0
	fi
	return 1
}

release_lock() { rm -rf "$LOCK" 2>/dev/null; }

# 从 crontab 里删掉本工具自己的那几行（busybox sed 不支持 \| 分隔符，用 grep -v 更稳）
cron_drop_self() {
	[ -f /etc/crontabs/root ] || return 0
	_tmp="/tmp/crontab.cfopt.$$"
	grep -vF "${SELF} run" /etc/crontabs/root >"$_tmp" 2>/dev/null
	cat "$_tmp" >/etc/crontabs/root 2>/dev/null
	rm -f "$_tmp"
}

# ------------------------------------------------------------------ 配置

load_conf() {
	# 默认值
	ENABLED=1
	DOMAINS=""
	APPLY_MODE="dnsmasq"
	TOP_N=1
	MAX_LATENCY=200
	MIN_SPEED=1
	PACKET_LOSS=0.2
	THREADS=100
	PING_TIMES=4
	DL_COUNT=5
	DL_TIME=5
	TEST_URL="https://speed.cloudflare.com/__down?bytes=20000000"
	GH_PROXY=""
	CRON_SPEC="0 4 * * *"

	[ -f "$CONF" ] && . "$CONF"
}

write_default_conf() {
	mkdir -p "$STATEDIR"
	[ -f "$CONF" ] && return 0
	cat >"$CONF" <<'EOF'
# ============ cf-optimizer 配置文件 ============

# 总开关，0 = 只保留配置但不执行
ENABLED=1

# 要劫持的域名，空格分隔。子域名会自动一起生效。
# 例：DOMAINS="www.akkdiy.cn akkdiy.cn"
DOMAINS=""

# 应用方式：
#   dnsmasq —— 写入 UCI 的 dnsmasq address 规则（推荐，持久，全屋生效）
#   hosts   —— 写入 /etc/hosts（简单，但 OpenWrt 上重启会丢）
#   none    —— 只测速、只记录结果，不动任何配置
APPLY_MODE="dnsmasq"

# 保留几个最优 IP（dnsmasq 模式只用第 1 个，其余记录在结果里备查）
TOP_N=1

# 筛选条件：平均延迟上限(ms)、丢包率上限(0~1)、下载速度下限(MB/s)
# 达不到条件的 IP 一律不采用
MAX_LATENCY=200
PACKET_LOSS=0.2
MIN_SPEED=1

# 测速参数。路由器性能弱的话把 THREADS 调小（50 或 30）
THREADS=100
PING_TIMES=4
DL_COUNT=5
DL_TIME=5

# 下载测速用的地址。想更准可以换成自己站上的大文件
TEST_URL="https://speed.cloudflare.com/__down?bytes=20000000"

# GitHub 加速前缀，国内拉不动测速核心时填，例如：
#   GH_PROXY="https://ghproxy.net/"
GH_PROXY=""

# 定时任务（cron 格式），默认每天 04:00 跑一次
CRON_SPEC="0 4 * * *"
EOF
	log "INFO" "已生成默认配置：$CONF"
}

# ------------------------------------------------------------------ 测速核心

detect_arch() {
	case "$(uname -m)" in
		x86_64 | amd64) echo "amd64" ;;
		aarch64 | arm64) echo "arm64" ;;
		armv7*) echo "armv7" ;;
		armv6*) echo "armv6" ;;
		armv5*) echo "armv5" ;;
		i386 | i486 | i586 | i686) echo "386" ;;
		mips64el | mips64le) echo "mips64le" ;;
		mips64) echo "mips64" ;;
		mipsel | mipsle) echo "mipsle" ;;
		mips) echo "mips" ;;
		*) echo "" ;;
	esac
}

ensure_core() {
	if [ -x "$CORE" ]; then return 0; fi
	_arch=$(detect_arch)
	[ -z "$_arch" ] && { log "ERROR" "无法识别 CPU 架构：$(uname -m)"; return 1; }

	_url="https://github.com/${REPO}/releases/latest/download/cfst_linux_${_arch}.tar.gz"
	[ -n "$GH_PROXY" ] && _url="${GH_PROXY}${_url}"

	_tmp="/tmp/cfst.$$"
	rm -rf "$_tmp"; mkdir -p "$_tmp" || return 1

	log "INFO" "下载测速核心（${_arch}）…"
	if ! download "$_url" "$_tmp/pkgs.tar.gz"; then
		rm -rf "$_tmp"
		log "ERROR" "核心下载失败。GitHub 可能被墙，请在 $CONF 里设置 GH_PROXY 镜像后重试"
		return 1
	fi

	tar -xzf "$_tmp/pkgs.tar.gz" -C "$_tmp" 2>/dev/null
	_bin=""
	for _c in "$_tmp/cfst" "$_tmp/CloudflareST"; do
		[ -f "$_c" ] && { _bin="$_c"; break; }
	done
	[ -z "$_bin" ] && _bin=$(find "$_tmp" -type f \( -name cfst -o -name CloudflareST \) 2>/dev/null | head -n 1)
	[ -z "$_bin" ] && { rm -rf "$_tmp"; log "ERROR" "压缩包里没找到 cfst 可执行文件"; return 1; }

	chmod +x "$_bin"
	mv "$_bin" "$CORE" || { rm -rf "$_tmp"; log "ERROR" "无法写入 $CORE"; return 1; }
	rm -rf "$_tmp"
	log "INFO" "测速核心已就绪：$CORE"
	return 0
}

ensure_iplist() {
	[ -s "$IPFILE" ] && return 0
	mkdir -p "$STATEDIR"
	cat >"$IPFILE" <<'EOF'
173.245.48.0/20
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
141.101.64.0/18
108.162.192.0/18
190.93.240.0/20
188.114.96.0/20
197.234.240.0/22
198.41.128.0/17
162.158.0.0/15
104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
131.0.72.0/22
EOF
	log "INFO" "已生成 Cloudflare IP 段列表：$IPFILE"
}

# ------------------------------------------------------------------ 测速与选优

run_test() {
	mkdir -p "$STATEDIR"
	rm -f "$RESULT"

	log "INFO" "开始测速（线程 ${THREADS}，延迟上限 ${MAX_LATENCY}ms，速度下限 ${MIN_SPEED}MB/s）…"

	# 有 timeout 就加个总时长保护，防止弱鸡路由器上跑飞
	if command -v timeout >/dev/null 2>&1; then
		_timeout="timeout 1200"
	else
		_timeout=""
	fi

	$_timeout "$CORE" -f "$IPFILE" -o "$RESULT" -p 5 \
		-n "$THREADS" -t "$PING_TIMES" \
		-dn "$DL_COUNT" -dt "$DL_TIME" -tp 443 \
		-url "$TEST_URL" \
		-tl "$MAX_LATENCY" -tlr "$PACKET_LOSS" -sl "$MIN_SPEED" \
		>>"$LOG" 2>&1
	_rc=$?

	if [ ! -s "$RESULT" ]; then
		log "ERROR" "测速没有产出结果（退出码 $_rc），详见 $LOG"
		return 1
	fi
	log "INFO" "测速完成，结果：$RESULT"
	return 0
}

# 从结果 CSV 里挑出最优的若干条：ip 延迟 速度
pick_best() {
	[ -s "$RESULT" ] || return 1
	awk -F',' -v n="${TOP_N:-1}" '
		NR == 1 { next }
		{
			ip = $1; gsub(/[ \t\r]/, "", ip)
			if (ip == "" || ip ~ /:/) next
			lat = $5; gsub(/[ \t\r]/, "", lat)
			spd = $6; gsub(/[ \t\r]/, "", spd)
			if (spd + 0 <= 0) next
			print ip, lat, spd
			c++
			if (c >= n) exit
		}
	' "$RESULT"
}

verify_ip() {
	_ip="$1"; _domain="$2"
	# 没有 curl 就跳过验证（OpenWrt 精简固件常见），不阻断流程
	command -v curl >/dev/null 2>&1 || return 0
	_code=$(curl -sS -o /dev/null -m 12 -w '%{http_code}' --resolve "${_domain}:443:${_ip}" "https://${_domain}/" 2>/dev/null)
	case "$_code" in
		200 | 301 | 302 | 307 | 308) return 0 ;;
		*) log "WARN" "验证 ${_ip} 访问 ${_domain} 返回 ${_code:-超时}"; return 1 ;;
	esac
}

# ------------------------------------------------------------------ 应用

apply_dnsmasq() {
	_ip="$1"

	# 先撤掉上一次写的规则，避免堆积
	if [ -f "$CURRENT" ]; then
		while read -r _d _old; do
			[ -n "$_d" ] && uci -q del_list "${UCI_TARGET}.address=/${_d}/${_old}" >/dev/null 2>&1
		done <"$CURRENT"
	fi
	: >"$CURRENT"

	_ok=0
	for _d in $DOMAINS; do
		if uci -q add_list "${UCI_TARGET}.address=/${_d}/${_ip}" >/dev/null 2>&1; then
			echo "$_d $_ip" >>"$CURRENT"
			_ok=$((_ok + 1))
		else
			log "WARN" "写入 UCI 失败：$_d"
		fi
	done

	[ "$_ok" -eq 0 ] && { log "ERROR" "没有任何域名写入成功"; return 1; }

	uci -q commit dhcp
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
	log "INFO" "已把 ${_ok} 个域名指向 ${_ip}（dnsmasq 已重载）"
	return 0
}

apply_hosts() {
	_ip="$1"
	_tmp="/tmp/hosts.cfopt.$$"
	grep -v '# cf-optimizer' /etc/hosts >"$_tmp" 2>/dev/null
	for _d in $DOMAINS; do
		printf '%s %s # cf-optimizer\n' "$_ip" "$_d" >>"$_tmp"
	done
	cat "$_tmp" >/etc/hosts
	rm -f "$_tmp"
	: >"$CURRENT"
	for _d in $DOMAINS; do echo "$_d $_ip" >>"$CURRENT"; done
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
	log "INFO" "已写入 /etc/hosts 并重载 dnsmasq（注意：OpenWrt 重启后会丢失）"
	return 0
}

clear_applied() {
	if [ -f "$CURRENT" ]; then
		while read -r _d _ip; do
			[ -n "$_d" ] && uci -q del_list "${UCI_TARGET}.address=/${_d}/${_ip}" >/dev/null 2>&1
		done <"$CURRENT"
		: >"$CURRENT"
		uci -q commit dhcp
	fi
	if grep -q '# cf-optimizer' /etc/hosts 2>/dev/null; then
		_tmp="/tmp/hosts.cfopt.$$"
		grep -v '# cf-optimizer' /etc/hosts >"$_tmp" 2>/dev/null
		cat "$_tmp" >/etc/hosts
		rm -f "$_tmp"
	fi
	/etc/init.d/dnsmasq reload >/dev/null 2>&1
	log "INFO" "已清除所有优选 IP 规则"
}

# ------------------------------------------------------------------ 子命令

cmd_run() {
	load_conf
	[ "$ENABLED" = "1" ] || { log "INFO" "ENABLED=0，跳过"; return 0; }
	[ -n "$DOMAINS" ] || die "没有配置 DOMAINS，请编辑 $CONF"

	acquire_lock || { log "WARN" "已有实例在跑，本次跳过"; return 0; }

	ensure_core || return 1
	ensure_iplist

	run_test || { log "ERROR" "测速失败，保持现有配置不变"; return 1; }

	_line=$(pick_best | head -n 1)
	if [ -z "$_line" ]; then
		log "ERROR" "没有 IP 满足筛选条件，保持现有配置不变"
		return 1
	fi
	_ip=$(echo "$_line" | awk '{print $1}')
	_lat=$(echo "$_line" | awk '{print $2}')
	_spd=$(echo "$_line" | awk '{print $3}')
	log "INFO" "本轮最优：${_ip}  延迟 ${_lat}ms  速度 ${_spd}MB/s"

	_first=$(echo "$DOMAINS" | awk '{print $1}')
	if ! verify_ip "$_ip" "$_first"; then
		log "ERROR" "${_ip} 验证未通过，保持现有配置不变"
		return 1
	fi

	case "$APPLY_MODE" in
		dnsmasq) apply_dnsmasq "$_ip" || return 1 ;;
		hosts) apply_hosts "$_ip" || return 1 ;;
		none) log "INFO" "APPLY_MODE=none，仅测速不应用" ;;
		*) die "未知 APPLY_MODE：$APPLY_MODE" ;;
	esac

	echo "$_ip" >"$BESTFILE"
	log "INFO" "本轮完成"
	return 0
}

cmd_test() {
	load_conf
	[ -n "$DOMAINS" ] || log "WARN" "未配置 DOMAINS，仅做测速"
	acquire_lock || die "已有实例在跑"
	ensure_core || return 1
	ensure_iplist
	run_test || return 1

	echo ""
	echo "=========== 可用 IP（按下载速度排序）==========="
	_rows=$(pick_best_all 2>/dev/null)
	if [ -n "$_rows" ]; then
		printf '%-18s %-12s %-12s\n' "IP" "延迟(ms)" "速度(MB/s)"
		echo "$_rows" | while read -r ip lat spd; do
			printf '%-18s %-12s %-12s\n' "$ip" "$lat" "$spd"
		done
	else
		echo "没有 IP 满足筛选条件。"
		echo "去 $CONF 把 MIN_SPEED 调小（如 0.5）、MAX_LATENCY 调大（如 300）后重试。"
	fi
	echo "==============================================="
	echo "结果文件：$RESULT"
}

# 显示全部结果（不受 TOP_N 限制）
pick_best_all() {
	[ -s "$RESULT" ] || return 1
	awk -F',' '
		NR == 1 { next }
		{
			ip = $1; gsub(/[ \t\r]/, "", ip)
			if (ip == "" || ip ~ /:/) next
			lat = $5; gsub(/[ \t\r]/, "", lat)
			spd = $6; gsub(/[ \t\r]/, "", spd)
			if (spd + 0 <= 0) next
			print ip, lat, spd
		}
	' "$RESULT"
}

cmd_status() {
	load_conf
	echo "配置：$CONF"
	echo "  开关        : ENABLED=$ENABLED"
	echo "  域名        : ${DOMAINS:-<未配置>}"
	echo "  应用方式    : $APPLY_MODE"
	echo "  筛选条件    : 延迟<=${MAX_LATENCY}ms  丢包<=${PACKET_LOSS}  速度>=${MIN_SPEED}MB/s"
	echo "  定时        : ${CRON_SPEC:-<无>}"
	echo ""
	echo "测速核心："
	if [ -x "$CORE" ]; then
		echo "  $CORE  ($(du -h "$CORE" 2>/dev/null | awk '{print $1}'))"
	else
		echo "  未安装（首次运行会自动下载）"
	fi
	echo ""
	echo "当前生效的规则："
	if [ -s "$CURRENT" ]; then
		while read -r d ip; do echo "  $d -> $ip"; done <"$CURRENT"
	else
		echo "  <无>"
	fi
	echo ""
	echo "最近一次测速结果（前 5）："
	if [ -s "$RESULT" ]; then
		_rows=$(pick_best_all 2>/dev/null | head -n 5)
		if [ -n "$_rows" ]; then
			echo "$_rows" | while read -r ip lat spd; do
				printf '  %-18s %6sms  %6s MB/s\n' "$ip" "$lat" "$spd"
			done
		else
			echo "  <结果里没有可用 IP>"
		fi
	else
		echo "  <还没有测过>"
	fi
	echo ""
	echo "定时任务："
	if grep -q 'cf-optimizer' /etc/crontabs/root 2>/dev/null; then
		grep 'cf-optimizer' /etc/crontabs/root | sed 's/^/  /'
	else
		echo "  <未安装>"
	fi
	echo ""
	echo "最近日志："
	if [ -s "$LOG" ]; then
		tail -n 8 "$LOG" | sed 's/^/  /'
	else
		echo "  <无>"
	fi
}

cmd_apply() {
	load_conf
	[ -s "$BESTFILE" ] || die "还没有可用结果，先跑一次 test 或 run"
	_ip=$(cat "$BESTFILE")
	_first=$(echo "$DOMAINS" | awk '{print $1}')
	[ -n "$_first" ] || die "没有配置 DOMAINS"
	verify_ip "$_ip" "$_first" || die "$_ip 验证不通过"
	case "$APPLY_MODE" in
		dnsmasq) apply_dnsmasq "$_ip" ;;
		hosts) apply_hosts "$_ip" ;;
		*) die "APPLY_MODE=$APPLY_MODE 无需手动应用" ;;
	esac
}

cmd_update() {
	load_conf
	rm -f "$CORE"
	ensure_core || exit 1
	"$CORE" -v 2>&1 | head -n 3
}

cmd_install() {
	[ "$(id -u)" = "0" ] || die "请用 root 运行"

	load_conf
	write_default_conf

	# 安装自身
	if [ "$0" != "$SELF" ]; then
		cp "$0" "$SELF" || die "无法写入 $SELF"
	fi
	chmod +x "$SELF"
	log "INFO" "主程序已安装：$SELF"

	# 目录
	mkdir -p "$STATEDIR"

	# 定时任务
	load_conf
	_line="${CRON_SPEC} ${SELF} run >/dev/null 2>&1"
	mkdir -p /etc/crontabs
	touch /etc/crontabs/root
	cron_drop_self
	echo "$_line" >>/etc/crontabs/root
	/etc/init.d/cron enable >/dev/null 2>&1
	/etc/init.d/cron restart >/dev/null 2>&1
	log "INFO" "定时任务已设置：$_line"

	# 依赖检查
	[ -f /etc/config/dhcp ] || log "WARN" "没有找到 /etc/config/dhcp，dnsmasq 模式可能不可用"

	echo ""
	echo "安装完成。接下来："
	echo "  1. 编辑 $CONF，把 DOMAINS 改成你要加速的域名"
	echo "  2. 运行 $PROG test    先看看能不能测出好 IP"
	echo "  3. 运行 $PROG run     测速并自动应用"
	echo ""
}

cmd_uninstall() {
	[ "$(id -u)" = "0" ] || die "请用 root 运行"
	load_conf

	clear_applied

	if [ -f /etc/crontabs/root ]; then
		cron_drop_self
		/etc/init.d/cron restart >/dev/null 2>&1
	fi

	rm -f "$SELF" "$CORE" "$CONF"
	rm -rf "$STATEDIR"
	log "INFO" "已卸载（配置和结果已删除）"
}

usage() {
	cat <<EOF
$PROG —— OpenWrt Cloudflare 优选 IP 自动化

用法：
  $PROG install     安装主程序 + 定时任务 + 生成默认配置
  $PROG test        只测速并列出可用 IP，不改任何配置
  $PROG run         测速 + 验证 + 自动应用到 dnsmasq
  $PROG apply       用上一次的最优 IP 重新应用一次
  $PROG status      查看配置、当前生效规则、最近结果和日志
  $PROG update      重新下载测速核心 cfst
  $PROG uninstall   卸载并清除所有规则

配置文件：$CONF
日志文件：$LOG
EOF
}

# ------------------------------------------------------------------ 入口

case "${1:-}" in
	install) cmd_install ;;
	run) cmd_run ;;
	test) cmd_test ;;
	apply) cmd_apply ;;
	status) cmd_status ;;
	update) cmd_update ;;
	uninstall) cmd_uninstall ;;
	-h | --help | help | "") usage ;;
	*) usage; exit 1 ;;
esac
