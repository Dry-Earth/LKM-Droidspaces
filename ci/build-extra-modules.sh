#!/bin/bash
# Build the extra modules for the "check green" phDroid package.
#
# Runs inside the DDK container against the exact KDIR that phDroid was built
# with, so every .ko carries the same vermagic:
#
#   devtmpfs_lkm     <- extra/devtmpfs      (registers devtmpfs)
#   ip6table_nat     <- extra/net_ip6nat    (IPv6 NAT)
#   macvlan          <- target kernel tree  (drivers/net/macvlan.c)
#   droid_lkm_pids   <- extra/cgrouplimits  (cgroup pids controller)
#   droid_lkm_cpu    <- extra/cgrouplimits  (cpu.max time slicing)
#
# Sources come from the extra-module checkout (default Dry-Earth/droidspaces-lkm),
# pinned by EXTRAS_SHA in the workflow.
set -euxo pipefail

KDIR=${KDIR:?KDIR is required}
KSRC=${KSRC:-/work/kernel}
EXTRAS=${EXTRAS:?EXTRAS is required}
OUT=${OUT:?OUT is required}
NPROC=$(nproc 2>/dev/null || echo 4)

test -s "$KDIR/Module.symvers"
test -d "$KSRC/drivers/net"
test -d "$EXTRAS/extra/devtmpfs"
test -d "$EXTRAS/extra/net_ip6nat"
test -d "$EXTRAS/extra/cgrouplimits"

mkdir -p "$OUT"
export KBUILD_MODPOST_WARN=1

clean_dir() {
	local d=$1
	find "$d" -name '*.o' -delete 2>/dev/null || true
	find "$d" -name '.*.cmd' -delete 2>/dev/null || true
	find "$d" -name '*.ko' -delete 2>/dev/null || true
	find "$d" -name '*.mod' -delete 2>/dev/null || true
	rm -f "$d/modules.order" "$d/Module.symvers" 2>/dev/null || true
}

# --- devtmpfs -------------------------------------------------------------
clean_dir "$EXTRAS/extra/devtmpfs"
make -C "$KDIR" M="$EXTRAS/extra/devtmpfs" modules -j"$NPROC"
install -m 644 "$EXTRAS/extra/devtmpfs/devtmpfs_lkm.ko" "$OUT/devtmpfs_lkm.ko"

# --- IPv6 NAT -------------------------------------------------------------
clean_dir "$EXTRAS/extra/net_ip6nat"
make -C "$KDIR" M="$EXTRAS/extra/net_ip6nat" modules -j"$NPROC"
install -m 644 "$EXTRAS/extra/net_ip6nat/ip6table_nat.ko" "$OUT/ip6table_nat.ko"

# --- macvlan (kernel tree source, CONFIG_MACVLAN is off in the vendor config)
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

# --- pids / cpu limits ----------------------------------------------------
for m in pids cpu; do
	clean_dir "$EXTRAS/extra/cgrouplimits"
	make -C "$KDIR" M="$EXTRAS/extra/cgrouplimits" MODULE="droid_lkm_$m" modules -j"$NPROC"
	install -m 644 "$EXTRAS/extra/cgrouplimits/droid_lkm_$m.ko" "$OUT/droid_lkm_$m.ko"
done
clean_dir "$EXTRAS/extra/cgrouplimits"

echo "==> extra modules"
ls -lh "$OUT"
for k in "$OUT"/*.ko; do
	printf '%s: ' "$k"
	strings "$k" | grep -m1 'vermagic=' || true
done
