#!/bin/bash
# install-to-usb.sh  — Instal GoboLinux-Porteus ke USB drive
# make-iso.sh        — Buat file ISO bootable dari output/porteus-gobolinux/
#
# Penggunaan:
#   sudo bash install-to-usb.sh /dev/sdX
#   sudo bash make-iso.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/../output/porteus-gobolinux"

die()  { echo "ERROR: $*" >&2; exit 1; }
log()  { echo "[$(date +%H:%M:%S)] $*"; }

# ════════════════════════════════════════════════════════════════════════════
# install-to-usb.sh
# ════════════════════════════════════════════════════════════════════════════
install_to_usb() {
    local device="${1:-}"
    [ -z "$device" ] && { echo "Usage: $0 usb <device>  misal: $0 usb /dev/sdb"; exit 1; }
    [ -b "$device" ] || die "Bukan block device: $device"
    [ "$(id -u)" = "0" ] || die "Harus root"

    # Cek bukan disk sistem
    local root_dev
    root_dev=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    [ "$device" = "$root_dev" ] && die "Tidak boleh ke disk sistem: $device"

    echo "PERINGATAN: Semua data di $device akan dihapus!"
    read -rp "Lanjutkan? (ketik YES): " confirm
    [ "$confirm" = "YES" ] || { echo "Dibatalkan"; exit 0; }

    log "Mempartisi $device..."
    # Buat tabel partisi: 1 partisi FAT32 untuk boot + data
    parted -s "$device" \
        mklabel msdos \
        mkpart primary fat32 1MiB 100% \
        set 1 boot on

    local part="${device}1"
    # Handle mmcblk: /dev/mmcblk0p1
    [[ "$device" =~ mmcblk ]] && part="${device}p1"

    log "Format $part sebagai FAT32..."
    mkfs.fat -F 32 -n GOBOLINUX "$part"

    log "Mounting $part..."
    local mnt
    mnt=$(mktemp -d)
    mount "$part" "$mnt"
    trap "umount '$mnt' 2>/dev/null; rm -rf '$mnt'" EXIT

    log "Menyalin file..."
    cp -a "$OUTPUT_DIR/." "$mnt/"

    log "Menginstal syslinux MBR..."
    # Install syslinux bootloader
    syslinux --install "$part"
    dd if=/usr/lib/syslinux/mbr/mbr.bin of="$device" bs=440 count=1 conv=notrunc 2>/dev/null || \
    dd if=/usr/share/syslinux/mbr.bin   of="$device" bs=440 count=1 conv=notrunc 2>/dev/null || \
    warn "mbr.bin tidak ditemukan — boot MBR mungkin tidak berfungsi"

    # Rename porteus.cfg ke syslinux.cfg untuk syslinux
    [ -f "$mnt/boot/syslinux/porteus.cfg" ] && \
        cp "$mnt/boot/syslinux/porteus.cfg" "$mnt/boot/syslinux/syslinux.cfg"

    sync
    log "Selesai! USB siap boot GoboLinux dari $device"
    log "Total ukuran:"
    du -sh "$mnt/porteus/base/"*.xzm 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════
# make-iso.sh
# ════════════════════════════════════════════════════════════════════════════
make_iso() {
    local iso_out="${1:-$(dirname "$OUTPUT_DIR")/GoboLinux-Porteus-live.iso}"
    command -v xorriso &>/dev/null || die "xorriso tidak ada: apt install xorriso"

    local vmlinuz="$OUTPUT_DIR/boot/syslinux/vmlinuz"
    local initrd="$OUTPUT_DIR/boot/syslinux/initrd.xz"

    [ -f "$vmlinuz" ] || die "vmlinuz tidak ada: $vmlinuz"
    [ -f "$initrd"  ] || die "initrd.xz tidak ada: $initrd"

    log "Membuat ISO: $iso_out"

    # Cari isolinux.bin
    local isolinux_bin=""
    for candidate in \
        /usr/lib/syslinux/isolinux.bin \
        /usr/share/syslinux/isolinux.bin \
        "$OUTPUT_DIR/boot/syslinux/isolinux.bin"
    do
        [ -f "$candidate" ] && isolinux_bin="$candidate" && break
    done

if [ -n "$isolinux_bin" ] && [ -f "$isolinux_bin" ]; then
        DEST_DIR="$OUTPUT_DIR/boot/syslinux"
        mkdir -p "$DEST_DIR"

        # Cek apakah file sumber berada di luar direktori tujuan
        # agar tidak terjadi "same file error"
        if [ "$(realpath "$isolinux_bin")" != "$(realpath "$DEST_DIR/isolinux.bin")" ]; then
            cp "$isolinux_bin" "$DEST_DIR/"
        fi

        # Rename porteus.cfg -> isolinux.cfg
        if [ -f "$DEST_DIR/porteus.cfg" ]; then
            cp "$DEST_DIR/porteus.cfg" "$DEST_DIR/isolinux.cfg"
        fi
    fi

    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "GoboLinux-Live" \
        -appid  "GoboLinux 017.01 Porteus-style" \
        -publisher "GoboLinux Community" \
        -preparer "build-gobo-live.sh" \
        \
        -b boot/syslinux/isolinux.bin \
        -c boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        \
        -eltorito-alt-boot \
        -e EFI/boot/bootx64.efi \
        -no-emul-boot \
        \
        -isohybrid-mbr /usr/lib/syslinux/isohdpfx.bin 2>/dev/null || \
    xorriso -as mkisofs \
        -iso-level 3 \
        -volid "GoboLinux-Live" \
        -b boot/syslinux/isolinux.bin \
        -c boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o "$iso_out" \
        "$OUTPUT_DIR"

    local size
    size=$(du -sh "$iso_out" | cut -f1)
    log "ISO selesai: $iso_out ($size)"
    log "Burn ke USB: sudo dd if=$iso_out of=/dev/sdX bs=4M status=progress"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "${1:-help}" in
    usb)  install_to_usb "${2:-}" ;;
    iso)  make_iso "${2:-}" ;;
    help|*)
        echo "Usage:"
        echo "  sudo bash $0 usb /dev/sdX    Instal ke USB"
        echo "  sudo bash $0 iso [output.iso] Buat file ISO"
        ;;
esac
