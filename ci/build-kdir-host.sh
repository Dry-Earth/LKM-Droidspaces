#!/bin/bash
# Build the exact KDIR on the runner, using only the tool projects pinned by the
# OTA build-manifest.xml (placed under $TOOLS by ci/fetch-manifest-tools.sh).
set -euxo pipefail

ROOT=${ROOT:-$PWD}
TOOLS=${TOOLS:-$ROOT/tools}

export PATH="$TOOLS/clang/bin:$TOOLS/build-tools/bin:$TOOLS/kernel-build-tools/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLS/build-tools/lib64:$TOOLS/kernel-build-tools/lib64:${LD_LIBRARY_PATH:-}"
export BISON_PKGDATADIR="$TOOLS/build-tools/common/bison"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

EXPECTED_CLANG=${EXPECTED_CLANG:-r596125}
clang --version | head -n1
clang --version | grep -q "$EXPECTED_CLANG" || {
	echo "::error::clang does not match $EXPECTED_CLANG"
	exit 1
}

cd "$ROOT"
[ -e sm8750 ] || ln -s kernel sm8750

cd kernel
mkdir -p out

if [ -s "$ROOT/build-config/stock.config" ]; then
	echo "==> baseline config: extracted from boot.img"
	cp "$ROOT/build-config/stock.config" out/.config
elif [ -s "$ROOT/config/hummer_config.gz" ]; then
	echo "==> baseline config: config/hummer_config.gz"
	zcat "$ROOT/config/hummer_config.gz" > out/.config
else
	echo "::error::no config (build-config/stock.config or config/hummer_config.gz)"
	exit 1
fi
echo "==> baseline config: $(grep -c '^CONFIG_' out/.config) lines"

make O=out olddefconfig

echo "==> key config"
grep -E '^CONFIG_(LOCALVERSION|LOCALVERSION_AUTO|CFI_CLANG|MODVERSIONS|MODULES|MODULE_SIG_FORCE|SMP|PREEMPT)' out/.config || true

ccache_arg=()
if command -v ccache >/dev/null 2>&1; then
	echo "==> ccache: $(ccache --version | head -n1)"
	ccache_arg=(CC="ccache clang")
fi

make O=out -j"$(nproc)" KERNELRELEASE="$KERNELRELEASE" "${ccache_arg[@]}" Image modules

test -s out/Module.symvers
test -s out/System.map
test -s out/arch/arm64/boot/Image
grep -q "$KERNELRELEASE" out/include/generated/utsrelease.h
grep -a -q "Linux version $KERNELRELEASE" out/arch/arm64/boot/Image

echo "==> KDIR ready: $ROOT/kernel/out"
