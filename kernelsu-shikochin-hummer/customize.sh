#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 安装时检查：只允许装到目标内核，且不能和 phDroid 同时启用。
# 首次安装不会自动加载；验证稳定后手动 touch auto 才会开机加载。

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
command -v abort >/dev/null 2>&1 || abort() { ui_print "$1"; exit 1; }

MODDIR=$MODPATH
if [ -z "$MODDIR" ]; then
	MODDIR=$(dirname "$0")
	MODDIR=$(cd "$MODDIR" && pwd)
fi
. "$MODDIR/common.sh"

[ "$(uname -m)" = aarch64 ] || abort '! 只支持 ARM64 设备'
[ -x "$DS_KSUD" ] || abort '! 未找到 ksud；请使用 KernelSU / KernelSU Next / SUKISU'
"$DS_KSUD" insmod --help >/dev/null 2>&1 || abort '! 当前 ksud 不支持 insmod'

if [ -d /data/adb/modules/phdroid ] && [ ! -f /data/adb/modules/phdroid/disable ]; then
	abort '! 检测到已启用的 phDroid。两套 PID/IPC namespace 钩子不能共存：请先在 KernelSU 里停用 phDroid 并重启，再安装本模块。'
fi
if [ -d /data/adb/modules/droidspaces_lkm ] && [ ! -f /data/adb/modules/droidspaces_lkm/disable ]; then
	abort '! 检测到已启用的 Shikochin droidspaces_lkm。请先停用它并重启，再安装本模块，避免两套 droidspaces_ns 冲突。'
fi

want=$(ds_build_release)
rel=$(uname -r)
[ -n "$want" ] || abort '! build-id.txt 缺少 release'
[ "$rel" = "$want" ] || abort "! 内核不匹配：当前 $rel，本包只支持 $want"

ds_verify_payloads || abort '! 载荷 SHA-256 或 vermagic 校验失败；请重新下载完整 ZIP'

# 安装时清掉旧状态，强制先手动验证。
rm -f "$DS_AUTO" "$DS_BLOCKED" "$DS_MARK" "$DS_PEND" "$DS_CRASH" \
	"$DS_OK" "$DS_DATA/load.crash" 2>/dev/null

if command -v set_perm_recursive >/dev/null 2>&1; then
	set_perm_recursive "$MODPATH" 0 0 0755 0644
	set_perm "$MODPATH/service.sh" 0 0 0755
	set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
	set_perm "$MODPATH/customize.sh" 0 0 0755
	set_perm "$MODPATH/META-INF/com/google/android/update-binary" 0 0 0755 2>/dev/null
else
	chmod 0755 "$MODPATH"/*.sh 2>/dev/null
	chmod 0644 "$MODPATH"/*.conf "$MODPATH"/module.prop "$MODPATH"/kernel/* 2>/dev/null
fi

ui_print '- 目标内核：'"$want"
payloads=$(cat "$MODPATH/kernel/manifest.txt" 2>/dev/null | tr '\n' ' ')
ui_print "- 载荷：$payloads"
ui_print '- 默认不自动加载：先执行 service.sh load 验证'
ui_print '- 稳定后：touch /data/adb/droidspaces_hummer/auto'
ui_print '- 已激活的 .ko 需重启才能移除'
