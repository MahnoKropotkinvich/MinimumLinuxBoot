#!/usr/bin/env python3
"""Extract a CPU+RAM checkpoint from QEMU via GDB for OpenPiton restore.

Usage:
    python3 scripts/extract.py \
        --qemu qemu/build/qemu-system-riscv64 \
        --kernel bsc-linux/buildroot/output/images/Image \
        --initrd bsc-linux/buildroot/output/images/rootfs.cpio \
        --stub build/restore_stub.bin \
        --smp 1 --bp 0xffffffff80003cbc \
        -o build/
"""

from __future__ import annotations

import argparse
import dataclasses
import re
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

# CLINT MMIO base on the openpiton-spike machine. Register map matches both
# QEMU's ACLINT split and OpenPiton's clint.sv:
#   +0x0000 + 4*i : msip[i]      (32-bit)
#   +0x4000 + 8*i : mtimecmp[i]  (64-bit)
#   +0xbff8       : mtime        (64-bit)
CLINT_BASE = 0xFFF1_0200_00
CLINT_MSIP_OFF = 0x0000
CLINT_MTIMECMP_OFF = 0x4000
CLINT_MTIME_OFF = 0xBFF8
MAX_CLINT_HARTS = 16

QEMU_STARTUP_WAIT = 2.0
GDB_TIMEOUT = 600

# Linux do_trap_break. The userspace ebreak_trigger runs after init; GDB
# stops here, before the instruction executes, so restore leaves pc alone
# and the kernel resumes handling the ebreak.
DO_TRAP_BREAK = 0xFFFFFFFF80003CBC


@dataclass
class HartState:
    hart: int = 0
    pc: int = 0

    # mie must be restored: CVA6 resets mie_q to 0 and its wfi wake condition is
    # |(mip_q & mie_q), so a hart parked in wfi could never be woken by an IPI,
    # deadlocking SBI rfence/tlb_sync on SMP.
    mstatus: int = 0
    mtvec: int = 0
    mideleg: int = 0
    medeleg: int = 0
    mscratch: int = 0
    mcounteren: int = 0
    mie: int = 0

    satp: int = 0
    stvec: int = 0
    sscratch: int = 0
    sie: int = 0
    scounteren: int = 0
    sepc: int = 0
    scause: int = 0
    stval: int = 0

    fcsr: int = 0
    pmpcfg0: int = 0      # RV64 has only even-numbered pmpcfg
    pmpcfg2: int = 0

    gprs: list[int] = field(default_factory=lambda: [0] * 31)
    pmpaddrs: list[int] = field(default_factory=lambda: [0] * 16)
    fprs: list[int] = field(default_factory=lambda: [0] * 32)

    def pack(self) -> bytes:
        blob = bytearray(BLOB_SIZE)
        for name, off in SCALAR_OFF.items():
            struct.pack_into("<Q", blob, off, getattr(self, name))
        for name, (off, _start, _count, _expr) in ARRAYS.items():
            for i, v in enumerate(getattr(self, name)):
                struct.pack_into("<Q", blob, off + i * 8, v)
        return bytes(blob)


@dataclass
class ClintState:
    mtime: int = 0
    msip: list[int] = field(default_factory=list)
    mtimecmp: list[int] = field(default_factory=list)

    def pack(self) -> bytes:
        out = bytearray(struct.pack("<Q", self.mtime))
        for i in range(MAX_CLINT_HARTS):
            out += struct.pack("<I", self.msip[i] if i < len(self.msip) else 0)
        for i in range(MAX_CLINT_HARTS):
            out += struct.pack("<Q", self.mtimecmp[i] if i < len(self.mtimecmp) else 0)
        return bytes(out)



SCALAR_OFF: dict[str, int] = {
    "pc": 248,
    "mstatus": 256, "mtvec": 264, "mideleg": 272, "medeleg": 280,
    "mscratch": 288, "satp": 296, "stvec": 304, "sscratch": 312,
    "sie": 320, "scounteren": 328, "mcounteren": 336,
    "pmpcfg0": 344, "pmpcfg2": 352,
    "mie": 496,
    "sepc": 504, "scause": 512, "stval": 520, "fcsr": 528,
}

# field -> (blob offset, first register index, count, gdb expression).
ARRAYS: dict[str, tuple[int, int, int, str]] = {
    "gprs":     (0,   1, 31, "$x{}"),
    "pmpaddrs": (360, 0, 16, "$pmpaddr{}"),
    "fprs":     (536, 0, 32, "$f{}.double"),
}

NREGS = len(SCALAR_OFF) + sum(c for _o, _s, c, _e in ARRAYS.values())

BLOB_SIZE = 792
BLOB_STRIDE = 0x400
CLINT_STATE_OFF = 0xC00  # __clint_blob in restore_stub.ld
BLOB_BASE_OFF = 0x1000   # __reg_blob in restore_stub.ld

# p/x → "$1 = 0x8000000a00006120"    monitor xp /1 → "fff102bff8: 0x84fc4"
HEX_LINE = re.compile(
    r"^(?:\$\d+\s*=\s*|[0-9a-fA-F]+:\s*)(0x[0-9a-fA-F]+)")


def check_layout() -> None:
    placed = set(SCALAR_OFF) | set(ARRAYS)
    fields = {f.name for f in dataclasses.fields(HartState)} - {"hart"}
    if placed != fields:
        raise RuntimeError(
            f"blob layout: unplaced fields {sorted(fields - placed)}, "
            f"unknown offsets {sorted(placed - fields)}")

    regions = [(n, o, 8) for n, o in SCALAR_OFF.items()]
    regions += [(n, o, c * 8) for n, (o, _s, c, _e) in ARRAYS.items()]
    regions.sort(key=lambda r: r[1])

    for (n1, o1, s1), (n2, o2, _) in zip(regions, regions[1:]):
        if o1 + s1 > o2:
            raise RuntimeError(
                f"blob layout: {n1} ({o1}..{o1 + s1 - 1}) overlaps {n2} (at {o2})")

    end = max(o + s for _, o, s in regions)
    if end != BLOB_SIZE:
        raise RuntimeError(f"blob layout: BLOB_SIZE={BLOB_SIZE} but data ends at {end}")
    if BLOB_SIZE > BLOB_STRIDE:
        raise RuntimeError(
            f"blob layout: BLOB_SIZE={BLOB_SIZE} exceeds BLOB_STRIDE={BLOB_STRIDE:#x}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Extract OpenPiton/QEMU checkpoint via GDB")

    p.add_argument("--qemu", required=True, help="Path to qemu-system-riscv64")
    p.add_argument("--smp", type=int, default=1,
                   help="Number of harts to boot and capture (default 1). "
                        "Must match the RTL tile count.")
    p.add_argument("--bios", help="Optional firmware; omit to use QEMU default")
    p.add_argument("--kernel", required=True, help="Path to kernel/payload binary")
    p.add_argument("--initrd", help="Path to initramfs cpio(.gz)")
    p.add_argument("--append", help="Kernel command line")
    p.add_argument("--stub", required=True, help="Path to restore_stub.bin")
    p.add_argument("--tool-gdb", default="gdb", help="GDB binary (default: gdb)")

    p.add_argument("--bp", type=lambda x: int(x, 0), default=DO_TRAP_BREAK,
                   help=f"Breakpoint address (default: {DO_TRAP_BREAK:#x}, "
                        "Linux do_trap_break)")
    p.add_argument("--ram-size", type=lambda x: int(x, 0), default=0x10000000,
                   help="RAM dump size (default: 256M)")
    p.add_argument("--ram-base", type=lambda x: int(x, 0), default=0x80000000,
                   help="RAM base address (default: 0x80000000)")
    p.add_argument("-o", "--output-dir", default="build",
                   help="Output directory (default: build/)")

    return p.parse_args()


def run_qemu(args: argparse.Namespace, socket: Path) -> subprocess.Popen:
    argv = [
        args.qemu,
        "-machine", "openpiton-spike",
        # CVA6 implements Sv39 only; without pinning this the guest kernel may
        # select Sv48/Sv57 and the captured satp would name a paging mode the RTL
        # cannot walk. sstc=false because CVA6 has no stimecmp CSR, so OpenSBI
        # must not take the csrw stimecmp path.
        "-cpu", ("rv64,h=false,sstc=false,zicntr=false,zihpm=false"
                 ",sv57=false,sv48=false"
                ),
        "-m", "256M", "-nographic",
        "-smp", str(args.smp),
        "-kernel", args.kernel,
        "-gdb", f"unix:{socket},server,nowait",
        "-S",
    ]
    if args.initrd:
        argv += ["-initrd", args.initrd]
    if args.append:
        argv += ["-append", args.append]
    if args.bios:
        argv += ["-bios", args.bios]

    print(f"Starting QEMU ({socket})...", file=sys.stderr)
    proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    time.sleep(QEMU_STARTUP_WAIT)
    if proc.poll() is not None:
        raise RuntimeError(f"QEMU exited early (status {proc.returncode})")
    return proc


def run_gdb(args: argparse.Namespace, socket: Path,
            ram_path: Path) -> tuple[list[HartState], ClintState]:
    cmds = [
        "set architecture riscv:rv64",
        f"target remote {socket}",
        f"break *{args.bp:#x}",
        "continue",
    ]

    for hart in range(args.smp):
        # QEMU numbers its gdbstub threads hart+1.
        cmds.append(f"thread {hart + 1}")
        for name in SCALAR_OFF:
            cmds.append(f"p/x ${name}")
        cmds.append("p/x $priv")
        for _off, start, count, tmpl in ARRAYS.values():
            for i in range(count):
                cmds.append(f"p/x {tmpl.format(start + i)}")

    cmds.append(f'monitor pmemsave {args.ram_base:#x} {args.ram_size:#x} "{ram_path}"')

    # CLINT is MMIO, so pmemsave does not cover it. At capture time the harts
    # run in S-mode under a live satp, so a virtual read of the CLINT base
    # faults. `monitor xp` bypasses translation. One word per command, same
    # order as ClintState is filled below.
    for i in range(args.smp):
        cmds.append(f"monitor xp /1wx {CLINT_BASE + CLINT_MSIP_OFF + 4 * i:#x}")
    for i in range(args.smp):
        cmds.append(f"monitor xp /1gx {CLINT_BASE + CLINT_MTIMECMP_OFF + 8 * i:#x}")
    cmds.append(f"monitor xp /1gx {CLINT_BASE + CLINT_MTIME_OFF:#x}")

    argv = [args.tool_gdb, "-batch", "-nx"]
    for c in cmds:
        argv += ["-ex", c]

    r = subprocess.run(argv, capture_output=True, text=True, timeout=GDB_TIMEOUT)
    if r.returncode != 0:
        raise RuntimeError(f"GDB failed (status {r.returncode}):\n{r.stdout}\n{r.stderr}")

    vals = []
    for line in (r.stdout + r.stderr).splitlines():
        m = HEX_LINE.match(line.strip())
        if m:
            vals.append(int(m.group(1), 16))

    expect = args.smp * (NREGS + 1) + args.smp + args.smp + 1
    if len(vals) != expect:
        raise RuntimeError(f"GDB: expected {expect} hex values, got {len(vals)}")

    it = iter(vals)
    harts = []
    for h in range(args.smp):
        st = HartState(hart=h)
        for name in SCALAR_OFF:
            setattr(st, name, next(it))
        priv = next(it)
        st.mstatus = (st.mstatus & ~(3 << 11)) | ((priv & 3) << 11)
        for name, (_off, _start, count, _tmpl) in ARRAYS.items():
            getattr(st, name)[:] = [next(it) for _ in range(count)]
        harts.append(st)

    clint = ClintState(
        msip=[next(it) for _ in range(args.smp)],
        mtimecmp=[next(it) for _ in range(args.smp)],
        mtime=next(it),
    )
    return harts, clint


def pack_image(stub: Path, hart_blobs: list[bytes], ram: Path, out: Path,
               clint_blob: bytes) -> None:
    data = bytearray(ram.read_bytes())

    st = stub.read_bytes()
    if len(st) > CLINT_STATE_OFF:
        raise RuntimeError(
            f"stub ({len(st)}B) overruns CLINT blob at {CLINT_STATE_OFF:#x}")
    data[0:len(st)] = st

    end = CLINT_STATE_OFF + len(clint_blob)
    if end > BLOB_BASE_OFF:
        raise RuntimeError(
            f"CLINT blob ({len(clint_blob)}B) overruns blob area "
            f"at {BLOB_BASE_OFF:#x}")
    data[CLINT_STATE_OFF:end] = clint_blob

    for hart, b in enumerate(hart_blobs):
        off = BLOB_BASE_OFF + hart * BLOB_STRIDE
        data[off:off + len(b)] = b

    out.write_bytes(data)


def main() -> int:
    args = parse_args()
    check_layout()

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    socket = out_dir / "gdb.sock"
    blob_path = out_dir / "checkpoint_blob.bin"
    ram_path = out_dir / "checkpoint_ram.bin"
    combined_path = out_dir / "checkpoint_combined.bin"
    clint_path = out_dir / "clint_state.bin"
    for p in (blob_path, ram_path, combined_path, clint_path, socket):
        p.unlink(missing_ok=True)

    stub_path = Path(args.stub)
    if not stub_path.exists():
        raise RuntimeError(f"Stub not found: {stub_path}")

    qemu = run_qemu(args, socket)
    try:
        print(f"GDB: break *{args.bp:#x}, dump {args.ram_size:#x} "
              f"@ {args.ram_base:#x}", file=sys.stderr)
        harts, clint = run_gdb(args, socket, ram_path)

        clint_blob = clint.pack()
        clint_path.write_bytes(clint_blob)
        print(f"  clint    = {clint_path} (mtime={clint.mtime:#x})",
              file=sys.stderr)

        hart_blobs = [h.pack() for h in harts]
        blob_path.write_bytes(b"".join(
            b.ljust(BLOB_STRIDE, b"\x00") for b in hart_blobs))
        pack_image(stub_path, hart_blobs, ram_path, combined_path, clint_blob)

        h0 = harts[0]
        print(f"\n  harts    = {len(harts)}", file=sys.stderr)
        for name in ("mtvec", "mideleg", "medeleg", "satp", "mie"):
            print(f"  {name:<8} = {getattr(h0, name):#x}", file=sys.stderr)
        print(f"  {'mpp':<8} = {(h0.mstatus >> 11) & 3}\n", file=sys.stderr)
        for label, path in (("blob", blob_path), ("ram", ram_path),
                            ("combined", combined_path)):
            print(f"  {label:<8} = {path} ({path.stat().st_size}B)",
                  file=sys.stderr)
        return 0

    finally:
        qemu.kill()
        qemu.wait()
        socket.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
