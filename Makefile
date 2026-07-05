PREFIX     ?= /opt/riscv
TARGET     ?= $(CURDIR)/build

CROSS_COMPILE = $(PREFIX)/bin/riscv64-unknown-linux-gnu-
CC            = $(CROSS_COMPILE)gcc
OBJCOPY       = $(CROSS_COMPILE)objcopy
GDB          ?= $(CROSS_COMPILE)gdb
NM           ?= $(CROSS_COMPILE)nm
HOST_CC      ?= cc

QEMU_DIR     = $(CURDIR)/qemu
LINUX_DIR    = $(CURDIR)/linux
OPENSBI_DIR  = $(CURDIR)/opensbi

STUB_DIR     = $(CURDIR)/stub
TRIGGER_DIR  = $(CURDIR)/trigger
ROOTFS_OVERLAY = $(CURDIR)/rootfs-overlay
SCRIPTS_DIR  = $(CURDIR)/scripts

LINUX_BUILD  = $(TARGET)/linux
OPENSBI_BUILD = $(TARGET)/opensbi
QEMU_BUILD   = $(TARGET)/qemu

QEMU_BIN     = $(QEMU_BUILD)/qemu-system-riscv64
BIOS         = $(OPENSBI_BUILD)/platform/generic/firmware/fw_jump.bin
LINUX_IMAGE  = $(LINUX_BUILD)/arch/riscv/boot/Image

STUB_BIN     = $(TARGET)/restore_stub.bin
CONVERT_BIN  = $(TARGET)/convert
TRIGGER_BIN  = $(TARGET)/ebreak_trigger
INITRD      ?= $(TARGET)/initramfs.cpio.gz

ALPINE_VER  ?= 3.22.0
ALPINE_V    = $(word 1,$(subst ., ,$(ALPINE_VER))).$(word 2,$(subst ., ,$(ALPINE_VER)))
ALPINE_URL  ?= https://dl-cdn.alpinelinux.org/alpine/v$(ALPINE_V)/releases/riscv64/alpine-minirootfs-$(ALPINE_VER)-riscv64.tar.gz
ALPINE_DIR   = $(TARGET)/alpine-rootfs

CHECKPOINT   = $(TARGET)/checkpoint_combined.bin
MEM_IMAGE    = $(TARGET)/mem.image

.PHONY: all build build-linux build-opensbi build-qemu build-stub build-convert build-trigger build-rootfs capture clean

all: build

# ---- Linux ----
$(LINUX_IMAGE):
	$(MAKE) -C $(LINUX_DIR) ARCH=riscv mrproper
	$(MAKE) -C $(LINUX_DIR) ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE) O=$(LINUX_BUILD) minimumlinuxboot_defconfig
	$(MAKE) -C $(LINUX_DIR) ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE) O=$(LINUX_BUILD)

# ---- OpenSBI ----
$(BIOS):
	$(MAKE) -C $(OPENSBI_DIR) PLATFORM=generic \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		FW_TEXT_START=0 \
		FW_JUMP_ADDR=0x80200000 \
		O=$(OPENSBI_BUILD)

# ---- QEMU ----
$(QEMU_BIN):
	mkdir -p $(QEMU_BUILD)
	cd $(QEMU_BUILD) && $(QEMU_DIR)/configure --target-list=riscv64-softmmu
	$(MAKE) -C $(QEMU_BUILD)

# ---- M-mode restore stub ----
$(STUB_BIN): $(STUB_DIR)/restore_stub.S $(STUB_DIR)/restore_stub.ld
	$(CC) -nostdlib -T $(STUB_DIR)/restore_stub.ld -o $(TARGET)/restore_stub.elf $(STUB_DIR)/restore_stub.S
	$(OBJCOPY) -O binary $(TARGET)/restore_stub.elf $@

# ---- convert (C) ----
$(CONVERT_BIN): $(SCRIPTS_DIR)/convert.c
	$(HOST_CC) -O2 -Wall -Wextra -std=c11 -o $@ $<

# ---- ebreak trigger ----
$(TRIGGER_BIN): $(TRIGGER_DIR)/ebreak_trigger.S
	$(CC) -nostdlib -static -Wl,-Ttext=0x10000 -o $@ $<

# ---- Alpine initramfs ----
$(ALPINE_DIR)/.stamp:
	@mkdir -p $(ALPINE_DIR)
	curl -sL $(ALPINE_URL) | tar -xz -C $(ALPINE_DIR)
	touch $@

$(TARGET)/initramfs.cpio.gz: $(ALPINE_DIR)/.stamp $(TRIGGER_BIN) $(ROOTFS_OVERLAY)/etc/inittab
	cp $(ROOTFS_OVERLAY)/etc/inittab $(ALPINE_DIR)/etc/inittab
	cp $(TRIGGER_BIN) $(ALPINE_DIR)/ebreak_trigger
	cd $(ALPINE_DIR) && find . | cpio -o -H newc 2>/dev/null | gzip -9 > $@

# ---- Phony build targets ----
build-linux:     $(LINUX_IMAGE)
build-opensbi:   $(BIOS)
build-qemu:      $(QEMU_BIN)
build-stub:      $(STUB_BIN)
build-convert:   $(CONVERT_BIN)
build-trigger:   $(TRIGGER_BIN)
build-rootfs:    $(filter $(TARGET)/initramfs.cpio.gz,$(INITRD))

# ---- Aggregate ----
build: build-linux build-opensbi build-qemu build-stub build-convert build-trigger build-rootfs

# ---- Capture checkpoint + generate mem.image ----
capture: build
	python3 $(SCRIPTS_DIR)/extract.py \
		--qemu $(QEMU_BIN) \
		--bios $(BIOS) \
		--kernel $(LINUX_IMAGE) \
		--initrd $(INITRD) \
		--stub $(STUB_BIN) \
		--append "console=hvc0 quiet" \
		--elf $(LINUX_BUILD)/vmlinux \
		--tool-gdb $(GDB) \
		--tool-nm $(NM) \
		--gdb-socket $(TARGET)/gdb.sock \
		-o $(TARGET)/
	$(CONVERT_BIN) -o $(MEM_IMAGE) 0x80000000:$(CHECKPOINT)

clean:
	rm -rf $(TARGET)/*
