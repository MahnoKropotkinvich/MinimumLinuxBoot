/* ---- CLINT MMIO (matches riscv_peripherals.sv ClintBase) ---- */
.equ CLINT_BASE,     0xfff1020000
.equ CLINT_MSIP,     0x0000          /* + 4*hartid */
.equ CLINT_MTIMECMP, 0x4000          /* + 8*hartid */
.equ CLINT_MTIME,    0xbff8

/* ---- captured CLINT blob, placed at 0x80000C00 ----
 * Layout: mtime 8B, msip[16] 4B each, mtimecmp[16] 8B each.
 */
.equ CS_MTIME,       0
.equ CS_MSIP,        8
.equ CS_MTIMECMP,    72              /* 8 (mtime) + 64 (msip[16]) */

.option norvc
.section .text
.globl _start
_start:
    .option push
    .option norelax
    lla t6, __reg_blob
    .option pop

    /* Each hart restores its own blob: t6 += mhartid * BLOB_STRIDE (0x400). */
    csrr t5, mhartid
    slli t5, t5, 10
    add  t6, t6, t5

    /* ---- restore CLINT (msip + mtimecmp per hart, mtime once) ---- */
    li   t0, CLINT_BASE
    lla  t1, __clint_blob
    csrr t2, mhartid

    /* msip[hartid] */
    slli t3, t2, 2                      /* hartid * 4 */
    add  t4, t1, t3
    lwu  t4, CS_MSIP(t4)
    add  t3, t0, t3                     /* CLINT_BASE + 4*hartid */
    sw   t4, 0(t3)

    /* mtimecmp[hartid] */
    slli t3, t2, 3                      /* hartid * 8 */
    add  t4, t1, t3
    ld   t4, CS_MTIMECMP(t4)
    add  t3, t0, t3                     /* CLINT_BASE + 8*hartid */
    li   t5, CLINT_MTIMECMP
    add  t3, t3, t5                     /* offset exceeds 12-bit imm */
    sd   t4, 0(t3)

    /* mtime is global: only hart 0 writes it */
    bnez t2, 1f
    ld   t4, CS_MTIME(t1)
    li   t5, CLINT_MTIME
    add  t5, t0, t5
    sd   t4, 0(t5)
1:

/* ---- blob offsets (each 8 bytes) ---- */
.equ RB_X1,          0
.equ RB_X2,          8
.equ RB_X3,          16
.equ RB_X4,          24
.equ RB_X5,          32
.equ RB_X6,          40
.equ RB_X7,          48
.equ RB_X8,          56
.equ RB_X9,          64
.equ RB_X10,         72
.equ RB_X11,         80
.equ RB_X12,         88
.equ RB_X13,         96
.equ RB_X14,         104
.equ RB_X15,         112
.equ RB_X16,         120
.equ RB_X17,         128
.equ RB_X18,         136
.equ RB_X19,         144
.equ RB_X20,         152
.equ RB_X21,         160
.equ RB_X22,         168
.equ RB_X23,         176
.equ RB_X24,         184
.equ RB_X25,         192
.equ RB_X26,         200
.equ RB_X27,         208
.equ RB_X28,         216
.equ RB_X29,         224
.equ RB_X30,         232
.equ RB_X31,         240

.equ RB_PC,          248
.equ RB_MSTATUS,     256
.equ RB_MTVEC,       264
.equ RB_MIDELEG,     272
.equ RB_MEDELEG,     280
.equ RB_MSCRATCH,    288
.equ RB_SATP,        296
.equ RB_STVEC,       304
.equ RB_SSCRATCH,    312
.equ RB_SIE,         320
.equ RB_SCOUNTEREN,  328
.equ RB_MCOUNTEREN,  336
.equ RB_PMPCFG0,     344
.equ RB_PMPCFG2,     352
.equ RB_PMPADDR0,    360
.equ RB_PMPADDR1,    368
.equ RB_PMPADDR2,    376
.equ RB_PMPADDR3,    384
.equ RB_PMPADDR4,    392
.equ RB_PMPADDR5,    400
.equ RB_PMPADDR6,    408
.equ RB_PMPADDR7,    416
.equ RB_PMPADDR8,    424
.equ RB_PMPADDR9,    432
.equ RB_PMPADDR10,   440
.equ RB_PMPADDR11,   448
.equ RB_PMPADDR12,   456
.equ RB_PMPADDR13,   464
.equ RB_PMPADDR14,   472
.equ RB_PMPADDR15,   480
.equ RB_MIE,         496

.equ RB_SEPC,        504
.equ RB_SCAUSE,      512
.equ RB_STVAL,       520

.equ RB_FCSR,        528
.equ RB_F0,          536

.equ RB_SIZE,        792

/* ---- restore CSRs (use t0 as scratch, t6 as blob base) ---- */

    ld t0, RB_PC(t6)
    csrw mepc, t0

    ld t0, RB_MTVEC(t6)
    csrw mtvec, t0

    ld t0, RB_MIDELEG(t6)
    csrw mideleg, t0

    ld t0, RB_MEDELEG(t6)
    csrw medeleg, t0

    ld t0, RB_MSCRATCH(t6)
    csrw mscratch, t0

    ld t0, RB_SATP(t6)
    csrw satp, t0
    sfence.vma

    ld t0, RB_STVEC(t6)
    csrw stvec, t0

    ld t0, RB_SSCRATCH(t6)
    csrw sscratch, t0

    ld t0, RB_SEPC(t6)
    csrw sepc, t0

    ld t0, RB_SCAUSE(t6)
    csrw scause, t0

    ld t0, RB_STVAL(t6)
    csrw stval, t0

    ld t0, RB_SIE(t6)
    csrw sie, t0

    ld t0, RB_MIE(t6)
    csrw mie, t0

    ld t0, RB_SCOUNTEREN(t6)
    csrw scounteren, t0

    ld t0, RB_MCOUNTEREN(t6)
    csrw mcounteren, t0

    ld t0, RB_PMPCFG0(t6)
    csrw pmpcfg0, t0

    ld t0, RB_PMPCFG2(t6)
    csrw pmpcfg2, t0

    ld t0, RB_PMPADDR0(t6)
    csrw pmpaddr0, t0
    ld t0, RB_PMPADDR1(t6)
    csrw pmpaddr1, t0
    ld t0, RB_PMPADDR2(t6)
    csrw pmpaddr2, t0
    ld t0, RB_PMPADDR3(t6)
    csrw pmpaddr3, t0
    ld t0, RB_PMPADDR4(t6)
    csrw pmpaddr4, t0
    ld t0, RB_PMPADDR5(t6)
    csrw pmpaddr5, t0
    ld t0, RB_PMPADDR6(t6)
    csrw pmpaddr6, t0
    ld t0, RB_PMPADDR7(t6)
    csrw pmpaddr7, t0
    ld t0, RB_PMPADDR8(t6)
    csrw pmpaddr8, t0
    ld t0, RB_PMPADDR9(t6)
    csrw pmpaddr9, t0
    ld t0, RB_PMPADDR10(t6)
    csrw pmpaddr10, t0
    ld t0, RB_PMPADDR11(t6)
    csrw pmpaddr11, t0
    ld t0, RB_PMPADDR12(t6)
    csrw pmpaddr12, t0
    ld t0, RB_PMPADDR13(t6)
    csrw pmpaddr13, t0
    ld t0, RB_PMPADDR14(t6)
    csrw pmpaddr14, t0
    ld t0, RB_PMPADDR15(t6)
    csrw pmpaddr15, t0

    /* ---- restore floating point state ---- */
    li t0, (3 << 13)          /* mstatus.FS = Dirty */
    csrs mstatus, t0

    ld t0, RB_FCSR(t6)
    fscsr t0

    fld f0,  RB_F0 +   0(t6)
    fld f1,  RB_F0 +   8(t6)
    fld f2,  RB_F0 +  16(t6)
    fld f3,  RB_F0 +  24(t6)
    fld f4,  RB_F0 +  32(t6)
    fld f5,  RB_F0 +  40(t6)
    fld f6,  RB_F0 +  48(t6)
    fld f7,  RB_F0 +  56(t6)
    fld f8,  RB_F0 +  64(t6)
    fld f9,  RB_F0 +  72(t6)
    fld f10, RB_F0 +  80(t6)
    fld f11, RB_F0 +  88(t6)
    fld f12, RB_F0 +  96(t6)
    fld f13, RB_F0 + 104(t6)
    fld f14, RB_F0 + 112(t6)
    fld f15, RB_F0 + 120(t6)
    fld f16, RB_F0 + 128(t6)
    fld f17, RB_F0 + 136(t6)
    fld f18, RB_F0 + 144(t6)
    fld f19, RB_F0 + 152(t6)
    fld f20, RB_F0 + 160(t6)
    fld f21, RB_F0 + 168(t6)
    fld f22, RB_F0 + 176(t6)
    fld f23, RB_F0 + 184(t6)
    fld f24, RB_F0 + 192(t6)
    fld f25, RB_F0 + 200(t6)
    fld f26, RB_F0 + 208(t6)
    fld f27, RB_F0 + 216(t6)
    fld f28, RB_F0 + 224(t6)
    fld f29, RB_F0 + 232(t6)
    fld f30, RB_F0 + 240(t6)
    fld f31, RB_F0 + 248(t6)

    /* mstatus last: overwrites the temporary FS = Dirty with the captured
     * FS. MPP is already the current privilege (filled in by extract.py). */
    ld t0, RB_MSTATUS(t6)
    csrw mstatus, t0

    /* ---- restore GPRs (t6=x31 last, t0=x5 second-to-last) ---- */
    ld x1,  RB_X1(t6)
    ld x2,  RB_X2(t6)
    ld x3,  RB_X3(t6)
    ld x4,  RB_X4(t6)
    ld x6,  RB_X6(t6)
    ld x7,  RB_X7(t6)
    ld x8,  RB_X8(t6)
    ld x9,  RB_X9(t6)
    ld x10, RB_X10(t6)
    ld x11, RB_X11(t6)
    ld x12, RB_X12(t6)
    ld x13, RB_X13(t6)
    ld x14, RB_X14(t6)
    ld x15, RB_X15(t6)
    ld x16, RB_X16(t6)
    ld x17, RB_X17(t6)
    ld x18, RB_X18(t6)
    ld x19, RB_X19(t6)
    ld x20, RB_X20(t6)
    ld x21, RB_X21(t6)
    ld x22, RB_X22(t6)
    ld x23, RB_X23(t6)
    ld x24, RB_X24(t6)
    ld x25, RB_X25(t6)
    ld x26, RB_X26(t6)
    ld x27, RB_X27(t6)
    ld x28, RB_X28(t6)
    ld x29, RB_X29(t6)
    ld x30, RB_X30(t6)

    /* restore t0 (x5) and t6 (x31) last */
    ld x5,  RB_X5(t6)
    ld x31, RB_X31(t6)

    mret
