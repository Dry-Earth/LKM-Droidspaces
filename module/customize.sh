#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 dere3046
# hummer fork: KMI fallback for kernels without androidNN in uname -r

SKIPUNZIP=1

DATA=${DATA:-/data/adb/phdroid}

command -v ui_print >/dev/null || ui_print() { echo "$1"; }
command -v abort >/dev/null || abort() { ui_print "$1"; exit 1; }

require_arm64() {
    [ "$ARCH" = arm64 ] || [ "$(uname -m)" = aarch64 ] || abort "! arm64 only"
}

detect_kmi() {
    local release ver tag
    release=$(uname -r)
    ver=$(printf '%s' "$release" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
    tag=$(printf '%s' "$release" | sed -n 's/.*\(android[0-9][0-9]*\).*/\1/p')
    [ -n "$ver" ] && [ -n "$tag" ] && echo "$tag-$ver"
}

unpack_static() {
    unzip -o "$ZIPFILE" module.prop config.conf service.sh uninstall.sh build-id.txt \
        -d "$MODPATH" >&2 || abort "! unpack failed"
}

unpack_build() {
    mkdir -p "$MODPATH/bin"
    unzip -o "$ZIPFILE" "bin/$1/*" -d "$MODPATH" >&2 || abort "! unpack $1 failed"
    [ -d "$MODPATH/bin/$1" ] || abort "! no build for $1"
}

chmod_module() {
    chmod 0755 "$MODPATH" "$MODPATH/bin" "$MODPATH"/*.sh
    chmod 0644 "$MODPATH"/module.prop "$MODPATH"/config.conf "$MODPATH"/build-id.txt
    find "$MODPATH"/bin -name '*.ko' -exec chmod 0644 {} \;
}

main() {
    local kmi
    require_arm64
    unpack_static

    kmi=$(detect_kmi)
    if [ -z "$kmi" ]; then
        kmi=$(sed -n 's/^kmi_override=//p' "$MODPATH/config.conf" 2>/dev/null | head -n 1 | tr -d '\r')
        [ -n "$kmi" ] && ui_print "- kmi fallback: $kmi"
    fi
    [ -n "$kmi" ] || abort "! cannot detect KMI from $(uname -r); set kmi_override in config.conf"
    unpack_build "$kmi"

    mkdir -p "$DATA"
    # 默认不自动加载；首次安装强制手动 load
    rm -f "$DATA/blocked" "$DATA/insmod" "$DATA/auto" "$DATA/crash_count" \
        "$DATA/boot_pending" "$DATA/.boot_ok" "$DATA/last_bootreason"

    chmod_module
    ui_print "- payload: $(ls "$MODPATH/bin/$kmi" | tr '\n' ' ')"
    ui_print "- auto: off (touch $DATA/auto after manual verification)"
}

main
