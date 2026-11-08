#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
MODDIR=${0%/*}
. "$MODDIR/common.sh"

# 每次开机先重置简介；真正加载在 service.sh（late_start）里做。
mkdir -p "$DS_DATA" 2>/dev/null
ds_status '[待加载] 本次开机尚未加载；等待 service 阶段。'
