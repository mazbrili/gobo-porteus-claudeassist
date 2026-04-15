#!/bin/bash
# build-gobo-live.sh  —  GoboLinux 017.01  →  struktur folder Porteus
# ─────────────────────────────────────────────────────────────────────────────
# Strategi: SCAN dulu isi ISO secara nyata, baru proses.
# Tidak hardcode nama file apapun dari ISO GoboLinux.
#
# GoboLinux 017.01 memakai:
#   isolinux/kernel      ← bukan vmlinuz
#   isolinux/initramfs   ← bukan initrd.xz, compressed zstd
#   GoboLinux/GoboLinuxFS.squashfs  ← squashfs utama, compressed zstd
#
# Output Porteus-style:
#   porteus-gobolinux/
#   ├── boot/syslinux/
#   │   ├── vmlinuz          ← salin dari isolinux/kernel
#   │   ├── initrd-gobo-orig ← salin dari isolinux/initramfs (asli)
#   │   ├── initrd.xz        ← hasil modify-initrd.sh (dijalankan terpisah)
#   │   └── porteus.cfg
#   ├── EFI/
#   └── porteus/
#       ├── base/
#       │   ├── 000-kernel.xzm
#       │   ├── 001-base.xzm
#       │   ├── 002-gobo-tools.xzm
#       │   ├── 003-xorg.xzm
#       │   └── 004-desktop.xzm
#       ├── modules/
#       ├── optional/
#       └── changes/
#
# Penggunaan:
#   sudo bash build-gobo-live.sh GoboLinux-017.01-x86_64.iso [output_dir]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

GOBO_ISO="${1:-GoboLinux-017.01-x86_64.iso}"
OUTPUT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)/output/porteus-gobolinux}"
WORK_DIR="${TMPDIR:-/tmp}/gobo-live-$$"
COMP="${COMP:-xz}"
BLOCK_SIZE="${BLOCK_SIZE:-256K}"

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' C='\033[0;36m' N='\033[0m'
log()  { echo -e "${G}[$(date +%H:%M:%S)]${N} $*"; }
info() { echo -e "${C}  ↳${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
die()  { echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }

# ── Dependensi ────────────────────────────────────────────────────────────────
check_deps() {
    local miss=()
    for cmd in mksquashfs unsquashfs file; do
        command -v "$cmd" &>/dev/null || miss+=("$cmd")
    done
    [ ${#miss[@]} -eq 0 ] || die "Tidak ada: ${miss[*]}
    Install: sudo apt install squashfs-tools"
    [ "$(id -u)" = "0" ] || die "Harus dijalankan sebagai root (sudo)"
}

# ── Scan dan tampilkan isi ISO ─────────────────────────────────────────────────
scan_iso() {
    log "Scanning isi ISO: $GOBO_ISO"
    [ -f "$GOBO_ISO" ] || die "ISO tidak ditemukan: $GOBO_ISO"

    mkdir -p "$WORK_DIR/iso"
    mount -o loop,ro "$GOBO_ISO" "$WORK_DIR/iso"

    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║         ISI ISO GoboLinux (semua file, 3 level)           ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    find "$WORK_DIR/iso" -maxdepth 3 | sort | while read -r f; do
        local rel="${f#$WORK_DIR/iso}"
        [ -z "$rel" ] && continue
        if [ -d "$f" ]; then
            echo "  📁 $rel/"
        else
            local sz
            sz=$(du -sh "$f" 2>/dev/null | cut -f1)
            local fmt
            fmt=$(file -b "$f" 2>/dev/null | cut -c1-45)
            printf "  📄 %-40s [%6s]  %s\n" "$rel" "$sz" "$fmt"
        fi
    done
    echo ""
}

# ── Deteksi kernel ─────────────────────────────────────────────────────────────
detect_kernel() {
    local found=""
    # Scan semua file, cek magic bytes
    while IFS= read -r -d '' f; do
        local magic
        magic=$(file -b "$f" 2>/dev/null)
        if echo "$magic" | grep -qiE "Linux kernel|bzImage|x86 boot sector|ELF.*executable"; then
            found="$f"; break
        fi
    done < <(find "$WORK_DIR/iso" -not -type d -print0 | sort -z)

    # Fallback: nama file umum
    if [ -z "$found" ]; then
        for candidate in \
            "$WORK_DIR/iso/isolinux/kernel" \
            "$WORK_DIR/iso/boot/isolinux/kernel" \
            "$WORK_DIR/iso/isolinux/vmlinuz" \
            "$WORK_DIR/iso/boot/vmlinuz"
        do
            [ -f "$candidate" ] && { found="$candidate"; break; }
        done
    fi

    echo "$found"
}

# ── Deteksi initramfs ──────────────────────────────────────────────────────────
detect_initramfs() {
    local found=""
    while IFS= read -r -d '' f; do
        local magic
        magic=$(file -b "$f" 2>/dev/null)
        # Jangan ambil kernel
        echo "$magic" | grep -qiE "Linux kernel|bzImage|ELF.*executable" && continue
        if echo "$magic" | grep -qiE "cpio|Zstandard|gzip compressed|XZ compressed|lzma"; then
            found="$f"; break
        fi
    done < <(find "$WORK_DIR/iso" -not -type d -print0 | sort -z)

    if [ -z "$found" ]; then
        for candidate in \
            "$WORK_DIR/iso/isolinux/initramfs" \
            "$WORK_DIR/iso/boot/isolinux/initramfs" \
            "$WORK_DIR/iso/isolinux/initrd" \
            "$WORK_DIR/iso/boot/initrd.img"
        do
            [ -f "$candidate" ] && { found="$candidate"; break; }
        done
    fi

    echo "$found"
}

# ── Deteksi squashfs ───────────────────────────────────────────────────────────
detect_squashfs() {
    local found="" best_size=0
    # Ambil squashfs TERBESAR (itu filesystem utama)
    while IFS= read -r -d '' f; do
        local magic
        magic=$(file -b "$f" 2>/dev/null)
        if echo "$magic" | grep -qi "Squashfs"; then
            local sz
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            if [ "$sz" -gt "$best_size" ]; then
                best_size="$sz"
                found="$f"
            fi
        fi
    done < <(find "$WORK_DIR/iso" -not -type d -print0)

    echo "$found"
}

# ── Setup boot files ──────────────────────────────────────────────────────────
setup_boot() {
    local kernel_src="$1"
    local initramfs_src="$2"
    local dst="$OUTPUT_DIR/boot/syslinux"
    mkdir -p "$dst"

    if [ -n "$kernel_src" ] && [ -f "$kernel_src" ]; then
        cp "$kernel_src" "$dst/vmlinuz"
        info "Kernel  : $(basename "$kernel_src") → boot/syslinux/vmlinuz"
        info "  size  : $(du -sh "$dst/vmlinuz" | cut -f1)"
    else
        warn "Kernel tidak ditemukan otomatis — salin manual ke $dst/vmlinuz"
    fi

    if [ -n "$initramfs_src" ] && [ -f "$initramfs_src" ]; then
        # Simpan asli — modify-initrd.sh akan membuat initrd.xz
        cp "$initramfs_src" "$dst/initrd-gobo-orig"
        info "Initramfs: $(basename "$initramfs_src") → boot/syslinux/initrd-gobo-orig"
        info "  format: $(file -b "$dst/initrd-gobo-orig" | cut -c1-55)"
        info "  size  : $(du -sh "$dst/initrd-gobo-orig" | cut -f1)"
    else
        warn "Initramfs tidak ditemukan otomatis — salin manual ke $dst/initrd-gobo-orig"
    fi

    # Salin file syslinux pendukung (.c32, splash, dll) dari ISO
    for isodir in \
        "$WORK_DIR/iso/isolinux" \
        "$WORK_DIR/iso/boot/isolinux" \
        "$WORK_DIR/iso/boot/syslinux"
    do
        [ -d "$isodir" ] || continue
        find "$isodir" -maxdepth 1 -type f | while read -r f; do
            local bn
            bn="$(basename "$f")"
            # Lewati kernel & initramfs (sudah ditangani)
            case "$bn" in
                kernel|vmlinuz|vmlinuz-*|initramfs|initrd|initrd.*|initramfs.*) continue ;;
            esac
            cp "$f" "$dst/$bn" 2>/dev/null || true
        done
        info "File syslinux dari: $isodir"
    done

    # EFI
    for efidir in "$WORK_DIR/iso/EFI" "$WORK_DIR/iso/efi"; do
        [ -d "$efidir" ] || continue
        cp -a "$efidir/." "$OUTPUT_DIR/EFI/"
        info "EFI disalin dari: $efidir"
        break
    done
}

# ── Ekstrak squashfs ──────────────────────────────────────────────────────────
extract_squashfs() {
    local sqfs="$1"
    log "Mengekstrak squashfs GoboLinux: $(basename "$sqfs")"
    info "Format: $(file -b "$sqfs" | cut -c1-60)"
    info "Ukuran: $(du -sh "$sqfs" | cut -f1)"
    info "Ini bisa memakan waktu beberapa menit..."

    mkdir -p "$WORK_DIR/gobo-root"
    unsquashfs -d "$WORK_DIR/gobo-root" "$sqfs" || \
        die "Gagal ekstrak squashfs.
    Jika error 'zstd not supported', install squashfs-tools >= 4.5:
      sudo apt install squashfs-tools
    Atau build dari source: https://github.com/plougher/squashfs-tools"

    log "Root GoboLinux berhasil diekstrak:"
    ls -la "$WORK_DIR/gobo-root/" | head -15
}

# ── make_xzm ─────────────────────────────────────────────────────────────────
make_xzm() {
    local staging="$1" out="$2" label="$3"

    [ -n "$(find "$staging" -not -type d 2>/dev/null | head -1)" ] || {
        warn "$label: staging kosong, dilewati"
        return 0
    }

    local count
    count=$(find "$staging" -not -type d | wc -l)
    log "Membuat $label ($count file)..."

    mksquashfs "$staging" "$out" \
        -b "$BLOCK_SIZE" -comp "$COMP" -noappend -no-progress \
        -Xbcj x86 2>/dev/null || \
    mksquashfs "$staging" "$out" \
        -b "$BLOCK_SIZE" -comp "$COMP" -noappend -no-progress

    info "→ $(du -sh "$out" | cut -f1)  $out"
}

# ── 000-kernel.xzm ────────────────────────────────────────────────────────────
build_000_kernel() {
    log "=== 000-kernel.xzm ==="
    local staging="$WORK_DIR/staging/000-kernel"
    mkdir -p "$staging"

    local linux_src="$WORK_DIR/gobo-root/Programs/Linux"
    if [ -d "$linux_src" ]; then
        local kver
        kver=$(find "$linux_src" -mindepth 1 -maxdepth 1 -type d \
               | grep -v Current | sort -V | tail -1 | xargs basename 2>/dev/null || true)
        if [ -n "$kver" ]; then
            info "Kernel GoboLinux versi: $kver"
            mkdir -p "$staging/Programs/Linux"
            cp -a "$linux_src/$kver" "$staging/Programs/Linux/"
            ln -snf "$kver" "$staging/Programs/Linux/Current"
            mkdir -p "$staging/System/Kernel"
            ln -snf "/Programs/Linux/Current/boot"        "$staging/System/Kernel/Boot"
            ln -snf "/Programs/Linux/Current/lib/modules" "$staging/System/Kernel/Modules" 2>/dev/null || true
        else
            warn "Tidak ada versi direktori di Programs/Linux/"
        fi
    else
        # Fallback: dari /boot dan /lib/modules
        warn "Programs/Linux tidak ada — menggunakan fallback dari /boot"
        local kver
        kver=$(ls "$WORK_DIR/gobo-root/lib/modules/" 2>/dev/null | sort -V | tail -1 || true)
        if [ -n "$kver" ]; then
            mkdir -p "$staging/Programs/Linux/$kver"/{boot,lib/modules,firmware}
            [ -d "$WORK_DIR/gobo-root/boot" ] && \
                cp -a "$WORK_DIR/gobo-root/boot/." "$staging/Programs/Linux/$kver/boot/"
            cp -a "$WORK_DIR/gobo-root/lib/modules/$kver/." \
                  "$staging/Programs/Linux/$kver/lib/modules/$kver/"
            ln -snf "$kver" "$staging/Programs/Linux/Current"
        fi
    fi

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/000-kernel.xzm" "000-kernel.xzm"
}

# ── 001-base.xzm ──────────────────────────────────────────────────────────────
BASE_PROGS=(
    Glibc Bash BusyBox Coreutils Util-linux Kmod
    E2fsprogs Shadow Kbd Procps Sed Grep Gawk
    Findutils Diffutils Which File Less Tar
    Gzip Bzip2 Xz PCRE PCRE2 Readline Ncurses NcursesW
    Zlib Openssl Ca-certificates Curl Wget
    Udev Eudev Acpid Dbus Linux-PAM Sysfsutils Psmisc
)

build_001_base() {
    log "=== 001-base.xzm ==="
    local staging="$WORK_DIR/staging/001-base"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${BASE_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        cp -a "$src" "$staging/Programs/"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada program base ditemukan di Programs/"

    # System/ (kecuali Kernel)
    if [ -d "$WORK_DIR/gobo-root/System" ]; then
        mkdir -p "$staging/System"
        for d in Links Settings Environment; do
            [ -d "$WORK_DIR/gobo-root/System/$d" ] && \
                cp -a "$WORK_DIR/gobo-root/System/$d" "$staging/System/"
        done
    fi

    for d in Users Data Mount; do
        [ -d "$WORK_DIR/gobo-root/$d" ] && cp -a "$WORK_DIR/gobo-root/$d" "$staging/"
    done

    for d in proc sys dev tmp run; do mkdir -p "$staging/$d"; done

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/001-base.xzm" "001-base.xzm"
}

# ── 002-gobo-tools.xzm ────────────────────────────────────────────────────────
TOOLS_PROGS=(
    Scripts Compile Manager GoboNet Freshen
    Python3 Python Git Perl
    OpenSSH Sudo Nano Vim GoboHide AbsTK Lua
)

build_002_tools() {
    log "=== 002-gobo-tools.xzm ==="
    local staging="$WORK_DIR/staging/002-gobo-tools"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${TOOLS_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        cp -a "$src" "$staging/Programs/"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada gobo-tools ditemukan"

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/002-gobo-tools.xzm" "002-gobo-tools.xzm"
}

# ── 003-xorg.xzm ─────────────────────────────────────────────────────────────
XORG_PROGS=(
    Xorg Xterm Xinit Xrandr Xsetroot Xauth
    Mesa LibDRM LibGLVND
    FontConfig FreeType HarfBuzz
    LibX11 LibXext LibXrender LibXft LibXi LibXtst
    LibXfixes LibXcomposite LibXdamage LibXrandr
    Pixman Cairo Pango
    LibPng LibJpeg-turbo LibTiff
)

build_003_xorg() {
    log "=== 003-xorg.xzm ==="
    local staging="$WORK_DIR/staging/003-xorg"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${XORG_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        cp -a "$src" "$staging/Programs/"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada paket Xorg ditemukan"

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/003-xorg.xzm" "003-xorg.xzm"
}

# ── 004-desktop.xzm ───────────────────────────────────────────────────────────
DESKTOP_PROGS=(
    Awesome Lua LibXdg-basedir
    Alacritty Firefox Thunar Mousepad Feh
    Gtk+ Gtk+3 Glib GObject-Introspection Atk Pango
    Gdk-Pixbuf Shared-Mime-Info HiColor-Icon-Theme
    NetworkManager Wpa-supplicant
    PulseAudio Alsa-lib Alsa-utils
    Notification-daemon LibNotify
    Rofi Picom Scrot ImageMagick
)

build_004_desktop() {
    log "=== 004-desktop.xzm ==="
    local staging="$WORK_DIR/staging/004-desktop"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${DESKTOP_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        cp -a "$src" "$staging/Programs/"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada paket desktop ditemukan"

    make_xzm "$staging" "$OUTPUT_DIR/porteus/base/004-desktop.xzm" "004-desktop.xzm"
}

# ── porteus.cfg & grub.cfg ─────────────────────────────────────────────────────
create_boot_config() {
    log "Membuat porteus.cfg dan grub.cfg..."

    cat > "$OUTPUT_DIR/boot/syslinux/porteus.cfg" << 'SYSLINUX_EOF'
# GoboLinux 017.01 Live  —  Porteus-style boot config
PROMPT 0
TIMEOUT 90
DEFAULT graphics

UI vesamenu.c32
MENU TITLE  GoboLinux 017.01 Live  [Porteus-style]

LABEL graphics
  MENU LABEL  GoboLinux — Graphical (AwesomeWM)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteus changes=/porteus/changes quiet splash

LABEL text
  MENU LABEL  GoboLinux — Text Mode
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteus changes=/porteus/changes 3

LABEL copy2ram
  MENU LABEL  GoboLinux — Copy to RAM (~2GB RAM needed)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteus changes=/porteus/changes copy2ram

LABEL fresh
  MENU LABEL  GoboLinux — Always Fresh (no save)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteus nomagic

LABEL reboot
  MENU LABEL  Reboot
  COM32 reboot.c32

LABEL poweroff
  MENU LABEL  Power Off
  COM32 poweroff.c32
SYSLINUX_EOF

    mkdir -p "$OUTPUT_DIR/boot/grub"
    cat > "$OUTPUT_DIR/boot/grub/grub.cfg" << 'GRUB_EOF'
set default=0
set timeout=9
menuentry "GoboLinux Graphical (AwesomeWM)" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus changes=/porteus/changes quiet splash
    initrd /boot/syslinux/initrd.xz
}
menuentry "GoboLinux Text Mode" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus changes=/porteus/changes 3
    initrd /boot/syslinux/initrd.xz
}
menuentry "GoboLinux Copy to RAM" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus changes=/porteus/changes copy2ram
    initrd /boot/syslinux/initrd.xz
}
menuentry "GoboLinux Always Fresh" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteus nomagic
    initrd /boot/syslinux/initrd.xz
}
menuentry "Reboot"   { reboot }
menuentry "Shutdown" { halt }
GRUB_EOF
}

# ── Ringkasan ─────────────────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║                  BUILD SELESAI                            ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo ""
    echo "Output: $OUTPUT_DIR"
    echo ""
    echo "File yang dihasilkan:"
    find "$OUTPUT_DIR" \
        \( -name "*.xzm" -o -name "vmlinuz" -o -name "initrd*" \
           -o -name "porteus.cfg" -o -name "grub.cfg" \) \
        2>/dev/null | sort | while read -r f; do
        printf "  %-10s  %s\n" "$(du -sh "$f" | cut -f1)" "${f#$OUTPUT_DIR/}"
    done
    echo ""
    echo "LANGKAH BERIKUTNYA:"
    echo ""
    echo "1. Modifikasi initrd (WAJIB sebelum boot):"
    echo "   sudo bash scripts/modify-initrd.sh \\"
    echo "     $OUTPUT_DIR/boot/syslinux/initrd-gobo-orig \\"
    echo "     $OUTPUT_DIR/boot/syslinux/initrd.xz"
    echo ""
    echo "2a. Install ke USB:"
    echo "    sudo bash scripts/install-deploy.sh usb /dev/sdX"
    echo ""
    echo "2b. Buat ISO:"
    echo "    sudo bash scripts/install-deploy.sh iso"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    check_deps

    log "GoboLinux → Porteus-style Live Builder"
    log "ISO    : $GOBO_ISO"
    log "Output : $OUTPUT_DIR"
    log "Kompresi modul: $COMP | Block: $BLOCK_SIZE"

    trap 'umount "$WORK_DIR/iso" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT
    mkdir -p "$WORK_DIR"

    mkdir -p \
        "$OUTPUT_DIR/boot/syslinux" \
        "$OUTPUT_DIR/EFI/boot" \
        "$OUTPUT_DIR/porteus/base" \
        "$OUTPUT_DIR/porteus/modules" \
        "$OUTPUT_DIR/porteus/optional" \
        "$OUTPUT_DIR/porteus/changes"

    # 1. Scan ISO — tampilkan semua file sebenarnya
    scan_iso

    # 2. Deteksi file penting berdasarkan magic bytes
    log "Mendeteksi file penting dalam ISO..."
    local KERNEL_SRC INITRAMFS_SRC SQUASHFS_SRC
    KERNEL_SRC=$(detect_kernel)
    INITRAMFS_SRC=$(detect_initramfs)
    SQUASHFS_SRC=$(detect_squashfs)

    echo ""
    [ -n "$KERNEL_SRC" ]    && info "Kernel   : ${KERNEL_SRC#$WORK_DIR/iso}" \
                               || warn "Kernel tidak terdeteksi"
    [ -n "$INITRAMFS_SRC" ] && info "Initramfs: ${INITRAMFS_SRC#$WORK_DIR/iso}" \
                               || warn "Initramfs tidak terdeteksi"
    [ -n "$SQUASHFS_SRC" ]  && info "Squashfs : ${SQUASHFS_SRC#$WORK_DIR/iso}" \
                               || die "Squashfs GoboLinux tidak ditemukan dalam ISO"
    echo ""

    # 3. Salin boot files
    setup_boot "$KERNEL_SRC" "$INITRAMFS_SRC"

    # 4. Ekstrak squashfs
    extract_squashfs "$SQUASHFS_SRC"

    # 5. Build modul .xzm
    build_000_kernel
    build_001_base
    build_002_tools
    build_003_xorg
    build_004_desktop

    # 6. Buat konfigurasi bootloader
    create_boot_config

    show_summary
}

main "$@"
