#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 公共加载器：MODDIR 由 service.sh / customize.sh / post-fs-data.sh 设置。
# 设计目标：
#   - 默认不自动加载（$DS_DATA/auto 不存在）
#   - 加载前校验完整内核 release、vermagic、SHA-256
#   - namespace 必须先成功，devtmpfs / netfilter 失败只降级为“部分加载”
#   - 已激活的 .ko 不能热卸载，只能重启

DS_DATA=${DS_DATA:-/data/adb/droidspaces_hummer}
DS_LOG=$DS_DATA/load.log
DS_STATUS=$DS_DATA/status.txt
DS_AUTO=$DS_DATA/auto
DS_BLOCKED=$DS_DATA/blocked
DS_MARK=$DS_DATA/insmod
DS_PEND=$DS_DATA/boot_pending
DS_OK=$DS_DATA/.boot_ok
DS_CRASH=$DS_DATA/crash_count
DS_LASTBR=$DS_DATA/last_bootreason
DS_PSTORE=$DS_DATA/pstore
DS_BUILDID=$MODDIR/build-id.txt
DS_MODULE_SYS=/sys/module/droidspaces_ns
DS_KSUD=/data/adb/ksud
[ -x "$DS_KSUD" ] || DS_KSUD=/data/adb/ksu/bin/ksud
export KSU_MODULE=droidspaces_hummer

# 所有状态文件都放在这里；提前创建，避免重定向到不存在的目录。
mkdir -p "$DS_DATA" 2>/dev/null

ds_log() {
	[ -d "$DS_DATA" ] || mkdir -p "$DS_DATA" 2>/dev/null
	printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$DS_LOG" 2>/dev/null
	if [ -w /dev/kmsg ]; then
		printf '<6>droidspaces_hummer: %s\n' "$*" > /dev/kmsg 2>/dev/null
	fi
}

# 同时更新模块简介和 status.txt；失败时不影响加载。
ds_status() {
	ds_message=$1
	printf '%s\n' "$ds_message"
	mkdir -p "$DS_DATA" 2>/dev/null
	printf '%s\n' "$ds_message" > "$DS_STATUS" 2>/dev/null
	if [ -x "$DS_KSUD" ] && "$DS_KSUD" module config set --temp override.description "$ds_message" 2>/dev/null; then
		return 0
	fi
	DS_DESCRIPTION="$ds_message" awk '
		!/^description=/ { print }
		END { print "description=" ENVIRON["DS_DESCRIPTION"] }
	' "$MODDIR/module.prop" > "$MODDIR/module.prop.tmp" 2>/dev/null &&
		cat "$MODDIR/module.prop.tmp" > "$MODDIR/module.prop" 2>/dev/null
	rm -f "$MODDIR/module.prop.tmp" 2>/dev/null
}

ds_conf() {
	# ds_conf key default
	v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$MODDIR/config.conf" 2>/dev/null \
		| tail -n 1 | tr -d '\r' | sed 's/[[:space:]]*$//')
	[ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "$2"
}

ds_loaded() {
	[ -r /proc/modules ] && grep -q "^$1 " /proc/modules
}

ds_active() {
	[ "$(cat "$DS_MODULE_SYS/parameters/activate" 2>/dev/null)" = Y ] &&
		[ -e /proc/self/ns/pid ] && [ -e /proc/self/ns/pid_for_children ] &&
		[ -e /proc/self/ns/ipc ]
}

ds_build_release() {
	sed -n 's/^release=//p' "$DS_BUILDID" 2>/dev/null | head -n 1 | tr -d '\r'
}

ds_verify_payloads() {
	want=$(ds_build_release)
	[ -n "$want" ] || { ds_log 'build-id.txt 缺少 release'; return 1; }
	rel=$(uname -r)
	if [ "$rel" != "$want" ]; then
		ds_log "kernel mismatch: running $rel, built for $want"
		return 1
	fi
	for ko in "$MODDIR"/kernel/*.ko; do
		[ -f "$ko" ] || continue
		if ! grep -q "vermagic=$want " "$ko" 2>/dev/null; then
			ds_log "vermagic mismatch: $ko"
			return 1
		fi
	done
	if [ -f "$MODDIR/kernel/SHA256SUMS" ]; then
		if command -v sha256sum >/dev/null 2>&1; then
			(cd "$MODDIR/kernel" && sha256sum -c SHA256SUMS) >> "$DS_LOG" 2>&1 || return 1
		elif [ -x /data/adb/ksu/bin/busybox ]; then
			(cd "$MODDIR/kernel" && /data/adb/ksu/bin/busybox sha256sum -c SHA256SUMS) >> "$DS_LOG" 2>&1 || return 1
		else
			ds_log 'sha256sum 不可用，跳过校验'
		fi
	fi
	return 0
}

ds_insmod() {
	ko=$1
	params=$2
	if [ -x "$DS_KSUD" ]; then
		if [ -n "$params" ]; then
			"$DS_KSUD" insmod "$ko" $params
		else
			"$DS_KSUD" insmod "$ko"
		fi
		return $?
	fi
	if [ -n "$params" ]; then
		insmod "$ko" $params
	else
		insmod "$ko"
	fi
}

ds_module_for_namespace() {
	if [ "$(ds_conf userns 0)" = 1 ] && [ -f "$MODDIR/kernel/droidspaces_ns_userns.ko" ]; then
		printf '%s\n' "$MODDIR/kernel/droidspaces_ns_userns.ko"
	else
		printf '%s\n' "$MODDIR/kernel/droidspaces_ns.ko"
	fi
}

ds_try_optional() {
	# ds_try_optional <module-name> <ko> <config-key> <default>
	mod=$1 ko=$2 key=$3 def=$4
	[ "$(ds_conf "$key" "$def")" = 1 ] || return 0
	[ -f "$ko" ] || { ds_log "$key=1 但缺少 $ko"; return 1; }
	ds_loaded "$mod" && return 0
	out=$(ds_insmod "$ko" "" 2>&1)
	rc=$?
	[ -n "$out" ] && ds_log "insmod $mod: $out"
	if [ "$rc" -ne 0 ] && ! ds_loaded "$mod"; then
		# devtmpfs 可能已由内核原生提供，此时 -EEXIST 是可接受的。
		if [ "$mod" = droidspaces_devtmpfs ] && grep -q devtmpfs /proc/filesystems 2>/dev/null; then
			ds_log 'devtmpfs 已由内核提供，跳过该 KO'
			return 0
		fi
		ds_log "$mod 加载失败 rc=$rc"
		return 1
	fi
	return 0
}

ds_load_all() {
	if ds_active; then
		ds_status "[已加载] PID / IPC namespace 已激活（本次开机）；更换 .ko 需重启。"
		return 0
	fi
	if [ -d "$DS_MODULE_SYS" ]; then
		ds_status '[加载失败] droidspaces_ns 已存在但未激活；请重启后重试。'
		return 1
	fi
	if ds_loaded droid_lkm; then
		ds_status '[不兼容] 检测到 phDroid / droid_lkm 已加载；两套 namespace 钩子不能共存，请先停用 phDroid 并重启。'
		return 1
	fi
	if ! ds_verify_payloads; then
		ds_status "[不兼容] 内核 $(uname -r) 与构建目标不匹配，或载荷校验失败；未加载。"
		return 1
	fi
	if [ ! -x "$DS_KSUD" ] && ! command -v insmod >/dev/null 2>&1; then
		ds_status '[加载失败] 找不到 ksud / insmod。'
		return 1
	fi

	ns=$(ds_module_for_namespace)
	ds_log "loading $ns"
	out=$(ds_insmod "$ns" "gki=1 activate=1" 2>&1)
	rc=$?
	[ -n "$out" ] && ds_log "insmod namespace: $out"
	if [ "$rc" -ne 0 ] || ! ds_active; then
		ds_status "[加载失败] namespace insmod rc=$rc，activate 检查未通过；详见 load.log。"
		return 1
	fi

	partial=0
	ds_try_optional droidspaces_devtmpfs "$MODDIR/kernel/droidspaces_devtmpfs.ko" devtmpfs 1 || partial=1
	ds_try_optional droidspaces_netfilter "$MODDIR/kernel/droidspaces_netfilter.ko" netfilter 0 || partial=1

	if [ "$partial" -ne 0 ]; then
		ds_status "[部分加载] namespace 已激活；devtmpfs / netfilter 有失败项，详见 load.log。"
	else
		ds_status "[已加载] PID / IPC namespace 已激活；devtmpfs/netfilter 按配置加载。更换 .ko 需重启。"
	fi
	return 0
}

ds_preflight() {
	if ! ds_verify_payloads; then
		return 1
	fi
	return 0
}

ds_collect_pstore() {
	[ -d /sys/fs/pstore ] || return 0
	ls /sys/fs/pstore/console-ramoops* >/dev/null 2>&1 || return 0
	d="$DS_PSTORE/$(date '+%Y%m%d-%H%M%S')"
	mkdir -p "$d" 2>/dev/null || return 0
	for f in /sys/fs/pstore/*; do
		[ -f "$f" ] || continue
		cp "$f" "$d/$(basename "$f")" 2>/dev/null
	done
	ds_log "pstore saved: $d"
	ls -1dt "$DS_PSTORE"/* 2>/dev/null | tail -n +4 | while IFS= read -r old; do
		rm -rf "$old" 2>/dev/null
	done
}

ds_boot_reason() {
	v=$(getprop ro.boot.bootreason 2>/dev/null | tr -d '\r')
	[ -n "$v" ] && { printf '%s\n' "$v"; return; }
	cat /proc/cmdline 2>/dev/null | tr ' ' '\n' \
		| sed -n 's/^androidboot.bootreason=//p' | tail -n 1
}

ds_boot() {
	ds_collect_pstore

	br=$(ds_boot_reason)
	[ -n "$br" ] && printf '%s\n' "$br" > "$DS_LASTBR" 2>/dev/null
	case "$br" in
	*watchdog* | *kernel_panic* | *panic*)
		cnt=$(cat "$DS_CRASH" 2>/dev/null | tr -dc '0-9')
		[ -z "$cnt" ] && cnt=0
		cnt=$((cnt + 1))
		printf '%s\n' "$cnt" > "$DS_CRASH" 2>/dev/null
		ds_log "bootreason=$br crash_count=$cnt"
		if [ "$cnt" -ge 2 ]; then
			: > "$DS_BLOCKED" 2>/dev/null
			ds_log 'crash_count>=2 -> blocked'
		fi
		;;
	esac

	if [ ! -f "$DS_AUTO" ]; then
		ds_log "auto off (touch $DS_AUTO to enable)"
		ds_status '[待加载] 本次开机尚未加载；验证稳定后 touch /data/adb/droidspaces_hummer/auto。'
		return 0
	fi
	if [ -f "$DS_BLOCKED" ]; then
		ds_log 'blocked'
		ds_status '[加载失败] 已 blocked；排查后执行 service.sh reset 再手动 load。'
		return 0
	fi
	if [ -f "$DS_MARK" ]; then
		mv -f "$DS_MARK" "$DS_BLOCKED" 2>/dev/null
		ds_status '[加载失败] 上次 insmod 未返回，已 blocked；请保存 pstore 后排查。'
		return 0
	fi
	if [ -f "$DS_PEND" ] && [ ! -f "$DS_OK" ]; then
		mv -f "$DS_PEND" "$DS_DATA/load.crash" 2>/dev/null
		: > "$DS_BLOCKED" 2>/dev/null
		ds_status '[加载失败] 上次加载后未存活，已 blocked；请保存 pstore 后排查。'
		return 0
	fi

	if ! ds_preflight; then
		ds_status "[不兼容] 预检失败；未加载。详见 load.log。"
		return 1
	fi

	: > "$DS_MARK" 2>/dev/null
	sync
	ds_load_all
	rc=$?
	rm -f "$DS_MARK" 2>/dev/null
	sync
	if [ "$rc" -ne 0 ]; then
		return "$rc"
	fi

	: > "$DS_PEND" 2>/dev/null
	sec=120
	[ -f "$DS_DATA/alive_sec" ] && sec=$(tr -dc '0-9' < "$DS_DATA/alive_sec")
	case "$sec" in '' | *[!0-9]*) sec=120 ;; esac
	[ "$sec" -gt 900 ] && sec=900
	ds_log "survival window ${sec}s"
	sleep "$sec"
	if [ -f "$DS_BLOCKED" ]; then
		rm -f "$DS_PEND" 2>/dev/null
		return 0
	fi
	: > "$DS_OK" 2>/dev/null
	rm -f "$DS_PEND" 2>/dev/null
	ds_log 'survival ok'
	return 0
}

ds_manual_load() {
	if [ -f "$DS_MARK" ]; then
		ds_log 'insmod marker present; run reset first'
		printf 'fail: marker present\n'
		return 1
	fi
	if ! ds_preflight; then
		printf 'fail: preflight\n'
		return 1
	fi
	: > "$DS_MARK" 2>/dev/null
	sync
	ds_load_all
	rc=$?
	rm -f "$DS_MARK" 2>/dev/null
	sync
	[ "$rc" -eq 0 ] && ds_log 'manual load ok' || ds_log "manual load failed rc=$rc"
	return "$rc"
}

ds_reset() {
	rm -f "$DS_BLOCKED" "$DS_MARK" "$DS_PEND" "$DS_CRASH" "$DS_OK" \
		"$DS_DATA/load.crash" 2>/dev/null
	ds_status '[待加载] 已清除 blocked / crash_count / boot_pending。'
}

ds_show_status() {
	printf 'version=%s\n' "$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'target=%s\n' "$(ds_build_release)"
	printf 'manager=%s\n' "$(if [ -d /data/adb/ksu ]; then echo KernelSU; elif [ -d /data/adb/ap ]; then echo APatch; elif [ -d /data/adb/magisk ]; then echo Magisk; else echo unknown; fi)"
	printf 'auto=%s\n' "$([ -f "$DS_AUTO" ] && echo 1 || echo 0)"
	printf 'blocked=%s\n' "$([ -f "$DS_BLOCKED" ] && echo 1 || echo 0)"
	printf 'namespace=%s\n' "$([ -d "$DS_MODULE_SYS" ] && echo present || echo absent)"
	printf 'active=%s\n' "$(ds_active && echo 1 || echo 0)"
	printf 'devtmpfs_ko=%s\n' "$([ -f "$MODDIR/kernel/droidspaces_devtmpfs.ko" ] && echo 1 || echo 0)"
	printf 'netfilter_ko=%s\n' "$([ -f "$MODDIR/kernel/droidspaces_netfilter.ko" ] && echo 1 || echo 0)"
	printf 'userns_ko=%s\n' "$([ -f "$MODDIR/kernel/droidspaces_ns_userns.ko" ] && echo 1 || echo 0)"
	printf 'status=%s\n' "$(cat "$DS_STATUS" 2>/dev/null)"
}
