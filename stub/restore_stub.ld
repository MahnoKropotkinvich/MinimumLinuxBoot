OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : {
        *(.text .text.*)
    }

    /* Captured CLINT state (mtime/msip/mtimecmp), 200 bytes, written by
       extract.py combine(). Sits between the stub text and the register blob. */
    __clint_blob = 0x80000C00;

    /* Register blob lives at fixed address 0x80001000 */
    __reg_blob = 0x80001000;

}
