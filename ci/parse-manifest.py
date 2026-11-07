#!/usr/bin/env python3
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 2:
    print("usage: parse-manifest.py <build-manifest.xml>", file=sys.stderr)
    sys.exit(2)

root = ET.parse(sys.argv[1]).getroot()
projects = []
for p in root.iter("project"):
    projects.append({
        "name": p.get("name") or "",
        "path": p.get("path") or "",
        "revision": p.get("revision") or "",
        "upstream": p.get("upstream") or "",
    })

def find(name=None, path_kw=None):
    for p in projects:
        if name and p["name"] == name:
            return p
        if path_kw and path_kw in p["path"]:
            return p
    return None

kernel = find("LineageOS/android_kernel_oneplus_sm8750", "kernel/oneplus/sm8750") \
    or find(path_kw="kernel/oneplus/sm8750")
modules = find("LineageOS/android_kernel_oneplus_sm8750-modules", "kernel/oneplus/sm8750-modules") \
    or find(path_kw="sm8750-modules")
devicetrees = find("LineageOS/android_kernel_oneplus_sm8750-devicetrees", "kernel/oneplus/sm8750-devicetrees") \
    or find(path_kw="sm8750-devicetrees")
clang = find("platform/prebuilts/clang/host/linux-x86", "prebuilts/clang/host/linux-x86") \
    or find(path_kw="prebuilts/clang/host/linux-x86")

def out(key, p):
    if not p or not p["revision"]:
        print(f"::error::cannot find {key} in manifest", file=sys.stderr)
        sys.exit(1)
    print(f"{key}={p['revision']}")
    print(f"{key}_NAME={p['name']}")
    print(f"{key}_PATH={p['path']}")

print(f"MANIFEST_PROJECTS={len(projects)}")
out("KERNEL_SHA", kernel)
out("MODULES_SHA", modules)
if devicetrees and devicetrees["revision"]:
    print(f"DEVICETREES_SHA={devicetrees['revision']}")
if clang and clang["revision"]:
    print(f"CLANG_PROJECT_SHA={clang['revision']}")
else:
    print("::warning::clang prebuilt project not found in manifest; will use branch fallback", file=sys.stderr)
    print("CLANG_PROJECT_SHA=")
