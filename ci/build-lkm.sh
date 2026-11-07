#!/bin/bash
# 用精确 6.6.144 KDIR + 原厂 clang r596125 编译上游 _patchHarmony 9f65632。
# 默认开启 native PID（fix panic / fix pid cache 的 native 路径）。
set -euxo pipefail

export PATH="/work/clang-stock/bin:$PATH"
clang --version | head -n1
EXPECTED_CLANG=${EXPECTED_CLANG:-r596125}
clang --version | grep -q "$EXPECTED_CLANG" || {
  echo "::error::clang does not match expected $EXPECTED_CLANG"
  exit 1
}

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

KDIR=${KDIR:-/work/kernel/out}
VER=${VER:-android15-6.6}
KERNELRELEASE=${KERNELRELEASE:?KERNELRELEASE required}
NATIVE=${DROID_LKM_NATIVE_PID:-1}

test -s "$KDIR/Module.symvers"
test -s "$KDIR/System.map"
grep -m1 UTS_RELEASE "$KDIR/include/generated/utsrelease.h"

cd /work

echo "==> fetch deps"
mkdir -p deps .sdk/builtin/vendorcompat/lib
fetch() {
  name=$1
  rev=$2
  rm -rf "deps/$name"
  git clone --filter=blob:none "https://github.com/Dere3046/$name" "deps/$name"
  git -C "deps/$name" fetch --depth 1 origin "$rev" 2>/dev/null || git -C "deps/$name" fetch origin
  git -C "deps/$name" checkout -q "$rev"
  echo "  $name @ $(git -C "deps/$name" rev-parse --short HEAD)"
}
fetch KallRecon b258fb6
fetch Type_info 7182dae
fetch KernCall  cdec722
fetch HooKern   7a02afa

base="https://raw.githubusercontent.com/ai-luo2006/droidspaces-6.12-pmb110/main/src/droid_lkm/.sdk/builtin/vendorcompat"
curl -fsSL "$base/deps.mk" -o .sdk/builtin/vendorcompat/deps.mk
curl -fsSL "$base/lib/vendorcompat.c" -o .sdk/builtin/vendorcompat/lib/vendorcompat.c
curl -fsSL "$base/lib/vendorcompat.h" -o .sdk/builtin/vendorcompat/lib/vendorcompat.h

echo "==> build LKM (native=$NATIVE) against $KDIR"
ccache_arg=()
if command -v ccache >/dev/null 2>&1; then
  ccache_arg=(CC="ccache clang")
fi
make -C /work KDIR="$KDIR" VER="$VER" KERNELRELEASE="$KERNELRELEASE" \
  DROID_LKM_NATIVE_PID="$NATIVE" "${ccache_arg[@]}" -j"$(nproc)"

echo "==> artifacts"
ls -lh "out/$VER"
for k in "out/$VER"/*.ko; do
  printf '%s: ' "$k"
  strings "$k" | grep -m1 'vermagic=' || echo 'vermagic not found'
done
test -s "out/$VER/droid_lkm.ko"
