#!/bin/bash
# 把上游 9f65632 的 module/ 改成 hummer 专用，并写入 build-id。
set -euxo pipefail

SAFE=${SAFE_MODE:-false}
if [ "$SAFE" = "true" ]; then
  modules="droid_lkm"
  suffix="-safe"
else
  modules="droid_lkm droid_lkm_vendor"
  suffix=""
fi

cat > module/config.conf <<EOF
modules=${modules}
kmi_override=android15-6.6
EOF

cfg_sha=$(sha256sum config/hummer_config.gz 2>/dev/null | awk '{print $1}')
cat > module/build-id.txt <<EOF
release=${EXPECTED_RELEASE:-6.6.144-4k-g6350e8af3f4c}
kernel_sha=${KERNEL_SHA:-6350e8af3f4c452d087fbd6fe1aabe03cbc0af75}
clang=${CLANG_REV:-clang-r596125}
config_sha256=${cfg_sha}
EOF

sed -i \
  -e 's/^id=.*/id=phdroid/' \
  -e 's/^name=.*/name=phDroid hummer (LineageOS 24)/' \
  -e "s/^version=.*/version=v2.0.0-hummer${suffix}/" \
  -e 's/^versionCode=.*/versionCode=7/' \
  -e 's/^author=.*/author=Dere3046 XiYueSauce/' \
  -e 's|^description=.*|description=phDroid for OnePlus Ace 5 Pro (hummer) / LineageOS 24 / 6.6.144. Upstream 9f65632 (fix panic / fix pid cache), exact KDIR + stock clang r596125. 默认不自动加载；先手动 load 验证。|' \
  module/module.prop

echo "==> config.conf"
cat module/config.conf
echo "==> module.prop"
cat module/module.prop
echo "==> build-id"
cat module/build-id.txt
