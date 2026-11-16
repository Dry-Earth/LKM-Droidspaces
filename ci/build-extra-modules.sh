#!/bin/bash
# Build the extra modules the stock kernel is missing.
#
# The target config is read from the stock boot.img. A module is built only when
# the CONFIG it stands in for is not already provided by the kernel: a config
# line of the form CONFIG_X=y (or =m) means the feature is already there, so the
# module is skipped instead of risking a duplicate registration.
#
#   devtmpfs_lkm     <- extra/devtmpfs      when CONFIG_DEVTMPFS is off
#   ip6table_nat     <- extra/net_ip6nat    when CONFIG_IP6_NF_NAT or
#                                              CONFIG_IP6_NF_TARGET_MASQUERADE is off
#   macvlan          <- target kernel tree  when CONFIG_MACVLAN is off
#   droid_lkm_pids   <- extra/cgrouplimits  when CONFIG_CGROUP_PIDS is off
#   droid_lkm_cpu    <- extra/cgrouplimits  when CONFIG_CFS_BANDWIDTH is off
#
# The names that were built are written to $OUT/extra-modules.list, and the
# packaging step appends only those to config.conf.
set -euxo pipefail

KDIR=${KDIR:?KDIR is required}
KSRC=${KSRC:-/work/kernel}
EXTRAS=${EXTRAS:?EXTRAS is required}
OUT=${OUT:?OUT is required}
STOCK_CONFIG=${STOCK_CONFIG:-/work/build-config/stock.config}
NPROC=$(nproc 2>/dev/null || echo 4)

# The KDIR was built with the toolchain staged by the workflow. An external
# module must use the same compiler or the kernel headers fail on attributes the
# other clang does not know (__counted_by with clang 18, for example).
if [ -n "${CLANG_DIR:-}" ] && [ -x "$CLANG_DIR/bin/clang" ]; then
	export PATH="$CLANG_DIR/bin:$PATH"
elif [ -x /work/clang-stock/bin/clang ]; then
	export PATH="/work/clang-stock/bin:$PATH"
fi
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
clang --version | head -n1
if [ -n "${EXPECTED_CLANG:-}" ]; then
	clang --version | grep -q "$EXPECTED_CLANG" || {
		echo "::error::clang does not match $EXPECTED_CLANG"
		exit 1
	}
fi

if [ ! -s "$STOCK_CONFIG" ]; then
	if [ -s "$KDIR/.config" ]; then
		STOCK_CONFIG="$KDIR/.config"
	else
		echo "::error::no stock config to decide what is missing"
		exit 1
	fi
fi

test -s "$KDIR/Module.symvers"
test -d "$EXTRAS/extra/devtmpfs"
test -d "$EXTRAS/extra/net_ip6nat"
test -d "$EXTRAS/extra/cgrouplimits"

mkdir -p "$OUT"
LIST="$OUT/extra-modules.list"
: > "$LIST"
export KBUILD_MODPOST_WARN=1

cfg_on() {
	grep -qE "^$1=(y|m)$" "$STOCK_CONFIG"
}

keep() {
	echo "$1" >> "$LIST"
}

clean_dir() {
	local d=$1
	find "$d" -name '*.o' -delete 2>/dev/null || true
	find "$d" -name '.*.cmd' -delete 2>/dev/null || true
	find "$d" -name '*.ko' -delete 2>/dev/null || true
	find "$d" -name '*.mod' -delete 2>/dev/null || true
	rm -f "$d/modules.order" "$d/Module.symvers" 2>/dev/null || true
}

# --- devtmpfs -------------------------------------------------------------
if cfg_on CONFIG_DEVTMPFS; then
	echo "==> skip devtmpfs_lkm: CONFIG_DEVTMPFS is already enabled"
else
	clean_dir "$EXTRAS/extra/devtmpfs"
	make -C "$KDIR" M="$EXTRAS/extra/devtmpfs" modules -j"$NPROC"
	install -m 644 "$EXTRAS/extra/devtmpfs/devtmpfs_lkm.ko" "$OUT/devtmpfs_lkm.ko"
	keep devtmpfs_lkm
fi

# --- IPv6 NAT -------------------------------------------------------------
if cfg_on CONFIG_IP6_NF_NAT && cfg_on CONFIG_IP6_NF_TARGET_MASQUERADE; then
	echo "==> skip ip6table_nat: the IPv6 nat table is already provided"
else
	clean_dir "$EXTRAS/extra/net_ip6nat"
	make -C "$KDIR" M="$EXTRAS/extra/net_ip6nat" modules -j"$NPROC"
	install -m 644 "$EXTRAS/extra/net_ip6nat/ip6table_nat.ko" "$OUT/ip6table_nat.ko"
	keep ip6table_nat
fi

# --- macvlan --------------------------------------------------------------
if cfg_on CONFIG_MACVLAN; then
	echo "==> skip macvlan: CONFIG_MACVLAN is already enabled"
else
	MACDIR=/tmp/mod-macvlan
	rm -rf "$MACDIR"
	mkdir -p "$MACDIR"
	cp "$KSRC/drivers/net/macvlan.c" "$MACDIR/"
	cat > "$MACDIR/Makefile" <<'EOF'
obj-m := macvlan.o
ccflags-y += -DCONFIG_MACVLAN=1
EOF
	make -C "$KDIR" M="$MACDIR" modules -j"$NPROC"
	install -m 644 "$MACDIR/macvlan.ko" "$OUT/macvlan.ko"
	keep macvlan
fi

# --- pids / cpu limits ----------------------------------------------------
if cfg_on CONFIG_CGROUP_PIDS; then
	echo "==> skip droid_lkm_pids: CONFIG_CGROUP_PIDS is already enabled"
else
	clean_dir "$EXTRAS/extra/cgrouplimits"
	make -C "$KDIR" M="$EXTRAS/extra/cgrouplimits" MODULE=droid_lkm_pids modules -j"$NPROC"
	install -m 644 "$EXTRAS/extra/cgrouplimits/droid_lkm_pids.ko" "$OUT/droid_lkm_pids.ko"
	keep droid_lkm_pids
fi

if cfg_on CONFIG_CFS_BANDWIDTH; then
	echo "==> skip droid_lkm_cpu: CONFIG_CFS_BANDWIDTH is already enabled"
else
	clean_dir "$EXTRAS/extra/cgrouplimits"
	make -C "$KDIR" M="$EXTRAS/extra/cgrouplimits" MODULE=droid_lkm_cpu modules -j"$NPROC"
	install -m 644 "$EXTRAS/extra/cgrouplimits/droid_lkm_cpu.ko" "$OUT/droid_lkm_cpu.ko"
	keep droid_lkm_cpu
fi
clean_dir "$EXTRAS/extra/cgrouplimits"

echo "==> extra modules built:"
cat "$LIST"
echo "==> .ko in $OUT:"
ls -lh "$OUT"
for k in "$OUT"/*.ko; do
	printf '%s: ' "$k"
	strings "$k" | grep -m1 'vermagic=' || true
done
