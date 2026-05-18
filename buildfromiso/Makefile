# Makefile — GoboLinux 017 Live Builder (Porteus-style)
SHELL    := /bin/bash
SCRIPTS  := $(shell pwd)/scripts
OUTPUT   := $(shell pwd)/output/porteux-gobolinux
GOBO017_ISO ?= GoboLinux-017.01-x86_64.iso
GOBO016_ISO  ?= GoboLinux-016.01-x86_64.iso
SLAX_ISO     ?= $(firstword $(wildcard slax-*.iso))
PORTEUS_ISO  ?= $(firstword $(wildcard Porteus*.iso porteus*.iso))
PORTEUX_ISO  ?= $(or $(PORTEUS_ISO),$(firstword $(wildcard Porteux*.iso porteux*.iso)))
COMP         ?= xz

.PHONY: all help download download-016 download-porteus build kernel initrd usb iso clean

all: build initrd
	@echo ""
	@echo "Build selesai. Jalankan: sudo make usb DEV=/dev/sdX"

help:
	@echo "GoboLinux 017 Live Builder (Porteus-style)"
	@echo ""
	@echo "Sumber:"
	@echo "  GoboLinux 017 ISO  → squashfs filesystem (Programs/, System/)"
	@echo "  Porteux/Porteus ISO → syslinux files + BusyBox statik"
	@echo ""
	@echo "Target:"
	@echo "  make download              Unduh GoboLinux 017.01 ISO"
	@echo "  make download-porteus      Info unduh Porteus ISO"
	@echo "  make build                 Ekstrak ISO → modul .xzm + copy kernel"
	@echo "    GOBO017_ISO=...          (default: GoboLinux-017.01-x86_64.iso)"
	@echo "    PORTEUS_ISO=...          ISO Porteus (auto-detect Porteus*.iso)"
	@echo "    COMP=xz|zstd             kompresi modul"
	@echo "  make kernel                Salin kernel dari GoboLinux ISO ke output"
	@echo "    GOBO017_ISO=...          ISO sumber kernel"
	@echo "  make initrd                Bangun initramfs (BusyBox dari Porteus)"
	@echo "  make iso                   Buat ISO bootable"
	@echo "  make usb DEV=/dev/sdX      Instal ke USB"
	@echo "  make clean                 Hapus output"

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

# ── Salin kernel dari GoboLinux ISO ─────────────────────────────────────────
# vmlinuz wajib ada sebelum make iso bisa berjalan.
# build-gobo-live.sh sudah mencoba mendeteksi otomatis, tapi kadang gagal.
# Target ini menyalin kernel secara eksplisit.
kernel:
	@[ -f "$(GOBO017_ISO)" ] || { 	    echo "ERROR: ISO tidak ada: $(GOBO017_ISO)"; 	    echo "Jalankan: make download"; exit 1; 	}
	@VMLINUZ="$(OUTPUT)/boot/syslinux/vmlinuz"; 	if [ -f "$$VMLINUZ" ]; then 	    echo "vmlinuz sudah ada: $$VMLINUZ ($(shell du -sh $(OUTPUT)/boot/syslinux/vmlinuz 2>/dev/null | cut -f1))"; 	    exit 0; 	fi; 	echo "Menyalin kernel dari $(GOBO017_ISO)..."; 	TMP_MNT=$$(mktemp -d); 	mount -o loop,ro "$(GOBO017_ISO)" "$$TMP_MNT" 2>/dev/null || { 	    echo "ERROR: Gagal mount ISO (perlu root: sudo make kernel)"; 	    rmdir "$$TMP_MNT"; exit 1; 	}; 	mkdir -p "$(OUTPUT)/boot/syslinux"; 	KERNEL_FILE=""; 	for candidate in 	    "$$TMP_MNT/isolinux/kernel" 	    "$$TMP_MNT/boot/isolinux/kernel" 	    "$$TMP_MNT/isolinux/vmlinuz" 	    "$$TMP_MNT/boot/vmlinuz"; 	do 	    if [ -f "$$candidate" ]; then 	        SZ=$$(stat -c%s "$$candidate" 2>/dev/null || echo 0); 	        if [ "$$SZ" -gt 1048576 ]; then 	            KERNEL_FILE="$$candidate"; break; 	        fi; 	    fi; 	done; 	if [ -n "$$KERNEL_FILE" ]; then 	    cp "$$KERNEL_FILE" "$$VMLINUZ"; 	    echo "OK: kernel disalin dari $${KERNEL_FILE#$$TMP_MNT} ($(shell stat -c%s $(GOBO017_ISO) 2>/dev/null || echo ?) bytes)"; 	    echo "   -> $$VMLINUZ ($$(du -sh "$$VMLINUZ" | cut -f1))"; 	else 	    echo "ERROR: kernel tidak ditemukan dalam ISO"; 	    echo "Isi isolinux/ dalam ISO:"; 	    ls "$$TMP_MNT/isolinux/" 2>/dev/null || ls "$$TMP_MNT/boot/isolinux/" 2>/dev/null; 	    umount "$$TMP_MNT" 2>/dev/null; rmdir "$$TMP_MNT"; exit 1; 	fi; 	umount "$$TMP_MNT" 2>/dev/null; rmdir "$$TMP_MNT"

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
	@INITRD_ORIG="$(OUTPUT)/boot/syslinux/initrd-gobo-orig"; \
	INITRD_OUT="$(OUTPUT)/boot/syslinux/initrd.xz"; \
	if [ ! -f "$$INITRD_ORIG" ]; then \
	    echo "ERROR: $$INITRD_ORIG tidak ada"; \
	    echo "Jalankan dulu: sudo make build"; \
	    exit 1; \
	fi; \
	echo "GoboLinux 017 initrd : $$INITRD_ORIG"; \
	echo "Format               : $$(file -b "$$INITRD_ORIG" | cut -c1-60)"; \
	PORTEUX_ARG=""; \
	PORTEUX_INITRD_FILE="$(OUTPUT)/boot/syslinux/porteux-initrd.xz"; \
	if [ -f "$$PORTEUX_INITRD_FILE" ]; then \
	    PORTEUX_ARG="--porteux-initrd $$PORTEUX_INITRD_FILE"; \
	    echo "Porteux initrd (auto): $$PORTEUX_INITRD_FILE"; \
	elif [ -n "$(PORTEUX_ISO)" ] && [ -f "$(PORTEUX_ISO)" ]; then \
	    PORTEUX_ARG="--porteux-initrd $(PORTEUX_ISO)"; \
	    echo "Porteux ISO          : $(PORTEUX_ISO)"; \
	else \
	    echo "WARN: porteux-initrd.xz tidak ada di output."; \
	    echo "  Jalankan dulu: sudo make build PORTEUX_ISO=/path/porteux.iso"; \
	    echo "  Atau: PORTEUX_ISO=/path/porteux.iso make initrd"; \
	fi; \
	bash $(SCRIPTS)/build-initrd.sh \
	    --gobo017initrd "$$INITRD_ORIG" \
	    $$PORTEUX_ARG \
	    --output "$$INITRD_OUT"


usb:
	@[ -n "$(DEV)" ] || { echo "Gunakan: make usb DEV=/dev/sdX"; exit 1; }
	@sudo bash $(SCRIPTS)/install-deploy.sh usb "$(DEV)"

iso:
	@VMLINUZ="$(OUTPUT)/boot/syslinux/vmlinuz"; \
	if [ ! -f "$$VMLINUZ" ]; then \
	    echo "vmlinuz tidak ada di $$VMLINUZ"; \
	    echo "Menjalankan: sudo make kernel ..."; \
	    sudo $(MAKE) kernel GOBO017_ISO=$(GOBO017_ISO); \
	fi
	@sudo bash $(SCRIPTS)/install-deploy.sh iso \
	    "$$(pwd)/output/GoboLinux-porteux-live.iso"

clean:
	@rm -rf $(OUTPUT) output/.gobo-root-path output/.busybox-path output/GoboLinux-porteux-live.iso
	@echo "Note: gobo-root di /tmp dibiarkan — hapus manual jika perlu"
	@echo "Output dibersihkan"
