# Makefile — GoboLinux Live Builder (Porteus-style)
# ─────────────────────────────────────────────────────────────────────────────
# Tujuan: Membangun GoboLinux versi live portable dengan struktur folder Porteus
# Input : GoboLinux-017.01-x86_64.iso (unduh dari gobolinux.org)
# Output: folder porteus-gobolinux/ siap di-deploy ke USB atau di-burn ke ISO

SHELL    := /bin/bash
SCRIPTS  := $(shell pwd)/scripts
OUTPUT   := $(shell pwd)/output/porteus-gobolinux
GOBO_ISO ?= GoboLinux-017.01-x86_64.iso
COMP     ?= xz

.PHONY: all help download build initrd usb iso clean

all: build initrd
	@echo "Build selesai. Jalankan: make usb DEV=/dev/sdX"

help:
	@echo "GoboLinux Live Builder (Porteus-style)"
	@echo ""
	@echo "  make download       Unduh GoboLinux 017.01 ISO"
	@echo "  make build          Ekstrak ISO dan bagi menjadi modul .xzm"
	@echo "    GOBO_ISO=file.iso  (default: GoboLinux-017.01-x86_64.iso)"
	@echo "    COMP=xz|zstd|lz4   kompresi modul"
	@echo "  make initrd         Modifikasi initrd agar bisa mount .xzm"
	@echo "  make usb DEV=/dev/sdX  Instal ke USB drive"
	@echo "  make iso            Buat file ISO bootable"
	@echo "  make clean          Hapus output"

download:
	@echo "Mengunduh GoboLinux 017.01..."
	@if [ -f "$(GOBO_ISO)" ]; then \
	    echo "  Sudah ada: $(GOBO_ISO)"; \
	else \
	    wget -O "$(GOBO_ISO)" \
	        "https://gobolinux.org/downloads/GoboLinux-017.01-x86_64.iso" || \
	    wget -O "$(GOBO_ISO)" \
	        "https://sourceforge.net/projects/gobolinux/files/latest/download"; \
	fi

build:
	@[ "$(shell id -u)" = "0" ] || { echo "Perlu root: sudo make build"; exit 1; }
	@[ -f "$(GOBO_ISO)" ] || { echo "ISO tidak ada. Jalankan: make download"; exit 1; }
	@chmod +x $(SCRIPTS)/*.sh
	@COMP=$(COMP) bash $(SCRIPTS)/build-gobo-live.sh "$(GOBO_ISO)" "$(OUTPUT)"

initrd:
	@[ "$(shell id -u)" = "0" ] || { echo "Perlu root: sudo make initrd"; exit 1; }
	@ORIG="$(OUTPUT)/boot/syslinux/initrd-gobo-orig.xz"; \
	OUT="$(OUTPUT)/boot/syslinux/initrd.xz"; \
	if [ -f "$$ORIG" ]; then \
	    bash $(SCRIPTS)/modify-initrd.sh "$$ORIG" "$$OUT"; \
	else \
	    echo "initrd asli tidak ditemukan: $$ORIG"; \
	    echo "Jalankan dulu: sudo make build"; \
	fi

usb:
	@[ -n "$(DEV)" ] || { echo "Tentukan device: make usb DEV=/dev/sdX"; exit 1; }
	@sudo bash $(SCRIPTS)/install-deploy.sh usb "$(DEV)"

iso:
	@sudo bash $(SCRIPTS)/install-deploy.sh iso \
	    "$(shell pwd)/output/GoboLinux-Porteus-live.iso"

clean:
	@echo "Menghapus output..."
	@rm -rf $(OUTPUT) output/GoboLinux-Porteus-live.iso
