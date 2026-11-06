#!/system/bin/sh
#
# late_start 加载 droid_lkm；insmod 期间用标记文件检测内核崩溃。
#
# 安全兜底（方向 B）：
#   - no_boot        首次安装默认存在，开机不自动加载；手动 load 一次验证
#   - boot_pending   自动加载后写；存活窗口结束写 .boot_ok
#   - crash_count    读 ro.boot.bootreason，watchdog/panic 累计；>=2 自动 blocked
#   - blocked        自动加载跳过；手动 load 可临时绕过
#   - pstore         开机自动把 /sys/fs/pstore 复制到模块目录
#   - build-id.txt   记录构建时的 release/kernel sha/config sha；OTA 后拒绝加载
#
# 用法：
#   sh service.sh status     # 状态
#   sh service.sh load       # 手动加载（绕过 no_boot/blocked）
#   sh service.sh reset      # 清除 blocked/crash_count/boot_pending
#   sh service.sh            # 开机自动路径

MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=$(pwd)

LOG=$MODDIR/phdroid.log
MARK=$MODDIR/insmod.inflight
BLOCK=$MODDIR/blocked
CONF=$MODDIR/config.conf
PEND=$MODDIR/boot_pending
OK=$MODDIR/.boot_ok
CRASH=$MODDIR/crash_count
LASTBR=$MODDIR/last_bootreason
PSTORE=$MODDIR/pstore
BUILDID=$MODDIR/build-id.txt
LOG_MAX=262144

MODE=${1:-${PH_ACTION:-}}
BOOT=1
[ -n "$MODE" ] && BOOT=0

ph_log() {
	if [ -f "$LOG" ]; then
		sz=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')
		[ -n "$sz" ] && [ "$sz" -gt "$LOG_MAX" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
	fi
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null
	if [ -w /dev/kmsg ]; then
		echo "<6>phDroid: $*" > /dev/kmsg 2>/dev/null
	fi
	command -v log >/dev/null 2>&1 && log -t phDroid "$*" 2>/dev/null
	return 0
}

conf() {
	v=
	if [ -f "$CONF" ]; then
		v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
			| tail -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//')
	fi
	[ -n "$v" ] && echo "$v" || echo "$2"
}

bool() {
	case "$(conf "$1" "$2")" in
	1 | true | on | yes) echo 1 ;;
	0 | false | off | no) echo 0 ;;
	*) echo "$2" ;;
	esac
}

sint() {
	v=$(conf "$1" "$2")
	case "$v" in
	'') echo "$2" ;;
	-*)
		rest=${v#-}
		case "$rest" in
		'' | *[!0-9]*) echo "$2" ;;
		*) echo "$v" ;;
		esac
		;;
	*[!0-9]*) echo "$2" ;;
	*) echo "$v" ;;
	esac
}

loaded() {
	[ -r /proc/modules ] && grep -q "^$1 " /proc/modules
}

insmod_ko() {
	f=$1
	shift
	if command -v insmod >/dev/null 2>&1; then
		insmod "$f" "$@" 2>&1
		return $?
	fi
	for bb in "${MAGISKTMP:-/nonexistent}/busybox" \
		/data/adb/ksu/bin/busybox \
		/data/adb/ap/bin/busybox \
		/data/adb/magisk/busybox; do
		[ -x "$bb" ] || continue
		"$bb" insmod "$f" "$@" 2>&1
		return $?
	done
	echo "insmod not found"
	return 127
}

try_insmod() {
	f=$1
	shift
	: > "$MARK" 2>/dev/null
	command -v sync >/dev/null 2>&1 && sync
	INS_OUT=$(insmod_ko "$f" "$@")
	INS_RC=$?
	rm -f "$MARK" 2>/dev/null
	command -v sync >/dev/null 2>&1 && sync
	return $INS_RC
}

selinux_allow() {
	ko=$1
	mp=
	for c in magiskpolicy "${MAGISKTMP:-/nonexistent}/magiskpolicy" \
		/data/adb/magisk/magiskpolicy; do
		if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
			mp=$c
			break
		fi
	done
	[ -n "$mp" ] || return 1

	sctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\0')
	sdom=${sctx#u:r:}
	sdom=${sdom%%:*}
	tctx=$(ls -Z "$ko" 2>/dev/null | awk '{print $1}')
	ttype=${tctx#u:object_r:}
	ttype=${ttype%%:*}
	case "$sdom" in '' | *[!a-zA-Z0-9_]*) return 1 ;; esac
	case "$ttype" in '' | *[!a-zA-Z0-9_]*) return 1 ;; esac

	"$mp" --live "allow $sdom $ttype:system module_load" >/dev/null 2>&1 || return 1
	ph_log "selinux: allow $sdom $ttype:system module_load"
	return 0
}

guarded_insmod() {
	try_insmod "$@"
	rc=$?
	if [ "$rc" -ne 0 ] && [ "$(bool selinux_fix 0)" = 1 ]; then
		case "$INS_OUT" in
		*"not permitted"* | *"Permission denied"* | *EPERM*)
			if selinux_allow "$1"; then
				try_insmod "$@"
				rc=$?
			fi
			;;
		esac
	fi
	[ -n "$INS_OUT" ] && ph_log "insmod: $INS_OUT"
	return $rc
}

runtime() {
	if [ -d /data/adb/ksu ]; then
		echo KernelSU
	elif [ -d /data/adb/ap ]; then
		echo APatch
	elif [ -d /data/adb/magisk ]; then
		echo Magisk
	else
		echo unknown
	fi
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
	ph_log "pstore saved: $d"
	ls -1dt "$PSTORE"/* 2>/dev/null | tail -n +4 | while IFS= read -r old; do
		rm -rf "$old" 2>/dev/null
	done
	return 0
}

preflight() {
	rel=$(uname -r)
	if [ -f "$BUILDID" ]; then
		brel=$(sed -n 's/^release=//p' "$BUILDID" 2>/dev/null | tr -d '\r' | head -n 1)
		if [ -n "$brel" ] && [ "$rel" != "$brel" ]; then
			ph_log "preflight: kernel $rel != build $brel (OTA?)"
			return 1
		fi
	fi
	for m in droid_lkm droid_lkm_vendor; do
		f=$MODDIR/ko/$m.ko
		[ -f "$f" ] || continue
		if ! grep -aq "vermagic=$rel " "$f" 2>/dev/null; then
			ph_log "preflight: $m vermagic mismatch (kernel $rel)"
			return 1
		fi
	done
	return 0
}

set_result() {
	echo "$1" > "$MODDIR/last_result" 2>/dev/null
}

# ---------------- status / reset ----------------
if [ "$MODE" = "status" ]; then
	echo "version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
	echo "manager=$(runtime)"
	echo "kernel=$(uname -r)"
	echo "kmi=$(conf kmi -)"
	if loaded droid_lkm; then echo "loaded=1"; else echo "loaded=0"; fi
	if loaded droid_lkm_vendor; then echo "compat=1"; else echo "compat=0"; fi
	case "$(conf compat off)" in
	on | 1 | yes | true) cw=on ;;
	auto) [ "$(conf oplus 0)" = 1 ] && cw=on || cw=off ;;
	*) cw=off ;;
	esac
	if [ "$cw" = on ] && [ ! -f "$MODDIR/ko/droid_lkm_vendor.ko" ]; then cw=missing; fi
	echo "compat_wanted=$cw"
	if [ -f "$BLOCK" ]; then echo "blocked=1"; else echo "blocked=0"; fi
	if [ -f "$MARK" ]; then echo "inflight=1"; else echo "inflight=0"; fi
	if [ -f "$MODDIR/insmod.crash" ]; then echo "crash=1"; else echo "crash=0"; fi
	if [ -f "$MODDIR/no_boot" ]; then echo "no_boot=1"; else echo "no_boot=0"; fi
	if [ -f "$PEND" ]; then echo "boot_pending=1"; else echo "boot_pending=0"; fi
	if [ -f "$OK" ]; then echo "boot_ok=1"; else echo "boot_ok=0"; fi
	echo "crash_count=$(cat "$CRASH" 2>/dev/null | tr -dc '0-9')"
	echo "last_bootreason=$(cat "$LASTBR" 2>/dev/null)"
	echo "build_release=$(sed -n 's/^release=//p' "$BUILDID" 2>/dev/null | head -n 1)"
	echo "pstore=$(ls -1d "$PSTORE"/* 2>/dev/null | wc -l | tr -d ' ')"
	echo "last=$(cat "$MODDIR/last_result" 2>/dev/null)"
	echo "oplus=$(conf oplus 0)"
	echo "brand=$(conf device_brand -)"
	echo "model=$(conf device_model -)"
	for p in /sys/module/droid_lkm/parameters/*; do
		[ -f "$p" ] || continue
		echo "param.${p##*/}=$(cat "$p" 2>/dev/null)"
	done
	for p in /sys/module/droid_lkm_vendor/parameters/*; do
		[ -f "$p" ] || continue
		echo "cparam.${p##*/}=$(cat "$p" 2>/dev/null)"
	done
	echo "---log---"
	tail -n 25 "$LOG" 2>/dev/null
	exit 0
fi

if [ "$MODE" = "reset" ]; then
	rm -f "$BLOCK" "$CRASH" "$PEND" "$OK" "$MARK" \
		"$MODDIR/insmod.crash" "$MODDIR/load.crash" 2>/dev/null
	ph_log "safety state reset (blocked/crash/pending cleared)"
	exit 0
fi

# ---------------- boot safety ----------------
if [ "$BOOT" = 1 ]; then
	collect_pstore

	br=$(boot_reason)
	[ -n "$br" ] && echo "$br" > "$LASTBR" 2>/dev/null
	case "$br" in
	*watchdog* | *kernel_panic* | *panic*)
		cnt=$(cat "$CRASH" 2>/dev/null | tr -dc '0-9')
		[ -z "$cnt" ] && cnt=0
		cnt=$((cnt + 1))
		echo "$cnt" > "$CRASH" 2>/dev/null
		ph_log "bootreason=$br crash_count=$cnt"
		if [ "$cnt" -ge 2 ]; then
			: > "$BLOCK" 2>/dev/null
			ph_log "crash_count>=2 -> blocked"
		fi
		;;
	esac

	if [ -f "$MODDIR/no_boot" ]; then
		ph_log "no_boot: skip auto load (manual: sh service.sh load)"
		exit 0
	fi
	if [ -f "$BLOCK" ]; then
		ph_log "blocked: skip auto load (manual: sh service.sh reset; sh service.sh load)"
		exit 0
	fi
	if [ -f "$PEND" ] && [ ! -f "$OK" ]; then
		mv -f "$PEND" "$MODDIR/load.crash" 2>/dev/null
		: > "$BLOCK" 2>/dev/null
		ph_log "previous boot died after load -> blocked"
		exit 0
	fi
	rm -f "$OK" 2>/dev/null
fi

# 手动 load 也做 preflight；不过 no_boot/blocked 不拦
if ! preflight; then
	set_result "fail: preflight"
	exit 1
fi

# 上次停在 insmod 里：置 blocked，本次不再加载
if [ -f "$MARK" ]; then
	mv -f "$MARK" "$MODDIR/insmod.crash" 2>/dev/null
	: > "$BLOCK" 2>/dev/null
	ph_log "previous insmod never returned, blocked"
	exit 0
fi
if [ "$BOOT" = 1 ] && [ -f "$BLOCK" ]; then
	ph_log "blocked, skip loading"
	exit 0
fi

# ---------------- load core ----------------
KMI=$(conf kmi -)
ph_log "start: mode=${MODE:-boot} kernel=$(uname -r) kmi=$KMI oplus=$(conf oplus 0)"

core_ok=0
if loaded droid_lkm; then
	ph_log "droid_lkm already loaded"
	core_ok=1
else
	KO=$MODDIR/ko/droid_lkm.ko
	if [ ! -f "$KO" ]; then
		ph_log "ko missing: $KO"
		set_result "fail: core ko missing"
		exit 1
	fi

	ph_log "loading droid_lkm.ko"
	guarded_insmod "$KO" \
		"verbose=$(bool verbose 0)" \
		"gate=$(bool gate 0)" \
		"mqueue=$(bool mqueue 1)" \
		"nspid=$(bool nspid 1)" \
		"nspid_append=$(bool nspid_append 1)" \
		"skip_sysvipc=$(bool skip_sysvipc 0)" \
		"no_fake_ns=$(bool no_fake_ns 0)" \
		"skip_do_exit=$(bool skip_do_exit 0)" \
		"degrade=$(bool degrade 0)"
	rc=$?

	if [ "$rc" -eq 0 ] && loaded droid_lkm; then
		core_ok=1
		ph_log "droid_lkm loaded"
		set_result "ok: core"
	else
		ph_log "droid_lkm failed (rc=$rc)"
		set_result "fail: core rc=$rc"
		dmesg 2>/dev/null | tail -n 15 >> "$LOG"
	fi
fi

[ "$core_ok" = 1 ] || exit 1

# ---------------- vendor ----------------
COMPAT=$MODDIR/ko/droid_lkm_vendor.ko
want_compat=0
case "$(conf compat off)" in
on | 1 | yes | true) want_compat=1 ;;
auto) [ "$(conf oplus 0)" = 1 ] && want_compat=1 ;;
esac

if [ "$want_compat" != 1 ]; then
	ph_log "compat: off (oplus=$(conf oplus 0))"
elif [ ! -f "$COMPAT" ]; then
	ph_log "compat: no build in this package"
elif loaded droid_lkm_vendor; then
	ph_log "droid_lkm_vendor already loaded"
else
	ph_log "loading droid_lkm_vendor.ko"
	guarded_insmod "$COMPAT" \
		"ghost=$(bool ghost 1)" \
		"ghost_match=$(conf ghost_match oplus_)" \
		"pid_max_cap=$(sint pid_max_cap 0)"
	rc=$?
	if [ "$rc" -eq 0 ] && loaded droid_lkm_vendor; then
		ph_log "droid_lkm_vendor loaded"
		set_result "ok: core+compat"
	else
		ph_log "droid_lkm_vendor failed (rc=$rc)"
		set_result "fail: compat rc=$rc"
		exit 1
	fi
fi

# ---------------- survival window ----------------
if [ "$BOOT" = 1 ]; then
	: > "$PEND" 2>/dev/null
	SEC=120
	if [ -f "$MODDIR/alive_sec" ]; then
		v=$(tr -dc '0-9' < "$MODDIR/alive_sec" 2>/dev/null)
		[ -n "$v" ] && [ "$v" -gt 0 ] && [ "$v" -le 900 ] && SEC=$v
	fi
	ph_log "survival window ${SEC}s"
	sleep "$SEC"
	if [ -f "$BLOCK" ]; then
		rm -f "$PEND" 2>/dev/null
		exit 0
	fi
	: > "$OK" 2>/dev/null
	rm -f "$PEND" 2>/dev/null
	ph_log "survival ok"
fi

exit 0
