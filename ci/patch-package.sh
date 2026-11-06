#!/bin/bash
# 把 phDroid 包改成 hummer / LineageOS 24 / 6.6.144 专用。
set -euxo pipefail

SAFE=${SAFE_MODE:-false}
CONF=module/config.conf

conf_set() {
  k=$1; v=$2
  awk -F= -v k="$k" -v v="$v" '
    BEGIN { done = 0 }
    $1 == k { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$CONF" > "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
}

conf_set kmi android15-6.6
conf_set kmi_override android15-6.6
conf_set oplus 1
conf_set compat on
conf_set skip_sysvipc 0
conf_set no_fake_ns 0
conf_set skip_do_exit 0
conf_set mqueue 1
conf_set nspid 1
conf_set nspid_append 1
conf_set verbose 0

# 构建指纹：service.sh 用它拒绝 OTA 后内核不匹配的加载
cfg_sha=$(sha256sum config/hummer_config.gz 2>/dev/null | awk '{print $1}')
cat > module/build-id.txt <<EOF
release=${EXPECTED_RELEASE:-6.6.144-4k-g6350e8af3f4c}
kernel_sha=${KERNEL_SHA:-6350e8af3f4c452d087fbd6fe1aabe03cbc0af75}
clang=${CLANG_REV:-clang-r596125}
config_sha256=${cfg_sha}
EOF
echo "==> build-id"
cat module/build-id.txt

suffix=""
if [ "$SAFE" = "true" ]; then
  # 安全模式：先不挂 do_exit kprobe，也不加载 OPPO vendor 模块。
  # 用来判断关机是发生在 ns 退出路径还是 vendor 钩子。
  conf_set skip_do_exit 1
  conf_set compat off
  suffix="-safe"
fi

sed -i \
  -e 's/^id=.*/id=phdroid/' \
  -e 's/^name=.*/name=phDroid hummer (LineageOS 24)/' \
  -e "s/^version=.*/version=v1.0.4-hummer${suffix}/" \
  -e 's|^description=.*|description=phDroid for OnePlus Ace 5 Pro (hummer) / LineageOS 24 / 6.6.144-4k-g6350e8af3f4c. LKM: PID/IPC/SYSVIPC/mqueue. 源构建于精确 KDIR + 原厂 clang r596125.|' \
  module/module.prop

echo "==> config"
cat "$CONF"
echo "==> module.prop"
cat module/module.prop
