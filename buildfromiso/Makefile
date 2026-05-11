# Makefile — GoboLinux 017 Live Builder (Porteus-style)
SHELL    := /bin/bash
SCRIPTS  := $(shell pwd)/scripts
OUTPUT   := $(shell pwd)/output/porteus-gobolinux
GOBO017_ISO ?= GoboLinux-017.01-x86_64.iso
GOBO016_ISO  ?= GoboLinux-016.01-x86_64.iso
SLAX_ISO     ?= $(firstword $(wildcard slax-*.iso))
PORTEUS_ISO  ?= $(firstword $(wildcard Porteus*.iso porteus*.iso))
COMP         ?= xz

.PHONY: all help download download-016 build initrd usb iso clean

all: build initrd
	@echo ""
	@echo "Build selesai. Jalankan: sudo make usb DEV=/dev/sdX"

help:
	@echo "GoboLinux 017 Live Builder (Porteus-style)"
	@echo ""
	@echo "Sumber:"
	@echo "  GoboLinux 017 ISO  → squashfs filesystem (Programs/, System/)"
	@echo "  GoboLinux 016 ISO  → referensi struktur initrd (startGoboLinux)"
	@echo "  Slax ISO           → BusyBox statik untuk initramfs"
	@echo ""
	@echo "Target:"
	@echo "  make download         Unduh GoboLinux 017.01 ISO"
	@echo "  make download-016     Unduh GoboLinux 016.01 ISO (referensi initrd)"
	@echo "  make build            Ekstrak 017 ISO → modul .xzm Porteus-style"
	@echo "    GOBO017_ISO=...      (default: GoboLinux-017.01-x86_64.iso)"
	@echo "    COMP=xz|zstd         kompresi modul"
	@echo "  make initrd           Bangun initramfs dari BusyBox Slax"
	@echo "                        + logika init GoboLinux 016"
	@echo "    SLAX_ISO=...         Slax ISO (wajib)"
	@echo "    GOBO016_ISO=...      GoboLinux 016 ISO (opsional, untuk referensi)"
	@echo "  make usb DEV=/dev/sdX Instal ke USB"
	@echo "  make iso              Buat ISO bootable"
	@echo "  make clean            Hapus output"

download:
	@if [ -f "$(GOBO017_ISO)" ]; then \
	    echo "Sudah ada: $(GOBO017_ISO)"; \
	else \
	    wget -O "$(GOBO017_ISO)" \
	        "https://gobolinux.org/downloads/GoboLinux-017.01-x86_64.iso"; \
	fi

download-porteus:
	@echo "Unduh Porteus dari https://porteus.org/porteus-downloads.html"
	@echo "Pilih versi x86_64, simpan di direktori ini sebagai Porteus-*.iso"
	@echo "Porteus ISO yang ada: $(PORTEUS_ISO)"

download-016:
	@if [ -f "$(GOBO016_ISO)" ]; then \
	    echo "Sudah ada: $(GOBO016_ISO)"; \
	else \
	    wget -O "$(GOBO016_ISO)" \
	        "https://gobolinux.org/iso/GoboLinux-016.01-x86_64.iso"; \
	fi

build:
	@[ "$$(id -u)" = "0" ] || { echo "Perlu root: sudo make build"; exit 1; }
	@[ -f "$(GOBO017_ISO)" ] || { \
	    echo "ISO tidak ada: $(GOBO017_ISO)"; \
	    echo "Jalankan: make download"; exit 1; \
	}
	@chmod +x $(SCRIPTS)/*.sh
	@PORTEUS_ISO="$(PORTEUS_ISO)" COMP=$(COMP) bash $(SCRIPTS)/build-gobo-live.sh "$(GOBO017_ISO)" "$(OUTPUT)"

initrd:
	@[ "$$(id -u)" = "0" ] || { echo "Perlu root: sudo make initrd"; exit 1; }
	@# initramfs GoboLinux 017 dihasilkan oleh make build
	@INITRD_ORIG="$(OUTPUT)/boot/syslinux/initrd-gobo-orig"; \
	INITRD_OUT="$(OUTPUT)/boot/syslinux/initrd.xz"; \
	if [ ! -f "$$INITRD_ORIG" ]; then \
	    echo "ERROR: $$INITRD_ORIG tidak ada"; \
	    echo "Jalankan dulu: sudo make build"; \
	    exit 1; \
	fi; \
	echo "Menggunakan initramfs GoboLinux 017: $$INITRD_ORIG"; \
	echo "Format: $$(file -b "$$INITRD_ORIG" | cut -c1-60)"; \
	bash $(SCRIPTS)/build-initrd.sh \
	    --gobo017initrd "$$INITRD_ORIG" \
	    --output "$$INITRD_OUT"


usb:
	@[ -n "$(DEV)" ] || { echo "Gunakan: make usb DEV=/dev/sdX"; exit 1; }
	@sudo bash $(SCRIPTS)/install-deploy.sh usb "$(DEV)"

iso:
	@sudo bash $(SCRIPTS)/install-deploy.sh iso \
	    "$$(pwd)/output/GoboLinux-Porteus-live.iso"

clean:
	@rm -rf $(OUTPUT) output/.gobo-root-path output/GoboLinux-Porteus-live.iso
	@echo "Note: gobo-root di /tmp dibiarkan — hapus manual jika perlu"
	@echo "Output dibersihkan"
