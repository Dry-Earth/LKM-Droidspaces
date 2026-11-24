#!/bin/bash
# Host build of the phDroid LKM against the exact KDIR, using only the tools
# pinned by the OTA build-manifest.xml.
set -euxo pipefail

ROOT=${ROOT:-$PWD}
TOOLS=${TOOLS:-$ROOT/tools}

export PATH="$TOOLS/clang/bin:$TOOLS/build-tools/bin:$TOOLS/kernel-build-tools/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLS/build-tools/lib64:$TOOLS/kernel-build-tools/lib64:${LD_LIBRARY_PATH:-}"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

clang --version | head -n1
EXPECTED_CLANG=${EXPECTED_CLANG:-r596125}
clang --version | grep -q "$EXPECTED_CLANG" || {
	echo "::error::clang does not match expected $EXPECTED_CLANG"
	exit 1
}

KDIR=${KDIR:-$ROOT/kernel/out}
VER=${VER:-android15-6.6}
KERNELRELEASE=${KERNELRELEASE:-${EXPECTED_RELEASE:?KERNELRELEASE or EXPECTED_RELEASE required}}
NATIVE=${DROID_LKM_NATIVE_PID:-1}

test -s "$KDIR/Module.symvers"
test -s "$KDIR/System.map"
grep -m1 UTS_RELEASE "$KDIR/include/generated/utsrelease.h"

cd "$ROOT"

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
while read -r name rev; do
  case "$name" in ""|"#"*) continue ;; esac
  [ "$name" = "vendorcompat" ] && continue
  [ -n "$rev" ] || continue
  fetch "$name" "$rev"
done < "$ROOT"/deps.lst

# vendorcompat comes from the KMSDK revision pinned in .sdk-version
SDKREV=$(cat "$ROOT"/.sdk-version)
vc="https://raw.githubusercontent.com/Dere3046/KMSDK/$SDKREV/builtin/vendorcompat"
curl -fsSL "$vc/deps.mk" -o .sdk/builtin/vendorcompat/deps.mk
curl -fsSL "$vc/lib/vendorcompat.c" -o .sdk/builtin/vendorcompat/lib/vendorcompat.c
curl -fsSL "$vc/lib/vendorcompat.h" -o .sdk/builtin/vendorcompat/lib/vendorcompat.h
echo "==> build LKM (native=$NATIVE) against $KDIR"
ccache_arg=()
if command -v ccache >/dev/null 2>&1; then
	ccache_arg=(CC="ccache clang")
fi
make -C "$ROOT" KDIR="$KDIR" VER="$VER" KERNELRELEASE="$KERNELRELEASE" \
	DROID_LKM_NATIVE_PID="$NATIVE" "${ccache_arg[@]}" -j"$(nproc)"

echo "==> artifacts"
ls -lh "out/$VER"
for k in "out/$VER"/*.ko; do
	printf '%s: ' "$k"
	strings "$k" | grep -m1 'vermagic=' || echo 'vermagic not found'
done
test -s "out/$VER/droid_lkm.ko"
