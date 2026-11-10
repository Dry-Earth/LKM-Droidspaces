#!/usr/bin/env python3
"""Package the hummer Shikochin port as a KernelSU module ZIP.

Only payloads that were built successfully are included.  The namespace module
is mandatory; devtmpfs / netfilter / USER_NS are optional and are exposed to the
loader through config.conf.
"""
import argparse
import hashlib
import json
import re
import shutil
import struct
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TEMPLATE = ROOT / 'kernelsu-shikochin-hummer'
PAYLOADS = {
    'namespace': ('droidspaces_ns.ko', 'droidspaces_ns'),
    'devtmpfs': ('droidspaces_devtmpfs.ko', 'droidspaces_devtmpfs'),
    'netfilter': ('droidspaces_netfilter.ko', 'droidspaces_netfilter'),
    'userns': ('droidspaces_ns_userns.ko', 'droidspaces_ns_userns'),
}
MODULE_FILES = ('module.prop', 'common.sh', 'customize.sh', 'post-fs-data.sh',
                'service.sh', 'config.conf', 'skip_mount', 'README.md')
WEBUI_FILES = ('webroot/index.html', 'webroot/main.js')


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def check_arm64_ko(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 64 or data[:4] != b'\x7fELF':
        raise SystemExit(f'{path}: not an ELF file')
    if data[4] != 2 or data[5] != 1:
        raise SystemExit(f'{path}: expected ELF64 little-endian')
    machine = struct.unpack_from('<H', data, 18)[0]
    if machine != 183:
        raise SystemExit(f'{path}: expected AArch64 (e_machine=183), got {machine}')
    return data


def check_vermagic(path: Path, data: bytes, release: str) -> None:
    marker = f'vermagic={release} '.encode()
    if marker not in data:
        text = [line for line in data.split(b'\0') if b'vermagic=' in line]
        raise SystemExit(f'{path}: vermagic does not target {release}: {text[:2]}')


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--payloads', type=Path, required=True,
                    help='directory containing the built *.ko files')
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--template', type=Path, default=DEFAULT_TEMPLATE)
    ap.add_argument('--version', required=True)
    ap.add_argument('--release', required=True)
    ap.add_argument('--kernel-sha', default='')
    ap.add_argument('--config-sha', default='')
    args = ap.parse_args()

    built = {}
    for key, (filename, _stem) in PAYLOADS.items():
        path = args.payloads / filename
        if not path.is_file():
            if key == 'namespace':
                raise SystemExit(f'missing mandatory payload: {path}')
            continue
        data = check_arm64_ko(path)
        check_vermagic(path, data, args.release)
        if key == 'namespace' and b'parmtype=activate:bool' not in data:
            raise SystemExit(f'{path}: namespace module lacks parmtype=activate')
        built[key] = (filename, data)

    if 'namespace' not in built:
        raise SystemExit('the namespace payload is mandatory')

    template = args.template
    for name in MODULE_FILES + WEBUI_FILES + ('META-INF/com/google/android/update-binary',
                                'META-INF/com/google/android/updater-script'):
        if not (template / name).is_file():
            raise SystemExit(f'template file missing: {name}')

    args.output.mkdir(parents=True, exist_ok=True)
    stage = args.output / f'stage-{args.version}'
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir()
    (stage / 'kernel').mkdir()
    (stage / 'META-INF/com/google/android').mkdir(parents=True)

    files = {}
    for name in MODULE_FILES + WEBUI_FILES:
        files[name] = (template / name).read_bytes()
    for rel in ('META-INF/com/google/android/update-binary',
                'META-INF/com/google/android/updater-script'):
        files[rel] = (template / rel).read_bytes()

    manifest = []
    checksums = []
    for key, (filename, stem) in PAYLOADS.items():
        if key not in built:
            continue
        name, data = built[key]
        files[f'kernel/{name}'] = data
        checksums.append(f'{sha(data)}  {name}\n')
        manifest.append(f'{key}|{name}\n')
    files['kernel/SHA256SUMS'] = ''.join(checksums).encode()
    files['kernel/manifest.txt'] = ''.join(manifest).encode()

    build_id = [
        f'release={args.release}',
        f'kernel_sha={args.kernel_sha}',
        f'config_sha256={args.config_sha}',
        f'built={datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}',
    ]
    for key, (filename, _stem) in PAYLOADS.items():
        if key in built:
            build_id.append(f'{key}_sha256={sha(built[key][1])}')
    files['build-id.txt'] = ('\n'.join(build_id) + '\n').encode()

    # Stamp the version into module.prop without touching the template.
    prop = files['module.prop'].decode()
    prop = re.sub(r'^version=.*$', f'version={args.version}', prop, flags=re.M)
    digits = ''.join(c for c in args.version if c.isdigit())
    prop = re.sub(r'^versionCode=.*$', f'versionCode={int(digits) if digits else 1}',
                  prop, flags=re.M)
    files['module.prop'] = prop.encode()

    # Disable optional switches whose payload was not built, so a fresh install
    # does not report a permanent "partial load" just because a module is absent.
    conf = files['config.conf'].decode()
    for key in ('devtmpfs', 'netfilter', 'userns'):
        if key not in built:
            conf = re.sub(rf'^{key}=.*$', f'{key}=0', conf, flags=re.M)
    files['config.conf'] = conf.encode()

    for name, data in files.items():
        target = stage / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    date_time = (2026, 11, 8, 0, 0, 0)
    zip_path = args.output / f'Droidspaces-LKM-hummer-{args.version}.zip'
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for name in sorted(files):
            info = zipfile.ZipInfo(name, date_time=date_time)
            info.create_system = 3
            executable = name.endswith('.sh') or name.endswith('update-binary')
            info.external_attr = (0o100755 if executable else 0o100644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, files[name])

    # Standalone payloads for manual testing.
    standalone = []
    for key, (filename, stem) in PAYLOADS.items():
        if key in built:
            out = args.output / f'{stem}-{args.release.split("-")[0]}-hummer.ko'
            out.write_bytes(built[key][1])
            standalone.append(out)

    sums = [zip_path, *standalone]
    (args.output / 'SHA256SUMS').write_text(
        ''.join(f'{sha(p.read_bytes())}  {p.name}\n' for p in sums))

    summary = {
        'zip': str(zip_path),
        'payloads': {k: v[0] for k, v in built.items()},
        'release': args.release,
        'version': args.version,
    }
    (args.output / 'package.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    for p in sums + [args.output / 'SHA256SUMS']:
        print(p)


if __name__ == '__main__':
    main()
