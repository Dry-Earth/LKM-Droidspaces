#!/bin/bash
# Fetch exactly the tool projects pinned by the OTA build-manifest.xml.
# Every URL below is android.googlesource.com + the manifest revision; nothing
# comes from a third-party container or a hand-built toolchain.
#
# ONLY=mkbootimg fetches just the AOSP unpack_bootimg.py, which is needed before
# the kernel release / clang revision can be read from the boot image.
set -euxo pipefail

ROOT=${ROOT:-$PWD}
TOOLS=${TOOLS:-$ROOT/tools}
BASE=https://android.googlesource.com

: "${MKBOOTIMG_SHA:?MKBOOTIMG_SHA required}"

mkdir -p "$TOOLS"

fetch_tree() { # repo sha path dest
	local repo=$1 sha=$2 path=$3 dest=$4
	mkdir -p "$dest"
	curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
		--connect-timeout 20 \
		"$BASE/$repo/+archive/$sha/$path.tar.gz" | tar -xz -C "$dest"
}

fetch_file() { # repo sha file dest
	local repo=$1 sha=$2 file=$3 dest=$4
	curl -fL --retry 5 --retry-all-errors --retry-delay 2 \
		--connect-timeout 20 \
		"$BASE/$repo/+/$sha/$file?format=TEXT" | base64 -d > "$dest"
}

fetch_mkbootimg() {
	echo "==> system/tools/mkbootimg $MKBOOTIMG_SHA"
	mkdir -p "$TOOLS/mkbootimg"
	fetch_file platform/system/tools/mkbootimg "$MKBOOTIMG_SHA" unpack_bootimg.py \
		"$TOOLS/mkbootimg/unpack_bootimg.py"
	fetch_file platform/system/tools/mkbootimg "$MKBOOTIMG_SHA" bootimg.py \
		"$TOOLS/mkbootimg/bootimg.py" || true
}

if [ "${ONLY:-}" = "mkbootimg" ]; then
	fetch_mkbootimg
	ls -l "$TOOLS/mkbootimg"
	exit 0
fi

: "${CLANG_PROJECT_SHA:?CLANG_PROJECT_SHA required}"
: "${BUILDTOOLS_SHA:?BUILDTOOLS_SHA required}"

echo "==> clang $CLANG_PROJECT_SHA (${CLANG_REV:-clang-r596125})"
fetch_tree platform/prebuilts/clang/host/linux-x86 "$CLANG_PROJECT_SHA" \
	"${CLANG_REV:-clang-r596125}" "$TOOLS/clang"

echo "==> prebuilts/build-tools $BUILDTOOLS_SHA"
fetch_tree platform/prebuilts/build-tools "$BUILDTOOLS_SHA" linux-x86 "$TOOLS/build-tools"
# bison in linux-x86/bin was built with pkgsdatadir=/nonexistent/common/bison;
# its m4 macros and skeletons ship separately under common/bison.
mkdir -p "$TOOLS/build-tools/common/bison"
curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 20 \
	"$BASE/platform/prebuilts/build-tools/+archive/$BUILDTOOLS_SHA/common/bison.tar.gz" \
	| tar -xz -C "$TOOLS/build-tools/common/bison"

if [ -n "${KERNEL_BUILDTOOLS_SHA:-}" ]; then
	echo "==> kernel/prebuilts/build-tools $KERNEL_BUILDTOOLS_SHA"
	fetch_tree kernel/prebuilts/build-tools "$KERNEL_BUILDTOOLS_SHA" linux-x86 \
		"$TOOLS/kernel-build-tools" || echo "::warning::kernel-build-tools archive unavailable"
fi

fetch_mkbootimg

echo "==> tool versions"
"$TOOLS/clang/bin/clang" --version | head -n1
"$TOOLS/build-tools/bin/make" --version | head -n1 || true
for p in "$TOOLS/kernel-build-tools/bin/pahole" "$TOOLS/build-tools/bin/pahole"; do
	[ -x "$p" ] && "$p" --version && break
done || true
ls -l "$TOOLS/mkbootimg"
