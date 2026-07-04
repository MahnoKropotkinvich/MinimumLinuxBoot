.option norvc
.section .text
.globl _start
_start:
    .option push
    .option norelax
    lla t6, __reg_blob
    .option pop

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
.equ RB_SIZE,        488

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

    ld t0, RB_SIE(t6)
    csrw sie, t0

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

    /* Restore mstatus last among CSRs — force MPP=S (01) */
    ld t0, RB_MSTATUS(t6)
    li t1, ~(3 << 11)
    and t0, t0, t1
    li t1, (1 << 11)
    or t0, t0, t1
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

    fence.i
    mret
