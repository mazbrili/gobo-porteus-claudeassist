#!/bin/bash
# build-gobo-live.sh
# ─────────────────────────────────────────────────────────────────────────────
# Membangun GoboLinux Live dalam struktur folder Porteus
#
# Input  : GoboLinux-017.01-x86_64.iso (unduh dari gobolinux.org)
# Output : folder porteus-gobolinux/ siap di-copy ke USB / di-burn ke ISO
#
# Struktur output (mengikuti Porteus persis):
#   porteus-gobolinux/
#   ├── boot/
#   │   └── syslinux/
#   │       ├── vmlinuz          ← kernel GoboLinux
#   │       ├── initrd.xz        ← initrd GoboLinux (dimodifikasi)
#   │       └── porteus.cfg      ← konfigurasi bootloader
#   ├── EFI/boot/bootx64.efi     ← UEFI support
#   └── porteus/
#       ├── base/
#       │   ├── 000-kernel.xzm   ← Programs/Linux/ + firmware
#       │   ├── 001-base.xzm     ← Glibc, Bash, Coreutils, dll
#       │   ├── 002-gobo-tools.xzm ← Scripts GoboLinux, Compile, Manager
#       │   └── 003-xorg.xzm     ← Xorg + driver dasar
#       ├── modules/             ← modul ekstra (kosong awal)
#       ├── optional/            ← modul opsional
#       └── changes/             ← persistent changes
#
# Penggunaan:
#   sudo bash build-gobo-live.sh [GoboLinux-017.01-x86_64.iso] [output_dir]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Konfigurasi ──────────────────────────────────────────────────────────────
GOBO_ISO="${1:-GoboLinux-017.01-x86_64.iso}"
OUTPUT_DIR="${2:-$(dirname "$0")/../output/porteus-gobolinux}"
WORK_DIR="${TMPDIR:-/tmp}/gobo-live-build-$$"
COMP="${COMP:-xz}"           # Kompresi: xz (kompatibel) atau zstd (lebih cepat)
BLOCK_SIZE="${BLOCK_SIZE:-256K}"  # Block size squashfs (Porteus default)

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Cek dependensi ───────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in mksquashfs unsquashfs xorriso syslinux file; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        die "Dependensi tidak ditemukan: ${missing[*]}
        Install: sudo apt install squashfs-tools xorriso syslinux-utils"
    fi
}

# ── Mount ISO GoboLinux ──────────────────────────────────────────────────────
mount_iso() {
    log "Mounting ISO GoboLinux: $GOBO_ISO"
    [ -f "$GOBO_ISO" ] || die "ISO tidak ditemukan: $GOBO_ISO
    Unduh dari: https://gobolinux.org/downloads.html"

    mkdir -p "$WORK_DIR/iso-mount"
    mount -o loop,ro "$GOBO_ISO" "$WORK_DIR/iso-mount"
    log "ISO ter-mount di $WORK_DIR/iso-mount"

    # Tampilkan isi ISO untuk referensi
    log "Isi ISO GoboLinux:"
    ls -la "$WORK_DIR/iso-mount/"
}

# ── Ekstrak squashfs GoboLinux dari ISO ──────────────────────────────────────
extract_gobo_squashfs() {
    log "Mencari squashfs GoboLinux dalam ISO..."
    mkdir -p "$WORK_DIR/gobo-root"

    # GoboLinux 017 menyimpan filesystem di:
    # - /GoboLinux/GoboLinuxFS (squashfs berisi seluruh /Programs)
    # - atau /live/filesystem.squashfs (format live CD standar)
    local sqfs=""
    for candidate in \
        "$WORK_DIR/iso-mount/GoboLinux/GoboLinuxFS" \
        "$WORK_DIR/iso-mount/live/filesystem.squashfs" \
        "$WORK_DIR/iso-mount/GoboLinux/filesystem.squashfs" \
        "$WORK_DIR/iso-mount/"*.squashfs
    do
        if [ -f "$candidate" ]; then
            sqfs="$candidate"
            break
        fi
    done

    if [ -z "$sqfs" ]; then
        # Scan semua squashfs dalam ISO
        sqfs=$(find "$WORK_DIR/iso-mount" -name "*.squashfs" 2>/dev/null | head -1 || true)
    fi

    [ -n "$sqfs" ] || die "Squashfs GoboLinux tidak ditemukan dalam ISO.
    Coba ekstrak manual: unsquashfs -d $WORK_DIR/gobo-root <path/ke/squashfs>"

    log "Mengekstrak squashfs: $sqfs"
    log "Ini membutuhkan waktu beberapa menit..."
    unsquashfs -d "$WORK_DIR/gobo-root" "$sqfs"

    log "Ekstraksi selesai. Isi root GoboLinux:"
    ls -la "$WORK_DIR/gobo-root/"
}

# ── Salin kernel & initrd ────────────────────────────────────────────────────
setup_boot() {
    log "Menyiapkan boot files..."
    local boot_dst="$OUTPUT_DIR/boot/syslinux"
    mkdir -p "$boot_dst"

    # Cari vmlinuz di ISO GoboLinux
    # GoboLinux 017 biasanya meletakkan kernel di /boot/ dalam squashfs
    # atau langsung di root ISO
    local vmlinuz=""
    for candidate in \
        "$WORK_DIR/iso-mount/boot/vmlinuz" \
        "$WORK_DIR/iso-mount/boot/vmlinuz-"* \
        "$WORK_DIR/gobo-root/System/Kernel/Boot/vmlinuz" \
        "$WORK_DIR/gobo-root/Programs/Linux/"*/boot/vmlinuz
    do
        if [ -f "$candidate" ]; then
            vmlinuz="$candidate"
            break
        fi
    done

    local initrd=""
    for candidate in \
        "$WORK_DIR/iso-mount/boot/initrd.img" \
        "$WORK_DIR/iso-mount/boot/initrd"* \
        "$WORK_DIR/iso-mount/boot/initramfs"*
    do
        if [ -f "$candidate" ]; then
            initrd="$candidate"
            break
        fi
    done

    if [ -n "$vmlinuz" ]; then
        cp "$vmlinuz" "$boot_dst/vmlinuz"
        log "  vmlinuz: $vmlinuz -> $boot_dst/vmlinuz"
    else
        warn "vmlinuz tidak ditemukan otomatis. Salin manual ke $boot_dst/vmlinuz"
    fi

    if [ -n "$initrd" ]; then
        # Initrd GoboLinux perlu dimodifikasi agar bisa mount .xzm Porteus-style
        # Untuk tahap ini, salin dulu aslinya
        cp "$initrd" "$boot_dst/initrd-gobo-orig.xz"
        log "  initrd asli disimpan: $boot_dst/initrd-gobo-orig.xz"
        log "  Modifikasi initrd dengan: bash modify-initrd.sh"
    else
        warn "initrd tidak ditemukan otomatis."
    fi

    # Salin syslinux.bin dan file pendukung jika ada
    for f in "$WORK_DIR/iso-mount/boot/isolinux/"* \
             "$WORK_DIR/iso-mount/boot/syslinux/"*; do
        [ -f "$f" ] && cp "$f" "$boot_dst/" 2>/dev/null || true
    done

    # EFI
    local efi_src=""
    for candidate in \
        "$WORK_DIR/iso-mount/EFI" \
        "$WORK_DIR/iso-mount/efi"
    do
        [ -d "$candidate" ] && efi_src="$candidate" && break
    done
    if [ -n "$efi_src" ]; then
        cp -a "$efi_src/." "$OUTPUT_DIR/EFI/"
        log "  EFI files disalin"
    fi
}

# ── Fungsi pembantu: buat .xzm dari direktori staging ────────────────────────
make_xzm() {
    local staging="$1"
    local output_xzm="$2"
    local label="$3"

    log "Membuat $label ..."

    if [ -z "$(ls -A "$staging" 2>/dev/null)" ]; then
        warn "$label: staging kosong, dilewati"
        return 0
    fi

    mksquashfs "$staging" "$output_xzm" \
        -b "$BLOCK_SIZE" \
        -comp "$COMP" \
        -noappend \
        -no-progress \
        ${COMP:+-Xbcj x86} 2>/dev/null || \
    mksquashfs "$staging" "$output_xzm" \
        -b "$BLOCK_SIZE" \
        -comp "$COMP" \
        -noappend \
        -no-progress

    local size
    size=$(du -sh "$output_xzm" | cut -f1)
    log "  → $output_xzm ($size)"
}

# ── 000-kernel.xzm ──────────────────────────────────────────────────────────
build_kernel_module() {
    log "=== Membangun 000-kernel.xzm ==="
    local staging="$WORK_DIR/staging/000-kernel"
    mkdir -p "$staging"

    # Cari versi kernel dari gobo root
    local kernel_ver=""
    if [ -d "$WORK_DIR/gobo-root/Programs/Linux" ]; then
        kernel_ver=$(ls "$WORK_DIR/gobo-root/Programs/Linux/" \
            | grep -v Current | sort -V | tail -1)
    fi

    if [ -n "$kernel_ver" ]; then
        log "  Kernel GoboLinux: $kernel_ver"
        # Salin seluruh Programs/Linux/<ver>/
        mkdir -p "$staging/Programs/Linux"
        cp -a "$WORK_DIR/gobo-root/Programs/Linux/$kernel_ver" \
              "$staging/Programs/Linux/"
        ln -snf "$kernel_ver" "$staging/Programs/Linux/Current"

        # System/Kernel symlinks
        mkdir -p "$staging/System/Kernel"
        ln -snf "/Programs/Linux/Current/boot"    "$staging/System/Kernel/Boot"
        ln -snf "/Programs/Linux/Current/modules" "$staging/System/Kernel/Modules"
    else
        warn "Programs/Linux tidak ditemukan — isi kernel dari /boot dan /lib/modules"
        mkdir -p "$staging/Programs/Linux/current"/{boot,modules,firmware}

        # Fallback: ambil dari boot/ di squashfs root
        [ -d "$WORK_DIR/gobo-root/boot" ] && \
            cp -a "$WORK_DIR/gobo-root/boot/." \
                  "$staging/Programs/Linux/current/boot/"
        [ -d "$WORK_DIR/gobo-root/lib/modules" ] && \
            cp -a "$WORK_DIR/gobo-root/lib/modules/." \
                  "$staging/Programs/Linux/current/modules/"
        [ -d "$WORK_DIR/gobo-root/lib/firmware" ] && \
            cp -a "$WORK_DIR/gobo-root/lib/firmware/." \
                  "$staging/Programs/Linux/current/firmware/"
    fi

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/000-kernel.xzm" "000-kernel.xzm"
}

# ── 001-base.xzm ─────────────────────────────────────────────────────────────
# Paket base GoboLinux: Glibc, Bash, Coreutils, BusyBox, Udev, dll
BASE_PROGRAMS=(
    Glibc Bash BusyBox Coreutils Util-linux
    Kmod E2fsprogs Shadow Kbd Procps
    Sed Grep Gawk Findutils Diffutils
    Which File Less Tar Gzip Bzip2 Xz
    PCRE PCRE2 Readline Ncurses Zlib
    Openssl Ca-certificates Curl
    Udev Eudev Util-linux
)

build_base_module() {
    log "=== Membangun 001-base.xzm ==="
    local staging="$WORK_DIR/staging/001-base"
    mkdir -p "$staging"

    if [ ! -d "$WORK_DIR/gobo-root/Programs" ]; then
        warn "Programs/ tidak ditemukan di gobo-root"
        return 0
    fi

    # Salin program base
    for prog in "${BASE_PROGRAMS[@]}"; do
        local prog_src="$WORK_DIR/gobo-root/Programs/$prog"
        if [ -d "$prog_src" ]; then
            mkdir -p "$staging/Programs"
            cp -a "$prog_src" "$staging/Programs/"
            log "  + $prog"
        fi
    done

    # Salin System/Links dan struktur System lainnya (kecuali Kernel)
    if [ -d "$WORK_DIR/gobo-root/System" ]; then
        mkdir -p "$staging/System"
        for d in Links Settings Environment; do
            local src="$WORK_DIR/gobo-root/System/$d"
            [ -d "$src" ] && cp -a "$src" "$staging/System/"
        done
    fi

    # Salin Users/root skeleton
    if [ -d "$WORK_DIR/gobo-root/Users" ]; then
        cp -a "$WORK_DIR/gobo-root/Users" "$staging/"
    fi

    # Salin Data/
    if [ -d "$WORK_DIR/gobo-root/Data" ]; then
        cp -a "$WORK_DIR/gobo-root/Data" "$staging/"
    fi

    # Mount points placeholder
    for d in Mount proc sys dev tmp run; do
        mkdir -p "$staging/$d"
    done

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/001-base.xzm" "001-base.xzm"
}

# ── 002-gobo-tools.xzm ───────────────────────────────────────────────────────
GOBO_PROGRAMS=(
    Scripts Compile Manager GoboNet
    Python3 Git Perl
    Linux-PAM OpenSSH Sudo
    GoboHide
)

build_tools_module() {
    log "=== Membangun 002-gobo-tools.xzm ==="
    local staging="$WORK_DIR/staging/002-gobo-tools"
    mkdir -p "$staging/Programs"

    for prog in "${GOBO_PROGRAMS[@]}"; do
        local prog_src="$WORK_DIR/gobo-root/Programs/$prog"
        if [ -d "$prog_src" ]; then
            cp -a "$prog_src" "$staging/Programs/"
            log "  + $prog"
        fi
    done

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/002-gobo-tools.xzm" "002-gobo-tools.xzm"
}

# ── 003-xorg.xzm ─────────────────────────────────────────────────────────────
XORG_PROGRAMS=(
    Xorg Xterm Xinit
    Mesa Libdrm Libglvnd
    FontConfig Freetype
    Libx11 Libxext Libxrender Libxft
    Pixman Cairo Pango
)

build_xorg_module() {
    log "=== Membangun 003-xorg.xzm ==="
    local staging="$WORK_DIR/staging/003-xorg"
    mkdir -p "$staging/Programs"

    for prog in "${XORG_PROGRAMS[@]}"; do
        local prog_src="$WORK_DIR/gobo-root/Programs/$prog"
        if [ -d "$prog_src" ]; then
            cp -a "$prog_src" "$staging/Programs/"
            log "  + $prog"
        fi
    done

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/003-xorg.xzm" "003-xorg.xzm"
}

# ── 004-desktop.xzm (AwesomeWM — default GoboLinux 017) ─────────────────────
DESKTOP_PROGRAMS=(
    Awesome Lua
    Alacritty Firefox Thunar
    Gtk+ Glib Atk
    Enlightenment  # fallback jika tidak ada Awesome
    Notification-daemon
)

build_desktop_module() {
    log "=== Membangun 004-desktop.xzm ==="
    local staging="$WORK_DIR/staging/004-desktop"
    mkdir -p "$staging/Programs"

    for prog in "${DESKTOP_PROGRAMS[@]}"; do
        local prog_src="$WORK_DIR/gobo-root/Programs/$prog"
        if [ -d "$prog_src" ]; then
            cp -a "$prog_src" "$staging/Programs/"
            log "  + $prog"
        fi
    done

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/004-desktop.xzm" "004-desktop.xzm"
}

# ── Buat porteus.cfg (konfigurasi bootloader) ────────────────────────────────
create_porteus_cfg() {
    log "Membuat porteus.cfg..."
    cat > "$OUTPUT_DIR/boot/syslinux/porteus.cfg" << 'SYSLINUX_EOF'
# GoboLinux Live — Porteus-style boot config
# Dibuat oleh build-gobo-live.sh

PROMPT 0
TIMEOUT 90
DEFAULT graphics

UI vesamenu.c32
MENU TITLE GoboLinux 017.01 Live (Porteus-style)
MENU BACKGROUND porteus.png
MENU WIDTH 78
MENU MARGIN 4
MENU ROWS 8
MENU VSHIFT 10
MENU TIMEOUTROW 20
MENU TABMSGROW 18

# ── Mode grafis (AwesomeWM) ──────────────────────────────────────────────────
LABEL graphics
  MENU LABEL GoboLinux Graphical (AwesomeWM)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz \
    from=/porteus \
    changes=/porteus/changes \
    gobo=1 \
    quiet splash

# ── Mode teks ────────────────────────────────────────────────────────────────
LABEL text
  MENU LABEL GoboLinux Text Mode
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz \
    from=/porteus \
    changes=/porteus/changes \
    gobo=1 \
    3

# ── Copy to RAM ──────────────────────────────────────────────────────────────
LABEL copy2ram
  MENU LABEL GoboLinux (Copy to RAM)
  MENU HELP Salin semua modul ke RAM sebelum boot. Butuh ~2GB RAM.
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz \
    from=/porteus \
    changes=/porteus/changes \
    gobo=1 \
    copy2ram

# ── Tanpa perubahan (fresh) ───────────────────────────────────────────────────
LABEL fresh
  MENU LABEL GoboLinux Always Fresh (no changes saved)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz \
    from=/porteus \
    gobo=1 \
    nomagic

# ── Reboot & matikan ─────────────────────────────────────────────────────────
LABEL reboot
  MENU LABEL Reboot
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL Power Off
  COM32 poweroff.c32
SYSLINUX_EOF

    log "  porteus.cfg dibuat"
}

# ── Buat grub.cfg untuk UEFI ─────────────────────────────────────────────────
create_grub_cfg() {
    log "Membuat grub.cfg (UEFI)..."
    mkdir -p "$OUTPUT_DIR/boot/grub"
    cat > "$OUTPUT_DIR/boot/grub/grub.cfg" << 'GRUB_EOF'
# GoboLinux Live — GRUB2 config (UEFI)

set default=0
set timeout=9

menuentry "GoboLinux Graphical (AwesomeWM)" --class gobolinux {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus changes=/porteus/changes gobo=1 quiet splash
    initrd /boot/syslinux/initrd.xz
}

menuentry "GoboLinux Text Mode" --class gobolinux {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus changes=/porteus/changes gobo=1 3
    initrd /boot/syslinux/initrd.xz
}

menuentry "GoboLinux Copy to RAM" --class gobolinux {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus changes=/porteus/changes gobo=1 copy2ram
    initrd /boot/syslinux/initrd.xz
}

menuentry "GoboLinux Always Fresh" --class gobolinux {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus gobo=1 nomagic
    initrd /boot/syslinux/initrd.xz
}

menuentry "Reboot" { reboot }
menuentry "Shutdown" { halt }
GRUB_EOF
}

# ── Buat README di output ────────────────────────────────────────────────────
create_readme() {
    cat > "$OUTPUT_DIR/README.txt" << 'README_EOF'
GoboLinux 017.01 Live — Porteus-style
======================================

Struktur folder ini mengikuti konvensi Porteus.

INSTALASI KE USB:
  Linux:
    sudo dd if=GoboLinux-Porteus.iso of=/dev/sdX bs=4M status=progress
  Atau (lebih aman):
    sudo cp -r porteus-gobolinux/* /mnt/usb/
    sudo syslinux --install /dev/sdX1

STRUKTUR:
  boot/syslinux/vmlinuz     ← Kernel Linux
  boot/syslinux/initrd.xz   ← Initial ramdisk
  boot/syslinux/porteus.cfg ← Konfigurasi bootloader (Syslinux)
  boot/grub/grub.cfg        ← Konfigurasi bootloader (GRUB2 UEFI)
  porteus/base/             ← Modul .xzm wajib (GoboLinux filesystem)
  porteus/modules/          ← Modul tambahan (aktif setiap boot)
  porteus/optional/         ← Modul opsional (aktif manual/cheatcode)
  porteus/changes/          ← Perubahan persistent

MENAMBAH MODUL:
  Salin file .xzm ke porteus/modules/ → aktif setiap boot
  Salin ke porteus/optional/ → aktif dengan cheatcode load=nama.xzm

BOOT CHEATCODES:
  gobo=1        Aktifkan GoboLinux link builder
  copy2ram      Salin semua modul ke RAM
  nomagic       Boot fresh, tanpa changes
  changes=PATH  Path custom untuk menyimpan perubahan
README_EOF
}

# ── Ringkasan output ─────────────────────────────────────────────────────────
show_summary() {
    log "=== BUILD SELESAI ==="
    echo ""
    echo "Output di: $OUTPUT_DIR"
    echo ""
    find "$OUTPUT_DIR" -name "*.xzm" -o -name "vmlinuz" -o -name "initrd*" \
         -o -name "porteus.cfg" -o -name "grub.cfg" 2>/dev/null \
        | sort | while read -r f; do
            size=$(du -sh "$f" 2>/dev/null | cut -f1)
            echo "  $size  ${f#$OUTPUT_DIR/}"
        done
    echo ""
    echo "Langkah selanjutnya:"
    echo "  1. Unduh ISO:   wget https://gobolinux.org/downloads/ -O GoboLinux-017.01-x86_64.iso"
    echo "  2. Build:       sudo bash $0 GoboLinux-017.01-x86_64.iso"
    echo "  3. Install USB: sudo bash install-to-usb.sh /dev/sdX"
    echo "  4. Atau burn:   sudo bash make-iso.sh"
}

# ── MAIN ─────────────────────────────────────────────────────────────────────
main() {
    [ "$(id -u)" = "0" ] || die "Harus dijalankan sebagai root (sudo)"
    check_deps

    log "GoboLinux Live Builder (Porteus-style)"
    log "ISO  : $GOBO_ISO"
    log "Output: $OUTPUT_DIR"
    log "Kompresi: $COMP, Block: $BLOCK_SIZE"

    trap "umount '$WORK_DIR/iso-mount' 2>/dev/null || true; rm -rf '$WORK_DIR'" EXIT
    mkdir -p "$WORK_DIR"

    mount_iso
    extract_gobo_squashfs
    setup_boot

    build_kernel_module
    build_base_module
    build_tools_module
    build_xorg_module
    build_desktop_module

    create_porteus_cfg
    create_grub_cfg
    create_readme

    show_summary
}

main "$@"
