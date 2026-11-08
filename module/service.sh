#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# phDroid hummer safety loader (upstream 9f65632 + 安全兜底)
#
# 默认不自动加载：/data/adb/phdroid/auto 不存在时只记录日志。
#   touch /data/adb/phdroid/auto        # 验证稳定后再开自启
#   sh service.sh load                  # 手动加载一次
#   sh service.sh status                # 状态
#   sh service.sh reset                 # 清 blocked/crash/pending
#
# 安全状态都在 /data/adb/phdroid/：
#   insmod        正在 insmod；下次开机还在 -> blocked
#   blocked       自动加载跳过；手动 load 可绕过
#   boot_pending  自动加载后写；存活窗口结束写 .boot_ok
#   crash_count   ro.boot.bootreason 为 watchdog/panic 时累计；>=2 -> blocked
#   pstore/       开机自动保存的 /sys/fs/pstore

MODDIR=${0%/*}
DATA=${DATA:-/data/adb/phdroid}
CONF=$MODDIR/config.conf
LOG=$DATA/phdroid.log
AUTO=$DATA/auto
MARK=$DATA/insmod
BLOCK=$DATA/blocked
PEND=$DATA/boot_pending
OK=$DATA/.boot_ok
CRASH=$DATA/crash_count
LASTBR=$DATA/last_bootreason
PSTORE=$DATA/pstore
BUILDID=$MODDIR/build-id.txt
LAST=$DATA/last_result
LOG_MAX=262144

MODE=${1:-${PH_ACTION:-}}
BOOT=1
[ -n "$MODE" ] && BOOT=0

log() {
	local size
	if [ -f "$LOG" ]; then
		size=$(wc -c < "$LOG" 2>/dev/null)
		[ "${size:-0}" -gt "$LOG_MAX" ] && rm -f "$LOG"
	fi
	mkdir -p "$DATA" 2>/dev/null
	printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
	if [ -w /dev/kmsg ]; then
		echo "<6>phDroid: $*" > /dev/kmsg 2>/dev/null
	fi
}

conf() {
	sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '\r'
}

loaded() {
	[ -r /proc/modules ] && grep -q "^$1 " /proc/modules
}

boot_reason() {
	v=$(getprop ro.boot.bootreason 2>/dev/null | tr -d '\r')
	[ -n "$v" ] && { echo "$v"; return; }
	cat /proc/cmdline 2>/dev/null | tr ' ' '\n' \
		| sed -n 's/^androidboot.bootreason=//p' | tail -n 1
}

collect_pstore() {
	[ -d /sys/fs/pstore ] || return 0
	ls /sys/fs/pstore/console-ramoops* >/dev/null 2>&1 || return 0
	d="$PSTORE/$(date '+%Y%m%d-%H%M%S')"
	mkdir -p "$d" 2>/dev/null || return 0
	for f in /sys/fs/pstore/*; do
		[ -f "$f" ] || continue
		cp "$f" "$d/$(basename "$f")" 2>/dev/null
	done
	log "pstore saved: $d"
	ls -1dt "$PSTORE"/* 2>/dev/null | tail -n +4 | while IFS= read -r old; do
		rm -rf "$old" 2>/dev/null
	done
}

preflight() {
	rel=$(uname -r)
	if [ -f "$BUILDID" ]; then
		brel=$(sed -n 's/^release=//p' "$BUILDID" 2>/dev/null | tr -d '\r' | head -n 1)
		if [ -n "$brel" ] && [ "$rel" != "$brel" ]; then
			log "preflight: kernel $rel != build $brel (OTA?)"
			return 1
		fi
	fi
	for ko in "$MODDIR"/bin/*/*.ko; do
		[ -f "$ko" ] || continue
		if ! grep -aq "vermagic=$rel " "$ko" 2>/dev/null; then
			log "preflight: $ko vermagic mismatch (kernel $rel)"
			return 1
		fi
	done
	return 0
}

do_install() {
	local m ko out rc
	for m in $(conf modules); do
		ko=$(ls "$MODDIR"/bin/*/"$m".ko 2>/dev/null | head -n 1)
		[ -f "$ko" ] || {
			log "missing $m.ko"
			return 1
		}
		if loaded "$m"; then
			log "$m already loaded"
			continue
		fi
		out=$(insmod "$ko" $(conf "$m") 2>&1)
		rc=$?
		[ -n "$out" ] && log "insmod $m: $out"
		[ "$rc" -eq 0 ] || return "$rc"
	done
	return 0
}

safety_boot() {
	collect_pstore

	br=$(boot_reason)
	[ -n "$br" ] && echo "$br" > "$LASTBR" 2>/dev/null
	case "$br" in
	*watchdog* | *kernel_panic* | *panic*)
		cnt=$(cat "$CRASH" 2>/dev/null | tr -dc '0-9')
		[ -z "$cnt" ] && cnt=0
		cnt=$((cnt + 1))
		echo "$cnt" > "$CRASH" 2>/dev/null
		log "bootreason=$br crash_count=$cnt"
		if [ "$cnt" -ge 2 ]; then
			: > "$BLOCK" 2>/dev/null
			log "crash_count>=2 -> blocked"
		fi
		;;
	esac

	[ -f "$AUTO" ] || {
		log "auto off (touch $AUTO to enable)"
		exit 0
	}
	[ -f "$BLOCK" ] && {
		log "blocked (manual: sh service.sh reset; sh service.sh load)"
		exit 0
	}
	if [ -f "$MARK" ]; then
		mv -f "$MARK" "$BLOCK" 2>/dev/null
		log "previous insmod never returned, blocked"
		exit 0
	fi
	if [ -f "$PEND" ] && [ ! -f "$OK" ]; then
		mv -f "$PEND" "$DATA/load.crash" 2>/dev/null
		: > "$BLOCK" 2>/dev/null
		log "previous boot died after load -> blocked"
		exit 0
	fi
	rm -f "$OK" 2>/dev/null

	if ! preflight; then
		echo "fail: preflight" > "$LAST" 2>/dev/null
		exit 1
	fi

	printf '%s\n' "$(conf modules)" > "$MARK"
	sync
	do_install
	rc=$?
	rm -f "$MARK"
	sync
	if [ "$rc" -ne 0 ]; then
		log "install failed rc=$rc"
		echo "fail: rc=$rc" > "$LAST" 2>/dev/null
		exit 1
	fi
	log "loaded $(conf modules)"
	echo "ok: $(conf modules)" > "$LAST" 2>/dev/null

	: > "$PEND" 2>/dev/null
	SEC=120
	[ -f "$DATA/alive_sec" ] && SEC=$(tr -dc '0-9' < "$DATA/alive_sec")
	case "$SEC" in ''|*[!0-9]*) SEC=120 ;; esac
	[ "$SEC" -gt 900 ] && SEC=900
	log "survival window ${SEC}s"
	sleep "$SEC"
	if [ -f "$BLOCK" ]; then
		rm -f "$PEND" 2>/dev/null
		exit 0
	fi
	: > "$OK" 2>/dev/null
	rm -f "$PEND" 2>/dev/null
	log "survival ok"
}

main_load() {
	if ! preflight; then
		echo "fail: preflight" > "$LAST" 2>/dev/null
		exit 1
	fi
	if [ -f "$MARK" ]; then
		log "insmod marker present; run reset first"
		exit 1
	fi
	printf '%s\n' "$(conf modules)" > "$MARK"
	sync
	do_install
	rc=$?
	rm -f "$MARK"
	sync
	[ "$rc" -eq 0 ] && log "manual load ok" || log "manual load failed rc=$rc"
	[ "$rc" -eq 0 ] && echo "ok: manual" > "$LAST" 2>/dev/null || echo "fail: manual rc=$rc" > "$LAST" 2>/dev/null
	return "$rc"
}

case "$MODE" in
status)
	echo "version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "kernel=$(uname -r)"
	echo "kmi=$(conf kmi_override)"
	echo "manager=$(if [ -d /data/adb/ksu ]; then echo KernelSU; elif [ -d /data/adb/ap ]; then echo APatch; elif [ -d /data/adb/magisk ]; then echo Magisk; else echo unknown; fi)"
	echo "brand=$(getprop ro.product.brand 2>/dev/null)"
	echo "model=$(getprop ro.product.model 2>/dev/null)"
	echo "oplus=$(conf oplus 1)"
	echo "loaded=$(loaded droid_lkm && echo 1 || echo 0)"
	echo "compat=$(loaded droid_lkm_vendor && echo 1 || echo 0)"
	case "$(conf modules)" in
	*droid_lkm_vendor*) echo "compat_wanted=on" ;;
	*) echo "compat_wanted=off" ;;
	esac
	echo "modules=$(conf modules)"
	echo "auto=$([ -f "$AUTO" ] && echo 1 || echo 0)"
	echo "blocked=$([ -f "$BLOCK" ] && echo 1 || echo 0)"
	echo "crash_count=$(cat "$CRASH" 2>/dev/null | tr -dc '0-9')"
	echo "boot_pending=$([ -f "$PEND" ] && echo 1 || echo 0)"
	echo "boot_ok=$([ -f "$OK" ] && echo 1 || echo 0)"
	echo "last_bootreason=$(cat "$LASTBR" 2>/dev/null)"
	echo "pstore=$(ls -1d "$PSTORE"/* 2>/dev/null | wc -l | tr -d ' ')"
	echo "build_release=$(sed -n 's/^release=//p' "$BUILDID" 2>/dev/null | head -n 1)"
	echo "last=$(cat "$LAST" 2>/dev/null)"
	for p in /sys/module/droid_lkm/parameters/*; do
		[ -f "$p" ] || continue
		echo "param.${p##*/}=$(cat "$p" 2>/dev/null)"
	done
	for p in /sys/module/droid_lkm_vendor/parameters/*; do
		[ -f "$p" ] || continue
		echo "cparam.${p##*/}=$(cat "$p" 2>/dev/null)"
	done
	echo "---log---"
	tail -n 30 "$LOG" 2>/dev/null
	exit 0
	;;
reset)
	rm -f "$BLOCK" "$CRASH" "$PEND" "$OK" "$MARK" "$DATA/load.crash" 2>/dev/null
	log "safety state reset"
	exit 0
	;;
load)
	main_load
	exit $?
	;;
esac

if [ "$BOOT" = 1 ]; then
	safety_boot
else
	# 带未知参数时按手动加载处理
	main_load
fi

exit 0
