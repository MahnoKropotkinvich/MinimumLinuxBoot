#!/usr/bin/env python3
"""Extract a CPU+RAM checkpoint from QEMU via GDB for OpenPiton restore.

Usage:
    python3 scripts/extract.py \
        --qemu qemu/build/qemu-system-riscv64 \
        --bios opensbi/build/platform/generic/firmware/fw_jump.bin \
        --kernel linux/arch/riscv/boot/Image \
        --initrd build/initramfs.cpio.gz \
        --stub build/restore_stub.bin \
        -o build/
"""

from __future__ import annotations

import argparse
import re
import struct
import subprocess
import sys
import time
from pathlib import Path

# --- Register definitions ---
# Must match restore_stub.S blob layout (488 bytes total).

GPRS = [f"x{i}" for i in range(1, 32)]

CSRS = [
    "mstatus", "mtvec", "mepc",
    "mideleg", "medeleg", "mscratch",
    "satp", "stvec", "sscratch",
    "sie", "scounteren", "mcounteren",
    "pmpcfg0", "pmpcfg2",
]

PMPADDRS = [f"pmpaddr{i}" for i in range(16)]

ALL_REGS = GPRS + ["pc"] + CSRS + PMPADDRS + ["priv"]

# Blob layout
BLOB_SIZE = 488
GPR_OFF = 0           # x1..x31: 31 * 8 = 248
PC_OFF = 248          # 8
CSR_OFF = {           # name -> byte offset in blob
    "mstatus": 256, "mtvec": 264,
    "mideleg": 272, "medeleg": 280, "mscratch": 288,
    "satp": 296, "stvec": 304, "sscratch": 312,
    "sie": 320, "scounteren": 328, "mcounteren": 336,
    "pmpcfg0": 344, "pmpcfg2": 352,
}
PMP_OFF = 360         # pmpaddr0..15: 16 * 8 = 128

VALUE_RE = re.compile(r"^\$\d+\s*=\s*(\S+)")

args: argparse.Namespace


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Extract OpenPiton/QEMU checkpoint via GDB")

    # Tool paths
    p.add_argument("--qemu", required=True,
                   help="Path to qemu-system-riscv64")
    p.add_argument("--bios", required=True,
                   help="Path to OpenSBI fw_jump.bin")
    p.add_argument("--kernel", required=True,
                   help="Path to kernel/payload binary")
    p.add_argument("--initrd",
                   help="Path to initramfs cpio.gz (optional, for Linux)")
    p.add_argument("--append",
                   help="Kernel command line (optional, for Linux)")
    p.add_argument("--stub", required=True,
                   help="Path to restore_stub.bin")
    p.add_argument("--tool-gdb", default="gdb",
                   help="GDB binary (default: gdb)")
    p.add_argument("--tool-nm", default="riscv64-linux-gnu-nm",
                   help="nm binary (default: riscv64-linux-gnu-nm)")

    # Checkpoint parameters
    p.add_argument("--bp", type=lambda x: int(x, 0),
                   default=0xffffffff8000db74,
                   help="Breakpoint address (default: handle_break)")
    p.add_argument("--bp-symbol",
                   help="Resolve breakpoint from ELF symbol (overrides --bp)")
    p.add_argument("--elf",
                   help="ELF for symbol resolution (required with --bp-symbol)")
    p.add_argument("--ram-size", default="0x10000000",
                   help="RAM dump size (default: 256M)")
    p.add_argument("--ram-base", default="0x80000000",
                   help="RAM base address (default: 0x80000000)")

    # Runtime
    p.add_argument("-o", "--output-dir", default="build",
                   help="Output directory (default: build/)")
    p.add_argument("--gdb-port", type=int, default=1234,
                   help="GDB TCP port (default: 1234)")
    p.add_argument("--qemu-wait", type=float, default=2.0,
                   help="Seconds to wait for QEMU startup")
    p.add_argument("--timeout", type=int, default=300,
                   help="GDB timeout in seconds")

    return p.parse_args()


def resolve_symbol(elf: str, symbol: str) -> int:
    """Look up symbol address using nm."""
    r = subprocess.run([args.tool_nm, elf], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{args.tool_nm} failed: {r.stderr.strip()}")
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[2] == symbol:
            return int(parts[0], 16)
    raise ValueError(f"Symbol '{symbol}' not found in {elf}")


def run_qemu() -> subprocess.Popen:
    """Start QEMU with openpiton-spike machine, paused with GDB stub."""
    argv = [
        args.qemu,
        "-machine", "openpiton-spike",
        "-cpu", "rv64,h=false,sstc=false,zicntr=false,zihpm=false",
        "-m", "256M", "-nographic",
        "-bios", args.bios,
        "-kernel", args.kernel,
        "-gdb", f"tcp::{args.gdb_port}",
        "-S",
    ]
    if args.initrd:
        argv += ["-initrd", args.initrd]
    if args.append:
        argv += ["-append", args.append]
    print(f"Starting QEMU (:{args.gdb_port})...", file=sys.stderr)
    proc = subprocess.Popen(argv,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(args.qemu_wait)
    if proc.poll() is not None:
        raise RuntimeError(f"QEMU exited early (status {proc.returncode})")
    return proc


def run_gdb(bp: int, ram_base: int, ram_size: int, ram_path: Path) -> str:
    """Run GDB batch: breakpoint, read registers, dump RAM."""
    cmds = [
        "set architecture riscv:rv64",
        f"target remote localhost:{args.gdb_port}",
        f"break *{bp:#x}",
        "continue",
        *(f"p/x ${r}" for r in ALL_REGS),
        f'monitor pmemsave {ram_base:#x} {ram_size:#x} "{ram_path}"',
    ]
    argv = [args.tool_gdb, "-batch", "-nx"]
    for c in cmds:
        argv += ["-ex", c]

    r = subprocess.run(argv, capture_output=True, text=True, timeout=args.timeout)
    output = r.stdout + r.stderr
    if r.returncode != 0:
        raise RuntimeError(f"GDB failed (status {r.returncode}):\n{output}")
    return output


def parse_values(gdb_output: str) -> list[int]:
    """Extract register values from GDB output."""
    values = []
    for line in gdb_output.splitlines():
        m = VALUE_RE.match(line.strip())
        if m:
            values.append(int(m.group(1).rstrip(","), 0))
    if len(values) != len(ALL_REGS):
        raise RuntimeError(
            f"Expected {len(ALL_REGS)} values, got {len(values)}")
    return values


def build_blob(values: list[int]) -> bytes:
    """Pack values into 488-byte blob matching restore_stub.S layout."""
    blob = bytearray(BLOB_SIZE)

    # GPRs: x1..x31
    for i in range(31):
        struct.pack_into("<Q", blob, GPR_OFF + i * 8,
                         values[i] & 0xFFFF_FFFF_FFFF_FFFF)

    # PC
    struct.pack_into("<Q", blob, PC_OFF,
                     values[31] & 0xFFFF_FFFF_FFFF_FFFF)

    # CSRs (mepc at index 34 is not stored - restore uses blob PC for mret)
    csr_indices = {
        "mstatus": 32, "mtvec": 33,
        "mideleg": 35, "medeleg": 36, "mscratch": 37,
        "satp": 38, "stvec": 39, "sscratch": 40,
        "sie": 41, "scounteren": 42, "mcounteren": 43,
        "pmpcfg0": 44, "pmpcfg2": 45,
    }
    for name, offset in CSR_OFF.items():
        struct.pack_into("<Q", blob, offset,
                         values[csr_indices[name]] & 0xFFFF_FFFF_FFFF_FFFF)

    # PMP addresses
    for i in range(16):
        struct.pack_into("<Q", blob, PMP_OFF + i * 8,
                         values[46 + i] & 0xFFFF_FFFF_FFFF_FFFF)

    return bytes(blob)


def combine(stub: Path, blob: Path, ram: Path, out: Path) -> None:
    """Overlay stub+blob onto RAM dump.

    Memory layout at 0x80000000:
        0x0000: restore_stub (entry point)
        0x1000: checkpoint_blob (488B GPR/CSR/PMP state)
        rest:   original RAM content
    """
    data = bytearray(ram.read_bytes())
    s = stub.read_bytes()
    b = blob.read_bytes()
    data[0:len(s)] = s
    data[0x1000:0x1000 + len(b)] = b
    out.write_bytes(data)


def main() -> int:
    global args
    args = parse_args()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ram_size = int(args.ram_size, 0)
    ram_base = int(args.ram_base, 0)

    # Resolve breakpoint
    if args.bp_symbol:
        if not args.elf:
            raise RuntimeError("--elf required when using --bp-symbol")
        bp = resolve_symbol(args.elf, args.bp_symbol)
        print(f"Resolved {args.bp_symbol} -> {bp:#x}", file=sys.stderr)
    else:
        bp = args.bp

    # Output paths
    blob_path = out_dir / "checkpoint_blob.bin"
    ram_path = out_dir / "checkpoint_ram.bin"
    combined_path = out_dir / "checkpoint_combined.bin"
    for p in (blob_path, ram_path, combined_path):
        p.unlink(missing_ok=True)

    # Start QEMU and extract via GDB
    qemu = run_qemu()
    try:
        print(f"GDB: break *{bp:#x}, dump {ram_size:#x} @ {ram_base:#x}",
              file=sys.stderr)
        gdb_out = run_gdb(bp, ram_base, ram_size, ram_path)

        values = parse_values(gdb_out)
        blob_data = build_blob(values)
        blob_path.write_bytes(blob_data)

        # Validate RAM dump
        if not ram_path.exists() or ram_path.stat().st_size != ram_size:
            actual = ram_path.stat().st_size if ram_path.exists() else 0
            raise RuntimeError(
                f"RAM dump: expected {ram_size:#x}, got {actual:#x}")

        # Combine stub + blob + ram
        stub_path = Path(args.stub)
        if not stub_path.exists():
            raise RuntimeError(f"Stub not found: {stub_path}")
        combine(stub_path, blob_path, ram_path, combined_path)

        # Summary
        print(f"\n  mtvec    = {values[33]:#x}", file=sys.stderr)
        print(f"  mideleg  = {values[35]:#x}", file=sys.stderr)
        print(f"  medeleg  = {values[36]:#x}", file=sys.stderr)
        print(f"  satp     = {values[38]:#x}", file=sys.stderr)
        print(f"  priv     = {values[-1]}", file=sys.stderr)
        print(f"\n  blob     = {blob_path} ({blob_path.stat().st_size}B)",
              file=sys.stderr)
        print(f"  ram      = {ram_path} ({ram_path.stat().st_size}B)",
              file=sys.stderr)
        print(f"  combined = {combined_path} ({combined_path.stat().st_size}B)",
              file=sys.stderr)
        return 0

    finally:
        if qemu.poll() is None:
            qemu.terminate()
            try:
                qemu.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu.kill()
                qemu.wait()


if __name__ == "__main__":
    sys.exit(main())
