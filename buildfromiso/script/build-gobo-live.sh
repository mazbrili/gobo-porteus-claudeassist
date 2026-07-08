#!/bin/bash
# build-gobo-live.sh  —  GoboLinux 017.01  →  struktur folder porteux
# ─────────────────────────────────────────────────────────────────────────────
# Strategi: SCAN dulu isi ISO secara nyata, baru proses.
# Tidak hardcode nama file apapun dari ISO GoboLinux.
#
# GoboLinux 017.01 memakai:
#   isolinux/kernel      ← bukan vmlinuz
#   isolinux/initramfs   ← bukan initrd.xz, compressed zstd
#   GoboLinux/GoboLinuxFS.squashfs  ← squashfs utama, compressed zstd
#
# Output porteux-style:
#   porteux-gobolinux/
#   ├── boot/syslinux/
#   │   ├── vmlinuz          ← salin dari isolinux/kernel
#   │   ├── initrd-gobo-orig ← salin dari isolinux/initramfs (asli)
#   │   ├── initrd.zst        ← hasil modify-initrd.sh (dijalankan terpisah)
#   │   └── porteux.cfg
#   ├── EFI/
#   └── porteux/
#       ├── base/
#       │   ├── 000-kernel.xzm
#       │   ├── 001-base.xzm
#       │   ├── 002-gobotool.xzm
#       │   ├── 003-xorg.xzm
#       │   └── 004-desktop.xzm
#       ├── modules/
#       ├── optional/
#       └── changes/
#
# Penggunaan:
#   sudo bash build-gobo-live.sh GoboLinux-017.01-x86_64.iso [output_dir]
# ─────────────────────────────────────────────────────────────────────────────
# Path untuk skrip pemetaan Current yang akan dihasilkan
CURRENT_MAP_FILE="gobo17.01-current.sh"

set -euo pipefail

GOBO_ISO="${1:-GoboLinux-017.01-x86_64.iso}"
OUTPUT_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)/output/porteux-gobolinux}"
PORTEUX_ISO="${PORTEUX_ISO:-}"   # Set via: PORTEUX_ISO=/path/to/porteux.iso make build
BUSYBOX_FROM_porteux=""         # Diisi oleh extract_syslinux_from_porteux()
WORK_DIR="${TMPDIR:-/tmp}/gobo-live-$$"
# gobo-root disimpan di luar WORK_DIR agar tidak ikut dihapus trap
GOBO_ROOT_DIR="${TMPDIR:-/tmp}/gobo-live-root-$$"
GOBO_ROOT_PERSIST=""
COMP="${COMP:-xz}"
BLOCK_SIZE="${BLOCK_SIZE:-256K}"

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' C='\033[0;36m' N='\033[0m'
# Semua output ke stderr agar tidak kontaminasi $() subshell capture
log()  { echo -e "${G}[$(date +%H:%M:%S)]${N} $*" >&2; }
info() { echo -e "${C}  ↳${N} $*" >&2; }
warn() { echo -e "${Y}[WARN]${N} $*" >&2; }
die()  { echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }

# ── Dependensi ────────────────────────────────────────────────────────────────
check_deps() {
    local miss=()
    for cmd in mksquashfs unsquashfs file rsync; do
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

    log ""
    log "╔═══════════════════════════════════════════════════════════╗"
    log "║         ISI ISO GoboLinux (semua file, 3 level)           ║"
    log "╚═══════════════════════════════════════════════════════════╝"
    find "$WORK_DIR/iso" -maxdepth 3 | sort | while read -r f; do
        local rel="${f#$WORK_DIR/iso}"
        [ -z "$rel" ] && continue
        if [ -d "$f" ]; then
            log "  DIR  $rel/"
        else
            local sz fmt
            sz=$(du -sh "$f" 2>/dev/null | cut -f1)
            fmt=$(file -b "$f" 2>/dev/null | cut -c1-45)
            log "  FILE $rel [$sz] $fmt"
        fi
    done
    log ""
}

# ── Deteksi kernel ─────────────────────────────────────────────────────────────
detect_kernel() {
    local found=""

    # Prioritas 1: nama file yang pasti dari GoboLinux isolinux/
    # Ini lebih reliable daripada scan ELF (bisa salah ambil file lain)
    for candidate in \
        "$WORK_DIR/iso/isolinux/kernel" \
        "$WORK_DIR/iso/boot/isolinux/kernel" \
        "$WORK_DIR/iso/isolinux/vmlinuz" \
        "$WORK_DIR/iso/boot/isolinux/vmlinuz" \
        "$WORK_DIR/iso/boot/vmlinuz"
    do
        [ -f "$candidate" ] || continue
        local sz; sz=$(stat -c%s "$candidate" 2>/dev/null || echo 0)
        # Kernel Linux minimal ~1MB, skip file kecil
        if [ "$sz" -gt 1048576 ]; then
            found="$candidate"
            info "Kernel ditemukan via nama: $candidate ($(du -sh "$candidate" | cut -f1))"
            break
        fi
    done

    # Prioritas 2: scan ELF — cari file TERBESAR yang match
    # (kernel selalu file terbesar di isolinux/)
    if [ -z "$found" ]; then
        local biggest_size=0
        while IFS= read -r -d '' f; do
            local magic sz
            magic=$(file -b "$f" 2>/dev/null)
            echo "$magic" | grep -qiE "Linux kernel|bzImage|x86 boot" || continue
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            if [ "$sz" -gt "$biggest_size" ]; then
                biggest_size="$sz"
                found="$f"
            fi
        done < <(find "$WORK_DIR/iso" -not -type d -print0)
        [ -n "$found" ] && info "Kernel ditemukan via scan: $found ($(du -sh "$found" | cut -f1))"
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
            "$WORK_DIR/iso/isolinux/initrd.zst" \
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


# ── Ekstrak file syslinux dari ISO porteux ────────────────────────────────────
# porteux ISO berisi semua file .c32, isolinux.bin, vesamenu.c32, dll
# yang dibutuhkan untuk boot BIOS/Legacy.
# porteux diunduh dari: https://porteux.org/porteux-downloads.html
extract_syslinux_from_porteux() {
    local dst="$OUTPUT_DIR/boot/syslinux"
    mkdir -p "$dst"

    # Cari porteux ISO — dari argumen env atau scan direktori kerja
    local PORTEUX_ISO="$PORTEUX_ISO"
    if [ -z "$PORTEUX_ISO" ]; then
        # Auto-detect: cari file porteux*.iso di direktori script dan parent
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        for candidate in             "$script_dir"/../porteux*.iso             "$script_dir"/../porteux*.iso             "$script_dir"/../../porteux*.iso             "$(pwd)"/porteux*.iso             "$(pwd)"/porteux*.iso
        do
            # Expand glob
            for f in $candidate; do
                [ -f "$f" ] && { PORTEUX_ISO="$f"; break 2; }
            done
        done
    fi

    if [ -z "$PORTEUX_ISO" ] || [ ! -f "$PORTEUX_ISO" ]; then
        warn "porteux ISO tidak ditemukan — syslinux dari GoboLinux ISO saja"
        warn "Untuk syslinux lengkap: PORTEUX_ISO=/path/to/porteux.iso make build"
        warn "Unduh: https://porteux.org/porteux-downloads.html"
        return 0
    fi

    log "Ekstrak syslinux dari porteux ISO: $PORTEUX_ISO"

    local porteux_mnt="$WORK_DIR/porteux-mnt"
    mkdir -p "$porteux_mnt"
    mount -o loop,ro "$PORTEUX_ISO" "$porteux_mnt" || {
        warn "Gagal mount porteux ISO: $PORTEUX_ISO"
        return 0
    }

    # Tampilkan isi boot/ porteux untuk referensi
    log "  Isi boot/ porteux:"
    find "$porteux_mnt/boot" -maxdepth 2 2>/dev/null | sort | while read -r f; do
        local rel="${f#$porteux_mnt}"
        [ -d "$f" ] && log "    DIR $rel/" ||             log "    $(du -sh "$f" 2>/dev/null | cut -f1)  $rel"
    done

    # File yang dicari dari porteux:
    # - isolinux.bin     : bootloader binary
    # - vesamenu.c32     : menu grafis
    # - menu.c32         : menu teks
    # - chain.c32        : chainload
    # - reboot.c32       : reboot
    # - poweroff.c32     : poweroff
    # - libcom32.c32     : library (dibutuhkan c32 lain)
    # - libutil.c32      : library
    # - ldlinux.c32      : library utama syslinux modern
    # - splash.png/jpg   : background menu (opsional)
    # - isohdpfx.bin     : untuk isohybrid (USB boot)

    # KRITIS: semua .c32 HARUS dari versi syslinux yang sama
    # Mencampur .c32 dari sumber berbeda menyebabkan:
    #   "Undef symbol FAIL: init_fpu"
    #   "Failed to load libcom32.c32"
    # Solusi: SELALU timpa dengan file dari Porteux, hapus file lama dulu

    # Hapus semua .c32 dan .bin lama yang mungkin dari sumber lain
    log "  Bersihkan .c32 lama di $dst ..."
    find "$dst" -maxdepth 1 \( -name "*.c32" -o -name "*.bin" \)         ! -name "vmlinuz" ! -name "initrd*"         -delete 2>/dev/null || true

    local copied=0
    local syslinux_src=""
    for isodir in         "$porteux_mnt/boot/syslinux"         "$porteux_mnt/boot/isolinux"         "$porteux_mnt/syslinux"         "$porteux_mnt/isolinux"
    do
        [ -d "$isodir" ] || continue
        syslinux_src="$isodir"
        log "  Sumber syslinux: ${isodir#$porteux_mnt}"
        break
    done

    [ -n "$syslinux_src" ] || { warn "Direktori syslinux tidak ditemukan di Porteux ISO"; return 0; }

    # Salin SEMUA file dari direktori syslinux Porteux (kecuali kernel/initrd/cfg)
    find "$syslinux_src" -maxdepth 1 -type f | while read -r f; do
        local bn="${f##*/}"
        case "$bn" in
            vmlinuz|kernel|initrd*|initramfs*|porteux.cfg|syslinux.cfg|isolinux.cfg)
                continue ;;
        esac
        cp "$f" "$dst/$bn" 2>/dev/null && {
            copied=$((copied+1))
            info "    + $bn"
        } || true
    done

    # Khusus: salin isohdpfx.bin untuk isohybrid (USB dd boot)
    for candidate in         "$porteux_mnt/boot/syslinux/isohdpfx.bin"         "$porteux_mnt/boot/isolinux/isohdpfx.bin"
    do
        [ -f "$candidate" ] && cp "$candidate" "$dst/isohdpfx.bin" &&             info "    + isohdpfx.bin (isohybrid)" && break
    done

    # Simpan porteux initrd.xz ke output agar build-initrd.sh bisa auto-detect BusyBox
    for candidate in         "$porteux_mnt/boot/syslinux/initrd.xz"         "$porteux_mnt/boot/isolinux/initrd.xz"         "$porteux_mnt/boot/syslinux/initrd.img"         "$porteux_mnt/porteux/boot/initrd.xz"
    do
        [ -f "$candidate" ] || continue
        local porteux_initrd_dst="$OUTPUT_DIR/boot/syslinux/porteux-initrd.xz"
        cp "$candidate" "$porteux_initrd_dst"
        info "  porteux initrd disimpan: ${candidate#$porteux_mnt} → boot/syslinux/porteux-initrd.xz"
        info "    ($(du -sh "$porteux_initrd_dst" | cut -f1)) — berisi BusyBox untuk build-initrd.sh"
        break
    done

    # ── Ekstrak BusyBox dari initrd.xz porteux ─────────────────────────────────
    # porteux initrd.xz berisi BusyBox statik yang dikompilasi dengan applet
    # lengkap — jauh lebih baik dari BusyBox GoboLinux yang mungkin tidak ada
    log "  Ekstrak BusyBox dari porteux initrd.xz..."
    local porteux_initrd=""
    for candidate in         "$porteux_mnt/boot/syslinux/initrd.xz"         "$porteux_mnt/boot/syslinux/initrd.img"         "$porteux_mnt/boot/initrd.xz"         "$porteux_mnt/boot/syslinux/initrd.zst"
    do
        [ -f "$candidate" ] && { porteux_initrd="$candidate"; break; }
    done

    if [ -n "$porteux_initrd" ]; then
        local bb_extract="$WORK_DIR/porteux-initrd-extract"
        mkdir -p "$bb_extract"
        log "    Initrd porteux: ${porteux_initrd#$porteux_mnt} ($(du -sh "$porteux_initrd" | cut -f1))"
        log "    Format: $(file -b "$porteux_initrd" | cut -c1-50)"

        # Ekstrak initrd — coba semua format (xz, zstd, gzip)
        local extracted=0
        if (cd "$bb_extract" && xzcat "$porteux_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null); then
            extracted=1
            log "    Ekstrak: xz OK"
        elif (cd "$bb_extract" && zstdcat "$porteux_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null); then
            extracted=1
            log "    Ekstrak: zstd OK"
        elif (cd "$bb_extract" && zcat "$porteux_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null); then
            extracted=1
            log "    Ekstrak: gzip OK"
        fi
        # Fallback: unmkinitramfs (handle early_cpio + main)
        if [ "$extracted" -eq 0 ] && command -v unmkinitramfs &>/dev/null; then
            unmkinitramfs "$porteux_initrd" "$bb_extract" 2>/dev/null && extracted=1
            log "    Ekstrak: unmkinitramfs OK"
        fi
        # Jika initrd berformat early_cpio+main, main ada di subdir
        for subdir in "$bb_extract/main" "$bb_extract/early"; do
            [ -d "$subdir" ] && { bb_extract="$subdir"; log "    Ganti extract root: $subdir"; break; }
        done

        # Tampilkan struktur initrd untuk debug
        log "    Struktur initrd porteux (top 3 level):"
        find "$bb_extract" -maxdepth 3 | sort | head -40 | while read -r f; do
            log "      ${f#$bb_extract/}"
        done

        # Cari busybox: scan SEMUA path tanpa batasan depth
        local bb_found=""
        # Cek path umum dulu
        for candidate in             "$bb_extract/bin/busybox"             "$bb_extract/usr/bin/busybox"             "$bb_extract/busybox"             "$bb_extract/sbin/busybox"
        do
            [ -f "$candidate" ] && { bb_found="$candidate"; break; }
        done

        # Fallback: scan seluruh initrd untuk file bernama busybox
        if [ -z "$bb_found" ]; then
            log "    Scan seluruh initrd untuk busybox..."
            bb_found=$(find "$bb_extract" -name "busybox" -type f 2>/dev/null | head -1)
            [ -n "$bb_found" ] && log "    Ditemukan via scan: ${bb_found#$bb_extract/}"
        fi

        # Fallback kedua: cari ELF statik apapun yang berukuran > 500KB (kemungkinan busybox)
        if [ -z "$bb_found" ]; then
            log "    Cari ELF statik (fallback)..."
            while IFS= read -r -d "" f; do
                local ftype; ftype=$(file -b "$f" 2>/dev/null)
                if echo "$ftype" | grep -qi "statically linked"; then
                    local fsz; fsz=$(stat -c%s "$f" 2>/dev/null || echo 0)
                    if [ "$fsz" -gt 524288 ]; then  # > 512KB
                        bb_found="$f"
                        log "    ELF statik ditemukan: ${f#$bb_extract/} ($(du -sh "$f" | cut -f1))"
                        break
                    fi
                fi
            done < <(find "$bb_extract" -type f -print0 2>/dev/null)
        fi

        if [ -n "$bb_found" ]; then
            cp "$bb_found" "$WORK_DIR/busybox-from-porteux"
            chmod +x "$WORK_DIR/busybox-from-porteux"
            BUSYBOX_FROM_porteux="$WORK_DIR/busybox-from-porteux"
            log "    BusyBox porteux: $(du -sh "$BUSYBOX_FROM_porteux" | cut -f1)"
            log "    Format: $(file -b "$BUSYBOX_FROM_porteux" | cut -c1-60)"
            echo "$BUSYBOX_FROM_porteux" > "$(dirname "$OUTPUT_DIR")/.busybox-path"
            log "    Path disimpan: $(dirname "$OUTPUT_DIR")/.busybox-path"
        else
            warn "    BusyBox tidak ditemukan di initrd porteux"
            warn "    File ELF dalam initrd:"
            find "$bb_extract" -type f | while read -r f; do
                ftype=$(file -b "$f" 2>/dev/null | cut -c1-40)
                echo "$ftype" | grep -qi "ELF\|executable" &&                     log "      ${f#$bb_extract/}: $ftype"
            done || true
        fi
        rm -rf "$bb_extract"
    else
        warn "  initrd.xz porteux tidak ditemukan di boot/syslinux/"
    fi

    umount "$porteux_mnt" 2>/dev/null || true

    log "  Syslinux dari porteux: $copied file disalin"

    # Verifikasi file kritis
    local critical_ok=1
    for critical in "isolinux.bin" "ldlinux.c32" "libcom32.c32" "vesamenu.c32"; do
        if [ -f "$dst/$critical" ]; then
            info "  OK: $critical"
        else
            warn "  MISSING: $critical"
            critical_ok=0
        fi
    done

    # Tampilkan semua .c32 yang tersedia untuk diagnosis
    log "  Daftar .c32 di output:"
    find "$dst" -maxdepth 1 -name "*.c32" 2>/dev/null | sort | while read -r f; do
        info "    $(basename "$f")"
    done

    [ "$critical_ok" = "1" ] &&         log "  Semua file syslinux kritis tersedia — versi konsisten dari Porteus" ||         warn "  File kritis MISSING — pastikan PORTEUS_ISO valid (Porteus 5.x x86_64)"
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

    # Ekstrak langsung ke GOBO_ROOT_DIR (di luar WORK_DIR, tidak ikut trap rm)
    # Ini menghindari mv antar filesystem (masalah WSL /tmp vs /mnt/c NTFS)
    rm -rf "$GOBO_ROOT_DIR"
    unsquashfs -d "$GOBO_ROOT_DIR" "$sqfs" || \
        die "Gagal ekstrak squashfs.
    Jika error 'zstd not supported', install squashfs-tools >= 4.5:
      sudo apt install squashfs-tools
    Atau build dari source: https://github.com/plougher/squashfs-tools"

    log "Root GoboLinux berhasil diekstrak:"
    ls -la "$GOBO_ROOT_DIR/" | head -15

    # Buat symlink WORK_DIR/gobo-root -> GOBO_ROOT_DIR
    # agar semua fungsi build_xxx() yang pakai $WORK_DIR/gobo-root tetap bekerja
    ln -snf "$GOBO_ROOT_DIR" "$WORK_DIR/gobo-root"

    GOBO_ROOT_PERSIST="$GOBO_ROOT_DIR"
    log "gobo-root di: $GOBO_ROOT_DIR ($(du -sh "$GOBO_ROOT_DIR" | cut -f1))"

    # ── Validasi: pastikan ini GoboLinux 017 (kernel 6.x), bukan 016 ──────────
    log "Validasi versi kernel di gobo-root..."
    if [ -d "$GOBO_ROOT_DIR/Programs/Linux" ]; then
        log "  Isi Programs/Linux/:"
        ls "$GOBO_ROOT_DIR/Programs/Linux/" | while read -r k; do
            log "    $k"
        done
        local kver
        kver=$(ls "$GOBO_ROOT_DIR/Programs/Linux/" | grep -v Current | sort -V | tail -1)
        log "  Kernel versi: $kver"
        # Cek apakah kernel 6.x
        case "$kver" in
            6.*)
                log "  OK: GoboLinux 017 kernel ($kver)" ;;
            5.*|4.*|3.*)
                warn "  PERHATIAN: Kernel $kver terdeteksi — ini sepertinya GoboLinux 016!"
                warn "  Pastikan ISO yang digunakan adalah GoboLinux-017.01-x86_64.iso"
                warn "  gobo-root ini TIDAK akan menghasilkan initrd yang benar" ;;
            *)
                warn "  Kernel versi tidak dikenal: $kver" ;;
        esac
    else
        warn "  Programs/Linux tidak ada di gobo-root — squashfs mungkin salah"
    fi

    # Simpan path gobo-root ke file agar Makefile/build-initrd.sh bisa menemukannya
    mkdir -p "$(dirname "$OUTPUT_DIR")"
    echo "$GOBO_ROOT_DIR" > "$(dirname "$OUTPUT_DIR")/.gobo-root-path"
    log "Path gobo-root: $GOBO_ROOT_DIR"
    log "Path file    : $(dirname "$OUTPUT_DIR")/.gobo-root-path"
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

# ── Fungsi Helper Rsync (Perbaikan) ──────────────────────────────────────────
# Fungsi ini memastikan hanya file yang diperlukan yang masuk ke modul.
# $1 = Path asal (/mnt/gobo-root/Programs/NamaApp)
# $2 = Path tujuan staging
# $3 = Mode (runtime / dev)
sync_gobo_program() {
    local src="$1"
    local dest="$2"
    local mode="${3:-runtime}"

    if [ "$mode" == "dev" ]; then
        # Mode Dev: Masukkan Include, Lib/pkgconfig, dan Static Libs
        rsync -ah --prune-empty-dirs \
            --include='*/' \
            --include='*/include/***' \
            --include='*/lib/pkgconfig/***' \
            --include='*/lib/*.a' \
            --include='*/lib/*.la' \
            --include='*/share/aclocal/***' \
            --include='*/bin/***' \
            --include='*/sbin/***' \
            --include='*/lib/***' \
            --include='*/libexec/***' \
            --exclude='*' \
            "$src" "$dest"
    else
        # Mode Runtime: Logika filter rsync Anda (Tanpa Headers/Docs)
        rsync -ah --prune-empty-dirs \
            --include='*/' \
            --include='*/bin/***' \
            --include='*/sbin/***' \
            --include='*/lib/***' \
            --include='*/libexec/***' \
            --include='*/share/icons/***' \
            --include='*/share/fonts/***' \
            --include='*/share/X11/***' \
            --exclude='*/include' \
            --exclude='*/share/doc' \
            --exclude='*/share/man' \
            --exclude='*/share/info' \
            --exclude='*' \
            "$src" "$dest"
    fi
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

    make_xzm "$staging" "$OUTPUT_DIR/porteux/base/000-kernel.xzm" "000-kernel.xzm"
}

# ── 001-base.xzm ──────────────────────────────────────────────────────────────
# ──|-----handy-ruler------------------------------------------------------|
BASE_PROGS=(
#    Glibc Bash BusyBox Coreutils Util-linux Kmod
#    E2fsprogs Shadow Kbd Procps Sed Grep Gawk
#    Findutils Diffutils Which File Less Tar
#    Gzip Bzip2 Xz PCRE PCRE2 Readline Ncurses NcursesW
#    Zlib Openssl Ca-certificates Curl Wget
#    Udev Eudev Acpid Dbus Linux-PAM Sysfsutils Psmisc
#   |-----handy-ruler------------------------------------------------------|
#   di gobo ada tapi di slack tidak pakai , python kelihatannya harus ada
    APR APR-Util At-Spi2-ATK At-Spi2-Core Python Python3
#   di porteux ada
    ACL Acpid ATTR Bash BC Bluez Bridge-Utils Bzip2 CA-Certificates
    CAcerts CoreUtils Cpio Curl Cyrus-SASL DBus DBus-GLib
    DHCPCD Dialog DiffUtils Dmidecode DosFSTools E2FSProgs Ethtool Eudev
    File FindUtils Fuse Gawk GD GDBM Gettext GLib Glibc Glib-Networking
    GnuTLS GoboHide GoboLight GoboNet Grep GRUB GRUB-EFI Gzip
    Hdparm InetUtils IPRoute2 Iptables KBD Kernel Kmod Less
    LibAIO LibArchive LibAssuan LibCap LibFFI LibGCrypt LibGPG-Error
    LibGUdev LibICU4C LibIDN LibIDN2 LibPSL LibXML2 Linux-PAM LM-Sensors
    Lsof LVM2 Lynx LZ4 LZip LZO MC Mdadm NcursesW Nettle Net-Tools
    NTFS-3G OpenSSH OpenSSL Propcs-NG P11-Kit Parted Rsync Sed SQLite
    SquashFS-Tools SSHFS Sudo SysFSUtils Sysklogd Sysvinit Tar Tcl Tree
    Unzip Util-linux USBUtils Wget Wireless-Tools XZ-Utils ZLib ZSH Zstd

)

# ── Refaktor Fungsi Build (Contoh 001-base) ──────────────────────────────────
build_001_base() {
    log "=== 001-base.xzm (Modular & Dynamic Current) ==="
    local staging="$WORK_DIR/staging/001-base"
    mkdir -p "$staging/Programs"

    # Proses aplikasi dasar
    for prog in "${BASE_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        sync_gobo_program "$src" "$staging/Programs/" "runtime"
    done

    # Masukkan skrip pemetaan Current ke lokasi inisialisasi
    # Script ini akan dieksekusi oleh /init setelah overlay mount
    # (lihat build-initrd.sh bagian System/Links — dipanggil sebelum switch_root)
    local init_dir="$staging/System/Settings/BootScripts"
    mkdir -p "$init_dir"
    cp "$WORK_DIR/$CURRENT_MAP_FILE" "$init_dir/InitializeCurrent"
    chmod +x "$staging/System/Settings/BootScripts/InitializeCurrent"
    
    # Salin System Files esensial lainnya
    cp -a "$WORK_DIR/gobo-root/System/Settings/." "$staging/System/Settings/" 2>/dev/null || true
    
    make_xzm "$staging" "$OUTPUT_DIR/porteux/base/001-base.xzm" "001-base.xzm"
}

# ── 002-gobotool.xzm ─────────────────────────────────────────────────────────────
TOOLS_PROGS=(
#   |-----handy-ruler------------------------------------------------------|
#    Scripts Compile Manager GoboNet Freshen
#    Python3 Python Git Perl
#    OpenSSH Sudo Nano Vim GoboHide AbsTK Lua
    AbsTK BootScripts Compile ConfigTools EnhancedSkel Freshen Installer 
    Listener Scripts
)

build_002_gobotool() {
    log "=== 002-gobotool.xzm ==="
    local staging="$WORK_DIR/staging/002-gobotool"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${TOOLS_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        sync_gobo_program "$src" "$staging/Programs/" "runtime"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada gobo-tools ditemukan"

    make_xzm "$staging" "$OUTPUT_DIR/porteux/base/002-gobotool.xzm" "002-gobotool.xzm"
}

# ── Build 002-gobo-rest.xzm (Struktur Folder GoboLinux 016/017 Sisa) ──────────
build_002_gobo_rest() {
    local base_dir="$OUTPUT_DIR/porteux/base"
    local staging="$WORK_DIR/staging-002-gobo-rest"
    rm -rf "$staging" && mkdir -p "$staging"

    log "Menyusun staging untuk 002-gobo-rest.xzm (Struktur Folder GoboLinux)..."

    # 1. Ambil folder sistem dasar GoboLinux di root "/"
    # Mengabaikan folder /Programs karena dihandle modul lain, tetapi menyalin sisanya.
    for folder in System Data Mount Users Depots Files Library; do
        if [ -d "$GOBO_ROOT_DIR/$folder" ]; then
            info "  Menduplikasi folder: /$folder"
            mkdir -p "$staging/$folder"
            # Salin struktur dan file di dalamnya (kecuali folder besar Programs jika ada)
            rsync -a --exclude="/Programs" "$GOBO_ROOT_DIR/$folder/" "$staging/$folder/"
        fi
    done

    # 2. Ambil symlink legasi/standar Linux di root "/" (seperti /bin, /sbin, /lib, /usr, /root, dll)
    # GoboLinux menggunakan symlink ini untuk mengarah ke /System/Index/...
    info "  Menyalin symlink root standar Linux..."
    find "$GOBO_ROOT_DIR" -maxdepth 1 -type l | while read -r link; do
        local link_name
        link_name=$(basename "$link")
        local link_target
        link_target=$(readlink "$link")
        ln -sf "$link_target" "$staging/$link_name"
    done

    # 3. Pastikan folder mountpoint kosong umum selalu tersedia
    # Ditambahkan cek [ ! -e ... ] dan [ ! -L ... ] agar tidak bentrok jika sudah ada/berbentuk symlink
    for mnt in dev proc sys run tmp mnt media root; do
        if [ ! -e "$staging/$mnt" ] && [ ! -L "$staging/$mnt" ]; then
            mkdir -p "$staging/$mnt"
        fi
    done
    
    # Pastikan permission folder tmp benar
    chmod 1777 "$staging/tmp"

    # 4. Bungkus menjadi modul xzm
    make_xzm "$staging" "$base_dir/002-gobo-rest.xzm" "002-gobo-rest.xzm"
    rm -rf "$staging"
}

# ── 003-xorg.xzm ─────────────────────────────────────────────────────────────
XORG_PROGS=(
#    Xorg Xterm Xinit Xrandr Xsetroot Xauth
#    Mesa LibDRM LibGLVND
#    FontConfig FreeType HarfBuzz
#    LibX11 LibXext LibXrender LibXft LibXi LibXtst
#    LibXfixes LibXcomposite LibXdamage LibXrandr
#    Pixman Cairo Pango
#    LibPng LibJpeg-turbo LibTiff
    ALSA-Utils ALSA-UCM-Conf ALSA-Lib ALSA-Firmware ATK ATKMM At-Spi2-Core
    At-Spi2-ATK Audiofile Cairo Cairomm DB DejaVu-Fonts-TTF Desktop-File-Utils 
    Flac Fontconfig FreeGlut FreeType Fribidi GDK-Pixbuf Giflib Glibmm Gparted
    Gobject-Introspection Graphite2 GSL GTKMM HarfBuzz Hicolor-Icon-Theme
    ICEAuth JSON-Glib Json-C Lame LCMS LibCanberra Lesstif LibDRM LibDMX
    LibEpoxy LibEvdev LibEvent LibFontenc LibGLVnd LibiCal LibICE LibJPEG-Turbo
    LibNotify LibOGG LibPCIAccess LibPNG LibPthread-Stubs LibSecret LibSigc++
    LibSM LibSndfile LibTheora LibUnwind LibVA LibVDPAU LibVorbis LibWebP LibX11
    LibXau LibXaw LibXCB LibXcomposite LibXcursor LibXdamage LibXdmcp LibXext
    LibXfixes LibXfont2 LibXft LibXi LibXinerama LibXKBfile LibXmu LibXpm
    LibXpresent LibXRandR LibXrender LibXres LibXScrnSaver LibXShmfence
    LibXSLT LibXt LibXtst LibXv LibXvMC LibXxf86dga LibXxf86vm Mesa MkFontScale
    MPG123 MtDev ORC Pango PangoMM Poppler Pixman PulseAudio SetXKBMap SDL PulseAudio-Ctl
    Shared-MIME-info SpeexDSP Startup-Notification WavPack SPICE-Protocol T1Lib
    XAuth XCB-Util XCB-Util-Image XCB-Util-Renderutil XCB-Util-WM XDG-Utils
    Xev Xhost Xinit Xorg Xorg-App Xorg-cf-files Xorg-Driver Xorg-Font Xorg-Lib
    Xorg-Proto Xorg-Server Xpdf Xterm
)

build_003_xorg() {
    log "=== 003-xorg.xzm ==="
    local staging="$WORK_DIR/staging/003-xorg"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${XORG_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        sync_gobo_program "$src" "$staging/Programs/" "runtime"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada paket Xorg ditemukan"

    make_xzm "$staging" "$OUTPUT_DIR/porteux/base/003-xorg.xzm" "003-xorg.xzm"
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
        sync_gobo_program "$src" "$staging/Programs/" "runtime"
        info "+ $prog"
        count=$((count + 1))
    done
    [ "$count" -eq 0 ] && warn "Tidak ada paket desktop ditemukan"

    make_xzm "$staging" "$OUTPUT_DIR/porteux/base/004-desktop.xzm" "004-desktop.xzm"
}
# ── 005-dev.xzm ───────────────────────────────────────────────────────────
# ── List Program Modul 005-dev ────────────────────────────────────────────────
# 05-dev.xzm: SEMUA program yang punya headers/source/pkgconfig
# Mencakup semua program dari modul lain — mode "dev" hanya ambil
# include/, lib/pkgconfig/, lib/*.a, lib/*.la, share/aclocal/
DEV_PROGS=(
    # Compiler & build tools
    Gcc Binutils Make M4 Bison Flex
    Autoconf Automake Libtool Pkg-config
    # Kernel headers
    Linux-Headers
    # Core libraries — headers dibutuhkan untuk compile
    Glibc Zlib Openssl
    PCRE PCRE2 Readline Ncurses NcursesW
    LibPng LibJpeg-turbo LibTiff
    Pixman Cairo Pango HarfBuzz FreeType FontConfig
    # X11 headers
    LibX11 LibXext LibXrender LibXft LibXi LibXtst
    LibXfixes LibXcomposite LibXdamage LibXrandr
    LibDRM LibGLVND Mesa
    # System libraries
    Dbus Udev Eudev Linux-PAM
    Glib GObject-Introspection Atk Gtk+ Gtk+3 Gdk-Pixbuf
    # Scripting
    Perl Lua
    # Dev tools
    Git Curl Wget
)
build_005_dev() {
    log "=== 05-dev.xzm (Headers + Source + pkgconfig) ==="
    local staging="$WORK_DIR/staging/05-dev"
    mkdir -p "$staging/Programs"

    local count=0
    for prog in "${DEV_PROGS[@]}"; do
        local src="$WORK_DIR/gobo-root/Programs/$prog"
        [ -d "$src" ] || continue
        info "+ $prog (dev/full)"
        sync_gobo_program "$src" "$staging/Programs/" "dev"
        count=$((count + 1))
    done
    
    # Tambahkan symlink linker untuk dev
    if [ "$count" -gt 0 ]; then
        make_xzm "$staging" "$OUTPUT_DIR/porteux/optional/05-dev.xzm" "05-dev.xzm"
    else
        warn "Modul dev kosong, tidak dibuat."
    fi
}
# ── 1. \\\Fungsi Kolektor Link Current ──────────────────────────────────────────
# Menghasilkan skrip yang akan membuat link Current secara dinamis saat boot
generate_current_script() {
    log "Menghasilkan skrip pemetaan Current: $CURRENT_MAP_FILE"
    local source_root="$WORK_DIR/gobo-root/Programs"
    
    cat > "$WORK_DIR/$CURRENT_MAP_FILE" << 'EOF'
#!/bin/bash
# Restorasi link Current secara dinamis untuk GoboLinux 17.01
echo "--- Menginisialisasi Symlink Current di /Programs ---"
EOF

    # Scan semua link 'Current' di root asli
    find "$source_root" -maxdepth 2 -name "Current" -type l | while read -r link; do
        local app
        app=$(basename "$(dirname "$link")")
        local target
        target=$(readlink "$link")
        
        # Tambahkan perintah pembuatan link ke skrip
        echo "ln -snf \"$target\" \"/Programs/$app/Current\"" >> "$WORK_DIR/$CURRENT_MAP_FILE"
    done
    
    chmod +x "$WORK_DIR/$CURRENT_MAP_FILE"
}
# ── porteux.cfg & grub.cfg ─────────────────────────────────────────────────────
create_boot_config() {
    log "Membuat porteux.cfg dan grub.cfg..."

    cat > "$OUTPUT_DIR/boot/syslinux/porteux.cfg" << 'SYSLINUX_EOF'
# GoboLinux 017.01 Live  —  porteux-style boot config
PROMPT 0
TIMEOUT 90
DEFAULT graphics

# UI vesamenu.c32 dibutuhkan dari sumber yang SAMA dengan libcom32.c32
# Semua .c32 harus dari Porteus ISO — jangan campur dari sumber berbeda
UI vesamenu.c32
MENU TITLE  GoboLinux 017.01 Live  [porteux-style]

LABEL graphics
  MENU LABEL  GoboLinux — Graphical (AwesomeWM)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteux changes=/porteux/changes quiet splash

LABEL text
  MENU LABEL  GoboLinux — Text Mode
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteux changes=/porteux/changes 3

LABEL copy2ram
  MENU LABEL  GoboLinux — Copy to RAM (~2GB RAM needed)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteux changes=/porteux/changes copy2ram

LABEL fresh
  MENU LABEL  GoboLinux — Always Fresh (no save)
  KERNEL /boot/syslinux/vmlinuz
  APPEND initrd=/boot/syslinux/initrd.xz from=/porteux nomagic

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
    linux  /boot/syslinux/vmlinuz from=/porteux changes=/porteux/changes quiet splash
    initrd /boot/syslinux/initrd.xz
}
menuentry "GoboLinux Text Mode" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteux changes=/porteux/changes 3
    initrd /boot/syslinux/initrd.xz
}
menuentry "GoboLinux Copy to RAM" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteux changes=/porteux/changes copy2ram
    initrd /boot/syslinux/initrd.xz
}
menuentry "GoboLinux Always Fresh" {
    search -f /boot/syslinux/vmlinuz --set=root
    linux  /boot/syslinux/vmlinuz from=/porteux nomagic
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
           -o -name "porteux.cfg" -o -name "grub.cfg" \) \
        2>/dev/null | sort | while read -r f; do
        printf "  %-10s  %s\n" "$(du -sh "$f" | cut -f1)" "${f#$OUTPUT_DIR/}"
    done
    echo ""
    echo "LANGKAH BERIKUTNYA:"
    echo ""
    echo "1. Build initrd baru (WAJIB sebelum boot):"
    echo "   sudo bash scripts/build-initrd.sh \\"
    echo "     --gobo017initrd $OUTPUT_DIR/boot/syslinux/initrd-gobo-orig \\"
    echo "     --output $OUTPUT_DIR/boot/syslinux/initrd.xz"
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

    log "GoboLinux → porteux-style Live Builder"
    log "ISO    : $GOBO_ISO"
    log "Output : $OUTPUT_DIR"
    log "Kompresi modul: $COMP | Block: $BLOCK_SIZE"

    trap 'umount "$WORK_DIR/iso" 2>/dev/null || true; rm -rf "$WORK_DIR"' EXIT
    # GOBO_ROOT_DIR tidak dihapus trap — dibutuhkan oleh build-initrd.sh
    mkdir -p "$WORK_DIR"

    mkdir -p \
        "$OUTPUT_DIR/boot/syslinux" \
        "$OUTPUT_DIR/EFI/boot" \
        "$OUTPUT_DIR/porteux/base" \
        "$OUTPUT_DIR/porteux/modules" \
        "$OUTPUT_DIR/porteux/optional" \
        "$OUTPUT_DIR/porteux/changes"

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

    # 3b. Lengkapi syslinux dari porteux ISO (lebih lengkap dari GoboLinux)
    extract_syslinux_from_porteux

    # 4. Ekstrak squashfs
    extract_squashfs "$SQUASHFS_SRC"
    # 5. Jalankan kolektor sebelum memproses modul
    generate_current_script
    # 6. Build modul .xzm
    build_000_kernel
    build_001_base
	build_002_gobo_rest
    build_002_gobotool
    build_003_xorg
    build_004_desktop
    build_005_dev
    # 7. Buat konfigurasi bootloader
    create_boot_config

    show_summary
}

main "$@"
