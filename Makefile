PREFIX     ?= /opt/riscv
TARGET     ?= $(CURDIR)/build

CROSS_COMPILE = $(PREFIX)/bin/riscv64-unknown-linux-gnu-
CC            = $(CROSS_COMPILE)gcc
OBJCOPY       = $(CROSS_COMPILE)objcopy
GDB          ?= $(CROSS_COMPILE)gdb
HOST_CC      ?= cc

QEMU_DIR     = $(CURDIR)/qemu
STUB_DIR     = $(CURDIR)/stub
SCRIPTS_DIR  = $(CURDIR)/scripts

BSC_LINUX    ?= $(CURDIR)/bsc-linux
KERNEL       ?= $(BSC_LINUX)/buildroot/output/images/Image
INITRD       ?= $(BSC_LINUX)/buildroot/output/images/rootfs.cpio
SMP          ?= 1

QEMU_BUILD   = $(TARGET)/qemu
QEMU_BIN     = $(QEMU_BUILD)/qemu-system-riscv64

STUB_BIN     = $(TARGET)/restore_stub.bin
CONVERT_BIN  = $(TARGET)/convert

CHECKPOINT   = $(TARGET)/checkpoint_combined.bin
MEM_IMAGE    = $(TARGET)/mem.image

.PHONY: all build build-qemu build-stub build-convert build-bsc-linux capture clean

all: build

$(QEMU_BIN):
	mkdir -p $(QEMU_BUILD)
	cd $(QEMU_BUILD) && $(QEMU_DIR)/configure --target-list=riscv64-softmmu
	$(MAKE) -C $(QEMU_BUILD)

$(STUB_BIN): $(STUB_DIR)/restore_stub.S $(STUB_DIR)/restore_stub.ld
	mkdir -p $(TARGET)
	$(CC) -nostdlib -T $(STUB_DIR)/restore_stub.ld -o $(TARGET)/restore_stub.elf $(STUB_DIR)/restore_stub.S
	$(OBJCOPY) -O binary $(TARGET)/restore_stub.elf $@

$(CONVERT_BIN): $(SCRIPTS_DIR)/convert.c
	mkdir -p $(TARGET)
	$(HOST_CC) -O2 -Wall -Wextra -std=c11 -o $@ $<

build-bsc-linux:
	git -C $(BSC_LINUX) submodule update --init
	$(MAKE) -C $(BSC_LINUX)/buildroot BR2_EXTERNAL=$(BSC_LINUX)/bsc_tree sargantana_alveo_defconfig
	$(MAKE) -C $(BSC_LINUX)/buildroot
	$(MAKE) -C $(BSC_LINUX)/buildroot linux-rebuild-with-initramfs

build-qemu:      $(QEMU_BIN)
build-stub:      $(STUB_BIN)
build-convert:   $(CONVERT_BIN)

build: build-qemu build-stub build-convert build-bsc-linux

capture: build
	python3 $(SCRIPTS_DIR)/extract.py \
		--qemu $(QEMU_BIN) \
		--kernel $(KERNEL) \
		--initrd $(INITRD) \
		--stub $(STUB_BIN) \
		--smp $(SMP) \
		--append "console=hvc0 earlycon=sbi" \
		--tool-gdb $(GDB) \
		-o $(TARGET)/
	$(CONVERT_BIN) -o $(MEM_IMAGE) 0x80000000:$(CHECKPOINT)

clean:
	rm -rf $(TARGET)/*
