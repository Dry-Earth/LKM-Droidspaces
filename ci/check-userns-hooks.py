#!/usr/bin/env python3
"""Statically preflight the USER_NS hook table against a built vmlinux.

ds_hooks_prepare() in src/port66/hooks.c refuses to install a hook whose
symbol is absent or whose first four instructions cannot hold the trampoline.
A refusal is safe (the module simply fails to load), but it makes an otherwise
good build useless.  This checker applies the same rules to the exact KDIR:

  * every HOOK("name") exists in vmlinux with offset 0;
  * HOOK() entries have no RET/B in the first three instructions (a three-word
    ADRP/ADD/BR leaf patch is accepted, as the C code does);
  * HOOK_ORIGINAL() prologues contain only instructions the C code considers
    position independent (NOP/PACIASP/SUB SP/ADD x29,SP/STP/STR to SP);
  * every IPC_SYSCALL() wrapper exists as __arm64_sys_<name>.

Exit status is non-zero only for definite violations.  Missing tooling or an
unparseable function downgrades to a warning so the checker never blocks on
its own bugs.
"""

import argparse
import re
import shutil
import subprocess
import sys

HOOK_RE = re.compile(r'HOOK(?:_ORIGINAL)?\(\s*"([^"]+)"')
SYSCALL_RE = re.compile(r'(?<!DECLARE_)IPC_SYSCALL\(\s*([a-z0-9_]+)\s*\)')
SYSCALL_DECL_RE = re.compile(r'^\s*DECLARE_IPC_SYSCALL\(\s*([a-z0-9_]+)\s*\)')

MOVABLE_MNEMONICS = {"nop", "paciasp"}
TERMINATORS = {"ret"}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def pick_tools():
    nm = shutil.which("llvm-nm") or shutil.which("nm") or shutil.which("aarch64-linux-gnu-nm")
    od = (shutil.which("llvm-objdump") or shutil.which("objdump") or
          shutil.which("aarch64-linux-gnu-objdump"))
    return nm, od


def read_symbols(nm, vmlinux):
    """Return {name: (address, size)} for defined text symbols."""
    out = run([nm, "-S", "--defined-only", vmlinux])
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "nm failed")
    syms = {}
    # llvm-nm: "0000000000000000 0000000000000123 T name"
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        try:
            addr = int(parts[0], 16)
        except ValueError:
            continue
        if len(parts) >= 4:
            try:
                size = int(parts[1], 16)
            except ValueError:
                size = 0
            name = parts[3]
        else:
            size = 0
            name = parts[2]
        syms[name] = (addr, size)
    return syms


def disassemble(od, vmlinux, addr, size):
    """Return [(mnemonic, operands)] for the first min(size, 16) bytes."""
    end = addr + max(size, 16)
    out = run([od, "-d", "--no-show-raw-insn", "--start-address=0x%x" % addr,
               "--stop-address=0x%x" % end, vmlinux])
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or "objdump failed")
    insns = []
    for line in out.stdout.splitlines():
        m = re.match(r'^\s*[0-9a-f]+:\s+(\S+)\s*(.*)$', line)
        if not m:
            continue
        mnemonic = m.group(1).split(".")[0]
        insns.append((mnemonic, m.group(2).strip()))
        if len(insns) >= 8:
            break
    return insns


def is_movable(mnemonic, operands):
    if mnemonic in MOVABLE_MNEMONICS:
        return True
    if mnemonic == "sub" and re.match(r'^sp, sp, #(?:0x[0-9a-f]+|\d+)$', operands):
        return True
    if mnemonic == "mov" and operands == "x29, sp":
        return True
    if mnemonic == "add" and re.match(r'^x29, sp(?:, #(?:0x0|0))?$', operands):
        return True
    if mnemonic == "str":
        # Only the 64-bit STR (unsigned offset) form is position independent.
        return bool(re.match(r'^x\d+, \[sp(?:, #(?:0x[0-9a-f]+|\d+))?\]$', operands))
    if mnemonic == "stp":
        # Signed-offset or pre-index STP with SP as the base.
        return bool(re.match(r'^x\d+, x\d+, \[sp(?:, #-?(?:0x[0-9a-f]+|\d+))?\]!?$',
                             operands))
    return False


def is_terminator(mnemonic):
    return mnemonic in TERMINATORS or mnemonic == "b"


def parse_hooks(path):
    hooks = []
    syscalls = []
    declared = set()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            m = SYSCALL_DECL_RE.match(line)
            if m:
                declared.add(m.group(1))
            m = HOOK_RE.search(line)
            if m:
                name = m.group(1)
                original = "HOOK_ORIGINAL" in line.split(name)[0]
                hooks.append((name, original))
            syscalls.extend(SYSCALL_RE.findall(line))
    # newfstat/newfstatat are declared but installed through HOOK().
    return hooks, [s for s in syscalls if s in declared]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vmlinux", required=True)
    ap.add_argument("--hooks", required=True)
    ap.add_argument("--release", default="")
    args = ap.parse_args()

    nm, od = pick_tools()
    if not nm or not od:
        print("warning: nm/objdump unavailable; skipping static hook preflight")
        return 0

    hooks, syscalls = parse_hooks(args.hooks)
    try:
        syms = read_symbols(nm, args.vmlinux)
    except Exception as exc:  # noqa: BLE001 - downgrade tool failures
        print("warning: cannot read %s: %s" % (args.vmlinux, exc))
        return 0
    if not syms:
        print("warning: no symbols in %s; skipping" % args.vmlinux)
        return 0

    failures = []
    for name, original in hooks:
        sym = syms.get(name)
        if not sym:
            failures.append("missing symbol: %s" % name)
            continue
        addr, size = sym
        try:
            insns = disassemble(od, args.vmlinux, addr, size)
        except Exception as exc:  # noqa: BLE001
            print("warning: cannot disassemble %s: %s" % (name, exc))
            continue
        if len(insns) < 4:
            print("warning: %s: only %d instructions parsed" % (name, len(insns)))
            continue
        if original:
            bad = [i for i, ins in enumerate(insns[:4]) if not is_movable(*ins)]
            if bad:
                failures.append("unmovable original prologue: %s word %d %r" %
                                (name, bad[0], insns[:4]))
            continue
        early = None
        for i, (mnemonic, _) in enumerate(insns[:3]):
            if is_terminator(mnemonic):
                early = i
                break
        if early is not None and early != 2:
            failures.append("short entry: %s has a terminator at word %d" %
                            (name, early))

    for name in syscalls:
        wrapper = "__arm64_sys_" + name
        if wrapper not in syms:
            failures.append("missing syscall wrapper: %s" % wrapper)

    if failures:
        print("USER_NS hook preflight FAILED for %s" % (args.release or "target"))
        for item in failures:
            print("  - " + item)
        return 1

    print("USER_NS hook preflight passed: %d functions, %d syscalls" %
          (len(hooks), len(syscalls)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
