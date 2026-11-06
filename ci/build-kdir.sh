#!/bin/bash
# 在 DDK 容器里用“目标机器真实 config + 原厂 clang r596125”编出 KDIR。
# KDIR = /work/kernel/out，后面编 LKM 时直接用它。
set -euxo pipefail

if [ "${USE_STOCK_CLANG:-0}" != "1" ]; then
  echo "::error::必须设置 USE_STOCK_CLANG=1，拒绝用 DDK r510928 编 KDIR"
  exit 1
fi
if [ ! -x /work/clang-stock/bin/clang ]; then
  echo "::error::/work/clang-stock/bin/clang 不存在"
  exit 1
fi
export PATH="/work/clang-stock/bin:$PATH"
clang --version | head -n1
clang --version | grep -q 'r596125' || {
  echo "::error::当前 clang 不是原厂 r596125"
  exit 1
}
echo "==> clang: stock r596125"

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

# 上游 modules 源码里有 #include "../../../../../../../sm8750/drivers/ufs/..."
# LineageOS 的目录名是 kernel/oneplus/sm8750；这里内核检出在 /work/kernel，
# 所以补一个 /work/sm8750 -> kernel 的符号链接。
cd /work
if [ ! -e /work/sm8750 ]; then
  ln -s kernel /work/sm8750
fi

cd /work/kernel
mkdir -p out

if [ ! -s /work/config/hummer_config.gz ]; then
  echo "::error::/work/config/hummer_config.gz 不存在"
  exit 1
fi
zcat /work/config/hummer_config.gz > out/.config
echo "==> baseline config: $(grep -c '^CONFIG_' out/.config) lines"

make O=out olddefconfig

echo "==> key config"
grep -E '^CONFIG_(LOCALVERSION|LOCALVERSION_AUTO|CFI_CLANG|MODVERSIONS|MODULES|MODULE_SIG_FORCE|SMP|PREEMPT)' out/.config || true

# Image 生成 vmlinux / System.map；modules 生成 Module.symvers（外部模块需要）
ccache_arg=()
if command -v ccache >/dev/null 2>&1; then
  echo "==> ccache: $(ccache --version | head -n1)"
  ccache_arg=(CC="ccache clang")
fi
make O=out -j"$(nproc)" KERNELRELEASE="$KERNELRELEASE" "${ccache_arg[@]}" Image modules

test -s out/Module.symvers
test -s out/System.map
grep -q "$KERNELRELEASE" out/include/generated/utsrelease.h
grep -a -q "Linux version $KERNELRELEASE" out/arch/arm64/boot/Image

echo "==> KDIR ready"
ls -lh out/arch/arm64/boot/Image out/Module.symvers out/System.map
