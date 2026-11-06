#!/bin/bash
# 按上游 9f65632 的布局打包：module/ + bin/<KMI>/*.ko
set -euxo pipefail

KMI=${KMI:-android15-6.6}
VER=$(awk -F= '$1=="version"{print $2; exit}' module/module.prop)
OUT="$(pwd)/dist/phDroid-${VER}.zip"
STAGE="$(pwd)/build/stage"

rm -rf "$STAGE"
mkdir -p "$STAGE/bin/$KMI" "$(dirname "$OUT")"
cp -a module/. "$STAGE/"
cp out/"$KMI"/*.ko "$STAGE/bin/$KMI/"

test -s "$STAGE/bin/$KMI/droid_lkm.ko"
test -s "$STAGE/module.prop"
test -s "$STAGE/config.conf"
test -s "$STAGE/service.sh"
test -s "$STAGE/build-id.txt"

(cd "$STAGE" && zip -qr9 "$OUT" .)
ls -lh "$OUT"
unzip -l "$OUT" | sed -n '1,60p'
