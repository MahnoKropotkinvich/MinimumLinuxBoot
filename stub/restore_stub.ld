OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80000000;

    .text : {
        *(.text .text.*)
    }

    /* Register blob lives at fixed address 0x80001000 */
    __reg_blob = 0x80001000;

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
