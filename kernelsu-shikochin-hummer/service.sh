#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 用法：
#   sh service.sh            开机自动路径（需要 $DS_DATA/auto）
#   sh service.sh load       手动加载一次（绕过 auto / blocked）
#   sh service.sh status     查看状态
#   sh service.sh reset      清除 blocked / crash_count / boot_pending
#   sh service.sh unload     说明：已激活模块不能热卸载
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=$(pwd)
. "$MODDIR/common.sh"

MODE=${1:-${DSH_ACTION:-}}

case "$MODE" in
status)
	ds_show_status
	;;
load)
	ds_manual_load
	;;
reset)
	ds_reset
	;;
unload|remove)
	ds_status '[已加载] 已激活的内核模块不能热卸载；请禁用模块后重启。'
	exit 1
	;;
'' | boot)
	{
		printf 'Droidspaces hummer: %s\n' "$(date -u)"
		printf 'Kernel: %s\n' "$(uname -r)"
		printf 'Boot: %s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
	} >> "$DS_LOG" 2>/dev/null
	ds_boot
	;;
*)
	echo "unknown action: $MODE" >&2
	exit 2
	;;
esac
