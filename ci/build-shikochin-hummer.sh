#!/bin/bash
# Build the vendored Shikochin/Droidspaces-LKM port for one exact hummer kernel.
#
# The namespace payload is mandatory.  devtmpfs, netfilter and the USER_NS
# variant are attempted independently and reported, because the upstream
# devtmpfs/netfilter/user-namespace sources were validated only on 6.12.
set -euo pipefail

SHIKOCHIN=${SHIKOCHIN:-/work/third_party/shikochin-lkm}
KDIR=${KDIR:-/work/kernel/out}
OUTROOT=${OUTROOT:-/work/out-shikochin}
HUMMER_RELEASE=${HUMMER_RELEASE:-6.6.144-4k-g6350e8af3f4c}
BUILD_DEVTMPFS=${BUILD_DEVTMPFS:-true}
BUILD_NETFILTER=${BUILD_NETFILTER:-false}
BUILD_USERNS=${BUILD_USERNS:-false}
JOBS=${JOBS:-$(nproc)}

# Must use the same compiler as the KDIR: r596125 knows __counted_by__,
# the DDK default r510928 does not (and -Werror turns it into a failure).
if [ "${USE_STOCK_CLANG:-1}" = "1" ] && [ -x /work/clang-stock/bin/clang ]; then
	export PATH="/work/clang-stock/bin:$PATH"
	echo "==> clang: stock $(clang --version | head -n1)"
else
	echo "==> clang: DDK $(clang --version | head -n1)"
fi

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
# The module deliberately calls internal helpers that vendor kernels do not
# export.  KernelSU's ksud relocates them at load time; keep modpost from
# turning those unresolved symbols into a build failure.
export KBUILD_MODPOST_WARN=1

test -d "$SHIKOCHIN/src/port66"
test -s "$KDIR/Module.symvers"
test -s "$KDIR/System.map"

mkdir -p "$OUTROOT/ko"
REPORT=$OUTROOT/build-report.txt
: > "$REPORT"

# name|status|sha256|vermagic
record() {
	name=$1 status=$2 ko=$3
	if [ -f "$ko" ]; then
		sha=$(sha256sum "$ko" | awk '{print $1}')
		vm=$(strings "$ko" | grep -m1 '^vermagic=' || true)
	else
		sha=-
		vm=-
	fi
	printf '%s|%s|%s|%s\n' "$name" "$status" "$sha" "$vm" >> "$REPORT"
}

build_one() {
	name=$1
	shift
	echo "==> build $name: $*" >&2
	make -C "$SHIKOCHIN" KDIR="$KDIR" OUT="$OUTROOT/$name" HUMMER=1 \
		HUMMER_RELEASE="$HUMMER_RELEASE" \
		-j"$JOBS" "$@"
}

# Mandatory: PID / IPC / SYSVIPC / POSIX mqueue namespace port.
build_one namespace TARGET=namespace PORT_DIR=src/port66 \
	GKI_ANDROID=android15 GKI_VERSION=6.6
cp "$OUTROOT/namespace/droidspaces_ns.ko" "$OUTROOT/ko/droidspaces_ns.ko"

# Optional: late devtmpfs (upstream device guard now accepts the exact release).
if [ "$BUILD_DEVTMPFS" = true ]; then
	if build_one devtmpfs TARGET=devtmpfs >"$OUTROOT/devtmpfs.log" 2>&1; then
		cp "$OUTROOT/devtmpfs/droidspaces_devtmpfs.ko" "$OUTROOT/ko/"
		record devtmpfs ok "$OUTROOT/ko/droidspaces_devtmpfs.ko"
	else
		echo "::warning::devtmpfs 构建失败，未打包；日志：$OUTROOT/devtmpfs.log" >&2
		tail -n 60 "$OUTROOT/devtmpfs.log" >&2 || true
		record devtmpfs failed ""
	fi
else
	record devtmpfs skipped ""
fi

# Optional: USER_NS live port.  Upstream only validates this on 6.12; keep it
# behind an explicit switch until a 6.6 device regression exists.
if [ "$BUILD_USERNS" = true ]; then
	if build_one userns TARGET=namespace PORT_DIR=src/port66 USERNS=1 \
		GKI_ANDROID=android15 GKI_VERSION=6.6 >"$OUTROOT/userns.log" 2>&1; then
		cp "$OUTROOT/userns/droidspaces_ns.ko" "$OUTROOT/ko/droidspaces_ns_userns.ko"
		record userns ok "$OUTROOT/ko/droidspaces_ns_userns.ko"
	else
		echo "::warning::USER_NS 变体在当前 6.6 源码上构建失败；未打包。" >&2
		tail -n 80 "$OUTROOT/userns.log" >&2 || true
		record userns failed ""
	fi
else
	record userns skipped ""
fi

# Optional: Docker nftables / xt_addrtype port.  Upstream carries a 6.12
# nf_tables snapshot, so this is expected to need a real 6.6 port.
if [ "$BUILD_NETFILTER" = true ]; then
	if build_one netfilter TARGET=netfilter >"$OUTROOT/netfilter.log" 2>&1; then
		cp "$OUTROOT/netfilter/droidspaces_netfilter.ko" "$OUTROOT/ko/"
		record netfilter ok "$OUTROOT/ko/droidspaces_netfilter.ko"
	else
		echo "::warning::netfilter 构建失败（上游为 6.12 快照），未打包。" >&2
		tail -n 80 "$OUTROOT/netfilter.log" >&2 || true
		record netfilter failed ""
	fi
else
	record netfilter skipped ""
fi

record namespace ok "$OUTROOT/ko/droidspaces_ns.ko"

# Hard stop if the mandatory payload does not target the requested kernel.
# Write strings to a file first: `strings | grep -q` can make strings die with
# SIGPIPE, which `set -o pipefail` turns into a false build failure.
NS_KO=$OUTROOT/ko/droidspaces_ns.ko
strings "$NS_KO" > "$OUTROOT/namespace.strings"
VM=$(grep -m1 '^vermagic=' "$OUTROOT/namespace.strings" || true)
case "$VM" in
	"vermagic=$HUMMER_RELEASE "*) ;;
	*)
		echo "::error::droidspaces_ns.ko vermagic 不包含 $HUMMER_RELEASE" >&2
		echo "$VM" >&2
		exit 1
		;;
esac
if ! grep -q 'parmtype=activate:bool' "$OUTROOT/namespace.strings"; then
	echo "::error::droidspaces_ns.ko 缺少 activate 参数" >&2
	exit 1
fi
if ! grep -q 'hummer profile:' "$OUTROOT/namespace.strings"; then
	echo "::error::HUMMER_RELEASE 没有编译进模块，运行时会被 release 检查拒绝" >&2
	exit 1
fi

echo "==> payloads"
ls -lh "$OUTROOT/ko"
echo "==> build report"
cat "$REPORT"
