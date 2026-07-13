#!/bin/bash
# build-initrd.sh
# ─────────────────────────────────────────────────────────────────────────────
# Membangun initramfs untuk GoboLinux 017 Live (Porteux-style)
#
# STRATEGI BARU (berdasarkan temuan):
#   GoboLinux 017 initramfs bisa diekstrak dengan unmkinitramfs dan berisi:
#     early/  — microcode AMD/Intel
#     main/   — filesystem lengkap termasuk:
#               Programs/Linux/6.12.16/lib/modules/6.12.16-Gobo/kernel/
#               bin/busybox, sbin/*, lib/*, dll
#
#   Kita GUNAKAN main/ dari initramfs GoboLinux 017 sebagai base,
#   lalu GANTI /init-nya dengan init kita yang mount .xzm Porteux-style.
#   BusyBox dan semua modul kernel sudah ada di dalamnya.
#
# Usage:
#   sudo bash build-initrd.sh \
#     --gobo017initrd /path/to/initramfs-gobo-orig \
#     --porteux-initrd /path/to/porteux/boot/syslinux/initrd.xz \
#     --output        /path/to/initrd.xz
#
# --porteux-initrd: initrd.xz dari ISO Porteux — sumber BusyBox statik.
#   Porteux memakai BusyBox statik dengan semua applet lengkap.
#   Jika tidak disediakan, script mencari di PORTEUX_INITRD env atau auto-detect.
#
# Optional (backward compat, diabaikan):
#   --gobo016  GoboLinux-016.iso
#   --slax     slax.iso
#   --gobo017root /path
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Parse argumen ─────────────────────────────────────────────────────────────
GOBO017_INITRD=""
OUTPUT_INITRD=""
PORTEUX_INITRD="${PORTEUX_INITRD:-}"  # initrd.xz porteux untuk BusyBox
# Argumen lama tetap diterima tapi diabaikan (backward compat)
GOBO016_ISO=""
SLAX_ISO=""
GOBO017_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --gobo017initrd) GOBO017_INITRD="$2"; shift 2 ;;
        --output)        OUTPUT_INITRD="$2";  shift 2 ;;
        # Backward compat — diabaikan
        --porteux-initrd) PORTEUX_INITRD="$2"; shift 2 ;;
        --gobo016)       GOBO016_ISO="$2";    shift 2 ;;
        --slax)          SLAX_ISO="$2";       shift 2 ;;
        --gobo017root)   GOBO017_ROOT="$2";   shift 2 ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Argumen tidak dikenal: $1"; exit 1 ;;
    esac
done

[ -n "$OUTPUT_INITRD" ] || { echo "ERROR: --output wajib"; exit 1; }
[ "$(id -u)" = "0" ]    || { echo "ERROR: harus root (sudo)"; exit 1; }

WORK="$(mktemp -d /tmp/gobo-initrd-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' C='\033[0;36m' N='\033[0m'
# Semua log ke stderr agar tidak mengganggu $() capture return value
log()  { echo -e "${G}[$(date +%H:%M:%S)]${N} $*" >&2; }
info() { echo -e "${C}  ↳${N} $*" >&2; }
warn() { echo -e "${Y}[WARN]${N} $*" >&2; }
die()  { echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }

INITRD_DIR="$WORK/initrd"

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 1: Temukan initramfs GoboLinux 017
# Cari dari: --gobo017initrd, atau dari output build-gobo-live.sh
# ─────────────────────────────────────────────────────────────────────────────
find_gobo017_initrd() {
    log "=== Cari initramfs GoboLinux 017 ==="

    # Dari argumen eksplisit
    if [ -n "$GOBO017_INITRD" ]; then
        [ -f "$GOBO017_INITRD" ] || die "File tidak ada: $GOBO017_INITRD"
        info "Dari argumen: $GOBO017_INITRD"
        echo "$GOBO017_INITRD"
        return 0
    fi

    # Cari dari output build-gobo-live.sh
    local output_boot
    output_boot="$(dirname "$OUTPUT_INITRD")"

    local candidates=(
        "$output_boot/initrd-gobo-orig"
        "$output_boot/initrd-gobo-orig.xz"
        "$output_boot/initramfs"
        "$output_boot/../../../boot/syslinux/initrd-gobo-orig"
    )

    log "  Mencari di:"
    for f in "${candidates[@]}"; do
        log "    $f — $([ -f "$f" ] && echo ADA || echo tidak ada)"
        if [ -f "$f" ]; then
            info "Ditemukan: $f"
            echo "$f"
            return 0
        fi
    done

    # Scan seluruh output dir untuk file yang mirip initramfs
    log "  Scan output dir untuk file initramfs..."
    local found_scan
    found_scan=$(find "$output_boot" -maxdepth 2 \
        \( -name "initrd*" -o -name "initramfs*" \) \
        -not -name "*.xz" -not -name "*.gz" 2>/dev/null | head -1)
    if [ -z "$found_scan" ]; then
        found_scan=$(find "$output_boot" -maxdepth 2 \
            \( -name "initrd*" -o -name "initramfs*" \) \
            2>/dev/null | head -1)
    fi
    if [ -n "$found_scan" ]; then
        info "Ditemukan via scan: $found_scan"
        echo "$found_scan"
        return 0
    fi

    die "initramfs GoboLinux 017 tidak ditemukan!

Solusi:
  1. Pastikan sudah menjalankan: sudo make build
  2. Atau gunakan argumen eksplisit:
     sudo bash build-initrd.sh \
       --gobo017initrd /path/ke/initramfs-dari-iso-gobolinux017 \
       --output $OUTPUT_INITRD

Lokasi yang dicari: ${candidates[*]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 2: Ekstrak initramfs GoboLinux 017 dengan unmkinitramfs
# Menghasilkan: early/ dan main/
# ─────────────────────────────────────────────────────────────────────────────
extract_gobo017_initrd() {
    local initrd_file="$1"
    log "=== Ekstrak initramfs GoboLinux 017 ==="
    info "File: $initrd_file"
    info "Format: $(file -b "$initrd_file" | cut -c1-60)"
    info "Ukuran: $(du -sh "$initrd_file" | cut -f1)"

    local extract_dir="$WORK/gobo017-initrd"
    mkdir -p "$extract_dir"

    # unmkinitramfs adalah tool standar dari initramfs-tools
    if command -v unmkinitramfs &>/dev/null; then
        log "  Menggunakan unmkinitramfs..."
        unmkinitramfs "$initrd_file" "$extract_dir" 2>&1 | \
            while read -r l; do info "$l"; done
    else
        warn "unmkinitramfs tidak ada — install: apt install initramfs-tools"
        warn "Mencoba ekstrak manual..."

        # Coba split early_cpio + main cpio manual
        # Format: [early cpio tidak terkompresi] + [main cpio terkompresi]
        local fmt; fmt=$(file -b "$initrd_file")

        mkdir -p "$extract_dir/main"

        if echo "$fmt" | grep -qi "Zstandard"; then
            # GoboLinux 017: zstd
            if command -v zstd &>/dev/null; then
                # Skip early_cpio (cari offset zstd magic: FD 2F B5 28)
                local offset
                offset=$(grep -boa $'\xfd\x2f\xb5\x28' "$initrd_file" | head -1 | cut -d: -f1 || echo "0")
                if [ "$offset" -gt 0 ]; then
                    info "  Offset zstd ditemukan: $offset bytes"
                    # Ekstrak early_cpio dulu
                    head -c "$offset" "$initrd_file" | \
                        (cd "$extract_dir" && cpio -id --quiet 2>/dev/null || true)
                    # Ekstrak main
                    tail -c "+$((offset+1))" "$initrd_file" | \
                        zstdcat | (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null || true)
                else
                    zstdcat "$initrd_file" | \
                        (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null || true)
                fi
            else
                die "zstd tidak ada: apt install zstd"
            fi
        elif echo "$fmt" | grep -qi "XZ"; then
            xzcat "$initrd_file" | \
                (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null || true)
        elif echo "$fmt" | grep -qi "gzip"; then
            zcat "$initrd_file" | \
                (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null || true)
        else
            # Coba semua
            zstdcat "$initrd_file" 2>/dev/null | \
                (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null) || \
            xzcat "$initrd_file" 2>/dev/null | \
                (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null) || \
            zcat "$initrd_file" 2>/dev/null | \
                (cd "$extract_dir/main" && cpio -id --quiet 2>/dev/null) || \
            die "Gagal mengekstrak initramfs"
        fi
    fi

    log "=== Hasil ekstraksi ==="
    info "Isi $extract_dir:"
    ls "$extract_dir/" | while read -r d; do info "  $d/"; done

    # Verifikasi: cari Programs/Linux dan modules
    local main_dir=""
    for candidate in "$extract_dir/main" "$extract_dir"; do
        if [ -d "$candidate/Programs/Linux" ]; then
            main_dir="$candidate"
            info "Main filesystem di: $main_dir"
            break
        fi
    done

    if [ -n "$main_dir" ]; then
        local kver_dir
        kver_dir=$(find "$main_dir/Programs/Linux" -path "*/lib/modules/*/kernel" \
                   -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
        if [ -n "$kver_dir" ]; then
            local kver; kver=$(basename "$kver_dir")
            info "Kernel modules: $kver"
            info "Total .ko: $(find "$kver_dir" -name '*.ko' 2>/dev/null | wc -l)"
            info "Drivers tersedia:"
            ls "$kver_dir/kernel/drivers/" 2>/dev/null | while read -r d; do
                info "    drivers/$d/"
            done
        else
            warn "Tidak menemukan lib/modules di main/"
        fi

        local bb="$main_dir/bin/busybox"
        if [ -f "$bb" ]; then
            info "BusyBox: $(file -b "$bb" | cut -c1-50)"
        else
            info "BusyBox tidak ada di $main_dir/bin/busybox (akan diambil dari Porteux)"
        fi
    else
        warn "Programs/Linux tidak ditemukan — struktur initramfs mungkin berbeda"
        info "Isi direktori extract:"
        find "$extract_dir" -maxdepth 3 | sort | head -40 | while read -r f; do
            info "  ${f#$extract_dir/}"
        done
    fi

    echo "$extract_dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 3: Salin main/ dari GoboLinux 017 initramfs sebagai base initrd kita
# ─────────────────────────────────────────────────────────────────────────────
build_from_gobo017_main() {
    local extract_dir="$1"
    log "=== Build initrd dari GoboLinux 017 main/ ==="

    # Tentukan main_dir
    local main_dir=""
    for candidate in "$extract_dir/main" "$extract_dir"; do
        if [ -d "$candidate/Programs/Linux" ] || [ -f "$candidate/bin/busybox" ]; then
            main_dir="$candidate"
            break
        fi
    done

    if [ -z "$main_dir" ]; then
        # Fallback: pakai seluruh extract_dir
        main_dir="$extract_dir"
        warn "Menggunakan seluruh extract_dir sebagai main"
    fi

    info "Sumber: $main_dir"
    info "Ukuran: $(du -sh "$main_dir" | cut -f1)"

    # Salin seluruh main/ ke INITRD_DIR
    log "  Menyalin filesystem GoboLinux 017..."
    mkdir -p "$INITRD_DIR"
    cp -a "$main_dir/." "$INITRD_DIR/"
    # --- Dekompresi modul kernel .ko.zst dan regenerasi modules.dep ---
    log "  Memeriksa kompresi modul kernel (.ko.zst)..."
    # Cari direktori kver: INITRD_DIR/lib/modules/<kver>/
    local kver_path=""
    if [ -d "$INITRD_DIR/lib/modules" ]; then
        kver_path=$(find "$INITRD_DIR/lib/modules" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
    else
        # GoboLinux: modules di Programs/Linux/<ver>/lib/modules/<kver>
        kver_path=$(find "$INITRD_DIR" -path "*/Programs/Linux/*/lib/modules/*" \
                    -mindepth 5 -maxdepth 6 -type d 2>/dev/null | sort -V | tail -1)
    fi

    if [ -n "$kver_path" ] && [ -d "$kver_path" ]; then
        local kver; kver=$(basename "$kver_path")
        info "  Direktori modules: $kver_path"
        info "  Kernel versi: $kver"
        local zst_count
        zst_count=$(find "$kver_path" -name "*.ko.zst" 2>/dev/null | wc -l)
        info "  .ko.zst ditemukan: $zst_count"

        if [ "$zst_count" -gt 0 ]; then
            if command -v zstd &>/dev/null; then
                log "  Dekompresi $zst_count file .ko.zst..."
                find "$kver_path" -name "*.ko.zst" | while read -r f; do
                    zstd -d --rm "$f" 2>/dev/null || true
                done
                info "  Dekompresi selesai (.ko.zst → .ko)"
            else
                warn "  zstd tidak ada di host — .ko.zst tidak bisa didekompresi!"
            fi
        fi

        # Regenerasi modules.dep dengan base yang benar
        # depmod -b BASE KVER: BASE = root initrd, KVER = versi kernel
        if command -v depmod &>/dev/null; then
            local depmod_base="$INITRD_DIR"
            # Jika modules di Programs/Linux, base harus parent dari lib/
            if echo "$kver_path" | grep -q "Programs/Linux"; then
                depmod_base=$(echo "$kver_path" | sed "s|/lib/modules/$kver||")
            fi
            info "  Regenerasi modules.dep: depmod -b $depmod_base $kver"
            depmod -b "$depmod_base" "$kver" 2>/dev/null && \
                info "  modules.dep diperbarui" || \
                warn "  depmod gagal — modprobe mungkin tidak bekerja"
        else
            warn "  depmod tidak ada di host — modules.dep tidak diperbarui"
        fi
    else
        info "  Tidak ada direktori modules ditemukan (kernel mungkin monolitik)"
    fi
    # ----------------------------------------
    # Pastikan direktori wajib ada
    mkdir -p \
        "$INITRD_DIR/proc" \
        "$INITRD_DIR/sys" \
        "$INITRD_DIR/dev" \
        "$INITRD_DIR/dev/pts" \
        "$INITRD_DIR/tmp" \
        "$INITRD_DIR/run" \
        "$INITRD_DIR/mnt" \
        "$INITRD_DIR/mnt/scan" \
        "$INITRD_DIR/mnt/xzm" \
        "$INITRD_DIR/mnt/up" \
        "$INITRD_DIR/mnt/wk" \
        "$INITRD_DIR/mnt/new"

    # Device nodes minimal (mungkin sudah ada dari GoboLinux, tapi pastikan)
    [ -c "$INITRD_DIR/dev/console" ] || mknod -m 600 "$INITRD_DIR/dev/console" c 5 1
    [ -c "$INITRD_DIR/dev/null"    ] || mknod -m 666 "$INITRD_DIR/dev/null"    c 1 3
    [ -c "$INITRD_DIR/dev/tty"     ] || mknod -m 666 "$INITRD_DIR/dev/tty"     c 5 0
    [ -c "$INITRD_DIR/dev/tty1"    ] || mknod -m 660 "$INITRD_DIR/dev/tty1"    c 4 1

    info "Isi INITRD_DIR (top level):"
    ls "$INITRD_DIR/" | while read -r d; do info "  $d"; done

    local ko_count
    ko_count=$(find "$INITRD_DIR" -name '*.ko' 2>/dev/null | wc -l)
    info ".ko files: $ko_count"

    local kver
    kver=$(find "$INITRD_DIR" -path "*/lib/modules/*/kernel" -type d 2>/dev/null \
           | head -1 | xargs dirname 2>/dev/null | xargs basename 2>/dev/null || true)
    [ -n "$kver" ] && info "Kernel version: $kver"
}


# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 4: Salin early_cpio (microcode) untuk digabung saat pack
# ─────────────────────────────────────────────────────────────────────────────
save_early_cpio() {
    local extract_dir="$1"
    log "=== Simpan early_cpio (microcode) ==="

    # unmkinitramfs menghasilkan early/ atau early0/, early1/, dst
    local early_dir=""
    for candidate in "$extract_dir/early" "$extract_dir/early0"; do
        [ -d "$candidate" ] && { early_dir="$candidate"; break; }
    done

    if [ -n "$early_dir" ]; then
        info "early_cpio: $early_dir"
        info "Isi:"
        find "$early_dir" -not -type d | head -10 | while read -r f; do
            info "  ${f#$early_dir/}"
        done
        # Simpan sebagai cpio untuk digabung
        (cd "$early_dir" && find . | cpio -o -H newc --quiet 2>/dev/null) \
            > "$WORK/early.cpio"
        info "early.cpio: $(du -sh "$WORK/early.cpio" | cut -f1)"
    else
        info "Tidak ada early_cpio (microcode) — tidak apa-apa"
        touch "$WORK/early.cpio"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 2b: Ekstrak BusyBox dari initrd.xz porteux
# porteux initrd.xz berisi BusyBox statik yang dikompilasi dengan semua
# applet yang dibutuhkan (mount, mknod, switch_root, sleep, dll).
# Ini menggantikan BusyBox dari GoboLinux yang mungkin tidak ada.
# ─────────────────────────────────────────────────────────────────────────────
extract_busybox_from_PORTEUX_INITRD() {
    log "=== Ekstrak BusyBox dari porteux initrd ==="

    # Gunakan variabel global PORTEUX_INITRD (jangan re-declare sebagai local)
    local porteux_input="$PORTEUX_INITRD"
    local porteux_extract="$WORK/porteux-initrd-extract"
    local porteux_iso_mnt="$WORK/porteux-iso-mnt"
    local actual_initrd=""

    # Auto-detect: cari porteux-initrd.xz di output build
    if [ -z "$porteux_input" ]; then
        local output_syslinux
        output_syslinux="$(dirname "$OUTPUT_INITRD")"
        for candidate in \
            "$output_syslinux/porteux-initrd.xz" \
            "$output_syslinux/porteus-initrd.xz"
        do
            [ -f "$candidate" ] && { porteux_input="$candidate"; break; }
        done
    fi

    if [ -z "$porteux_input" ] || [ ! -f "$porteux_input" ]; then
        warn "porteux initrd/ISO tidak ditemukan — BusyBox tidak diinstall"
        warn "Gunakan: --porteux-initrd /path/to/porteux.iso"
        warn "Atau jalankan dulu: sudo make build PORTEUX_ISO=/path/to/porteux.iso"
        return 0
    fi

    local fmt
    fmt=$(file -b "$porteux_input" 2>/dev/null)
    log "  Input : $porteux_input"
    log "  Format: $(echo "$fmt" | cut -c1-60)"
    log "  Ukuran: $(du -sh "$porteux_input" | cut -f1)"

    mkdir -p "$porteux_extract"

    # ── Jika input adalah ISO Porteux: mount dan ambil initrd dari dalamnya ──
    if echo "$fmt" | grep -qi "ISO 9660\|UDF\|CD-ROM"; then
        log "  Input adalah ISO — mount dan ambil initrd..."
        mkdir -p "$porteux_iso_mnt"
        if mount -o loop,ro "$porteux_input" "$porteux_iso_mnt" 2>/dev/null; then

            log "  Isi boot/ dalam ISO:"
            find "$porteux_iso_mnt/boot" -maxdepth 2 2>/dev/null | sort | \
                while read -r f; do info "    ${f#$porteux_iso_mnt}"; done

            for candidate in \
                "$porteux_iso_mnt/boot/syslinux/initrd.xz" \
                "$porteux_iso_mnt/boot/syslinux/initrd.zst" \
                "$porteux_iso_mnt/boot/syslinux/initrd.img" \
                "$porteux_iso_mnt/boot/isolinux/initrd.xz" \
                "$porteux_iso_mnt/porteux/boot/initrd.xz" \
                "$porteux_iso_mnt/porteus/boot/initrd.xz"
            do
                [ -f "$candidate" ] || continue
                # Salin ke /tmp agar tetap bisa diakses setelah umount
                local tmp_initrd="$WORK/porteux-initrd-tmp.xz"
                cp "$candidate" "$tmp_initrd"
                actual_initrd="$tmp_initrd"
                log "  Initrd ditemukan: ${candidate#$porteux_iso_mnt} ($(du -sh "$tmp_initrd" | cut -f1))"
                break
            done

            umount "$porteux_iso_mnt" 2>/dev/null || true
        else
            warn "  Gagal mount ISO: $porteux_input"
        fi

        if [ -z "$actual_initrd" ]; then
            warn "  initrd tidak ditemukan di dalam ISO Porteus"
            return 0
        fi
    else
        # Input sudah berupa file initrd langsung
        actual_initrd="$porteux_input"
    fi

    # ── Ekstrak initrd ───────────────────────────────────────────────────────
    local initrd_fmt
    initrd_fmt=$(file -b "$actual_initrd" 2>/dev/null)
    log "  Ekstrak initrd: $(echo "$initrd_fmt" | cut -c1-50)"

    local extracted=0
    if (cd "$porteux_extract" && xzcat "$actual_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null); then
        extracted=1; log "  Ekstrak: xz OK"
    elif (cd "$porteux_extract" && zstdcat "$actual_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null); then
        extracted=1; log "  Ekstrak: zstd OK"
    elif (cd "$porteux_extract" && zcat "$actual_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null); then
        extracted=1; log "  Ekstrak: gzip OK"
    fi

    # Fallback unmkinitramfs untuk format early_cpio+main
    if [ "$extracted" -eq 0 ] && command -v unmkinitramfs &>/dev/null; then
        unmkinitramfs "$actual_initrd" "$porteux_extract" 2>/dev/null && \
            { extracted=1; log "  Ekstrak: unmkinitramfs OK"; }
    fi

    # Jika ada subdir main/ (format GoboLinux/dracut), busybox ada di sana
    local search_root="$porteux_extract"
    for subdir in "$porteux_extract/main" "$porteux_extract/rootfs"; do
        [ -d "$subdir" ] && { search_root="$subdir"; log "  Search root: $subdir"; break; }
    done

    # Tampilkan struktur untuk debug
    log "  Struktur initrd (3 level):"
    find "$search_root" -maxdepth 3 2>/dev/null | sort | head -30 | \
        while read -r f; do info "    ${f#$search_root/}"; done

    # ── Cari busybox ─────────────────────────────────────────────────────────
    local bb_found=""

    # Level 1: path standar
    for candidate in \
        "$search_root/bin/busybox" \
        "$search_root/usr/bin/busybox" \
        "$search_root/sbin/busybox" \
        "$search_root/busybox"
    do
        [ -f "$candidate" ] && { bb_found="$candidate"; break; }
    done

    # Level 2: scan nama
    [ -z "$bb_found" ] && \
        bb_found=$(find "$search_root" -name "busybox" -type f 2>/dev/null | head -1)

    # Level 3: ELF statik terbesar
    if [ -z "$bb_found" ]; then
        log "  Scan ELF statik (fallback)..."
        while IFS= read -r -d "" f; do
            file -b "$f" 2>/dev/null | grep -qi "statically linked" || continue
            local fsz; fsz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            [ "$fsz" -gt 524288 ] && { bb_found="$f"; break; }
        done < <(find "$search_root" -type f -print0 2>/dev/null)
        [ -n "$bb_found" ] && log "  ELF statik: ${bb_found#$search_root/}"
    fi

    if [ -n "$bb_found" ]; then
        cp "$bb_found" "$WORK/busybox-from-porteux"
        chmod +x "$WORK/busybox-from-porteux"
        log "  BusyBox: ${bb_found#$search_root/}"
        log "  Format : $(file -b "$WORK/busybox-from-porteux" | cut -c1-60)"
        log "  Ukuran : $(du -sh "$WORK/busybox-from-porteux" | cut -f1)"
        echo "$WORK/busybox-from-porteux" > "$(dirname "$OUTPUT_INITRD")/.busybox-path"
        log "  Path disimpan: $(dirname "$OUTPUT_INITRD")/.busybox-path"
    else
        warn "  BusyBox tidak ditemukan"
        warn "  File ELF di dalam initrd:"
        find "$search_root" -type f 2>/dev/null | while read -r f; do
            file -b "$f" 2>/dev/null | grep -qi "ELF" && \
                info "    ${f#$search_root/}"
        done || true
    fi

    rm -rf "$porteux_extract" "$porteux_iso_mnt" 2>/dev/null || true
}


# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 4b: Install BusyBox ke INITRD_DIR
# Salin busybox dari WORK ke bin/busybox dan buat symlink semua applet
# ─────────────────────────────────────────────────────────────────────────────
install_busybox_to_initrd() {
    log "=== Install BusyBox ke initrd ==="

    local bb_src="$WORK/busybox-from-porteux"

    # Cek apakah BusyBox sudah berhasil diekstrak dari Porteux
    if [ ! -f "$bb_src" ]; then
        # Coba baca dari .busybox-path
        local path_file
        path_file="$(dirname "$OUTPUT_INITRD")/.busybox-path"
        if [ -f "$path_file" ]; then
            bb_src=$(cat "$path_file")
            info "Baca dari .busybox-path: $bb_src"
        fi
    fi

    if [ -z "$bb_src" ] || [ ! -f "$bb_src" ]; then
        # Coba cari BusyBox di dalam GoboLinux initramfs yang sudah disalin
        # GoboLinux simpan di Programs/BusyBox/<ver>/bin/busybox
        info "Cari BusyBox di INITRD_DIR/Programs/BusyBox/..."
        local gobo_bb
        gobo_bb=$(find "$INITRD_DIR/Programs" -name "busybox" -type f 2>/dev/null | head -1)
        if [ -n "$gobo_bb" ]; then
            info "  Ditemukan: ${gobo_bb#$INITRD_DIR/}"
            bb_src="$gobo_bb"
        else
            warn "BusyBox tidak tersedia — initrd mungkin tidak bootable!"
            warn "Pastikan PORTEUX_ISO disetel: make initrd PORTEUX_ISO=/path/to/porteux.iso"
            return 0
        fi
    fi

    info "BusyBox: $bb_src"
    info "  Format: $(file -b "$bb_src" | cut -c1-60)"
    info "  Ukuran: $(du -sh "$bb_src" | cut -f1)"

    # Install ke INITRD_DIR/bin/busybox
    mkdir -p "$INITRD_DIR/bin" "$INITRD_DIR/sbin"
    cp "$bb_src" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"
    info "  Diinstall: $INITRD_DIR/bin/busybox"

    # Buat symlink semua applet yang dibutuhkan /init
    local applets=(
        sh ash cat echo ls mkdir rm mv cp ln
        mount umount losetup mknod switch_root
        sleep true false test
        dmesg uname modprobe
        find xargs sort
        chroot
    )
    local linked=0
    for app in "${applets[@]}"; do
        local dst="$INITRD_DIR/bin/$app"
        [ -e "$dst" ] || { ln -sf busybox "$dst" 2>/dev/null && linked=$((linked+1)); }
    done
    # Juga di sbin
    for app in switch_root mknod mount umount modprobe; do
        [ -e "$INITRD_DIR/sbin/$app" ] ||             ln -sf ../bin/busybox "$INITRD_DIR/sbin/$app" 2>/dev/null || true
    done
    info "  $linked symlinks applet dibuat"

    # Buat /bin/sh yang selalu ada (penting untuk /init dan shell darurat)
    [ -e "$INITRD_DIR/bin/sh" ] || ln -sf busybox "$INITRD_DIR/bin/sh"

    log "BusyBox terpasang di INITRD_DIR/bin/busybox"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 5: Tulis /init baru (ganti init GoboLinux 017 dengan init kita)
# ─────────────────────────────────────────────────────────────────────────────
write_init() {
    log "=== Tulis /init ==="

    # Backup init GoboLinux asli (untuk referensi)
    if [ -f "$INITRD_DIR/init" ]; then
        cp "$INITRD_DIR/init" "$INITRD_DIR/init.gobo-orig"
        info "Init GoboLinux asli disimpan ke /init.gobo-orig"
    fi

    # Tentukan path busybox yang tersedia
    local bb_path=""
    for candidate in \
        "$INITRD_DIR/bin/busybox" \
        "$INITRD_DIR/usr/bin/busybox" \
        "$INITRD_DIR/sbin/busybox"; do
        [ -f "$candidate" ] && { bb_path="${candidate#$INITRD_DIR}"; break; }
    done
    [ -n "$bb_path" ] && info "BusyBox: $bb_path" || warn "BusyBox tidak ditemukan!"

    # Deteksi PATH yang benar dari initramfs GoboLinux
    local gobo_path="/bin:/sbin:/usr/bin:/usr/sbin"
    if [ -d "$INITRD_DIR/System/Index/bin" ]; then
        gobo_path="/System/Index/bin:/System/Index/lib:$gobo_path"
        info "Menggunakan System/Index PATH"
    fi

    cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# /init — GoboLinux 017 Live, porteux-style
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

p() { echo "[init] $*"; }

die_shell() {
    p "=== SHELL DARURAT ==="
    exec setsid sh -c 'exec sh </dev/console >/dev/console 2>&1'
}

# ── 1. Pseudo-filesystems ────────────────────────────────────────────────────
mount -t proc     proc  /proc  2>/dev/null
mount -t sysfs    sysfs /sys   2>/dev/null
mount -t devtmpfs dev   /dev   2>/dev/null || mount -t tmpfs tmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /tmp /run
mount -t devpts devpts /dev/pts 2>/dev/null || true
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null
[ -c /dev/tty ]     || mknod -m 666 /dev/tty     c 5 0 2>/dev/null
[ -c /dev/null ]    || mknod -m 666 /dev/null     c 1 3 2>/dev/null
p "kernel: $(uname -r)"

# ── 2. Load drivers ──────────────────────────────────────────────────────────
p "loading hardware drivers..."
for mod in libahci ahci cdrom sr_mod sd_mod isofs squashfs overlay loop; do
    modprobe "$mod" 2>/dev/null || true
done
sleep 3

# ── 3. Parse cmdline ─────────────────────────────────────────────────────────
FROM_PATH=""
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in from=*) FROM_PATH="${arg#from=}" ;; esac
done

# ── 4. Cari media ────────────────────────────────────────────────────────────
p "mencari media..."
porteux_DIR=""
mkdir -p /mnt/scan

try_mount() {
    [ -b "$1" ] || return 1
    p "  mencoba $1 ($2)..."
    mount -t "$2" -o ro "$1" /mnt/scan 2>/dev/null || return 1
    if [ -d "/mnt/scan/porteux/base" ]; then
        porteux_DIR="/mnt/scan/porteux"; return 0
    fi
    umount /mnt/scan 2>/dev/null; return 1
}

scan_all() {
    for sr in /dev/sr*; do
        [ -b "$sr" ] && try_mount "$sr" "iso9660" && return 0
    done
    while read -r major minor blocks name; do
        case "$name" in ""|name|loop*|ram*|zram*) continue ;; esac
        for fs in vfat ext4 iso9660; do
            try_mount "/dev/$name" "$fs" && return 0
        done
    done < /proc/partitions
    return 1
}

scan_all || { p "GAGAL: Media tidak ditemukan."; die_shell; }
p "Media: $porteux_DIR"

# ── 5. Mount .xzm → OverlayFS ────────────────────────────────────────────────
p "assembling modules..."
mkdir -p /mnt/xzm /mnt/newroot
LOWER="" IDX=0

for xzm in "$porteux_DIR/base/"*.xzm "$porteux_DIR/modules/"*.xzm; do
    [ -f "$xzm" ] || continue
    mp="/mnt/xzm/$IDX"
    mkdir -p "$mp"
    if mount -t squashfs -o loop,ro "$xzm" "$mp" 2>/dev/null; then
        p "  +${xzm##*/}"
        LOWER="${LOWER:+$LOWER:}$mp"
        IDX=$((IDX+1))
    fi
done

[ -n "$LOWER" ] || { p "GAGAL: tidak ada .xzm ter-mount"; die_shell; }
p "  $IDX modul dimuat"

mkdir -p /mnt/cow
mount -t tmpfs -o mode=0755 tmpfs /mnt/cow
mkdir -p /mnt/cow/upper /mnt/cow/work

p "mount overlay..."
mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=/mnt/cow/upper,workdir=/mnt/cow/work" \
    /mnt/newroot || { p "GAGAL overlay"; die_shell; }
p "overlay OK"

# ── 6. Setup /dev /proc /sys di newroot ──────────────────────────────────────
p "setup newroot fs..."
mkdir -p /mnt/newroot/dev /mnt/newroot/proc /mnt/newroot/sys \
         /mnt/newroot/run /mnt/newroot/tmp

mount --bind /dev  /mnt/newroot/dev  2>/dev/null || \
    mount -t devtmpfs devtmpfs /mnt/newroot/dev 2>/dev/null || true
mkdir -p /mnt/newroot/dev/pts
mount --bind /dev/pts /mnt/newroot/dev/pts 2>/dev/null || \
    mount -t devpts devpts /mnt/newroot/dev/pts 2>/dev/null || true
mount --bind /proc /mnt/newroot/proc 2>/dev/null || \
    mount -t proc proc /mnt/newroot/proc 2>/dev/null || true
mount --bind /sys /mnt/newroot/sys 2>/dev/null || \
    mount -t sysfs sysfs /mnt/newroot/sys 2>/dev/null || true
mount -t tmpfs tmpfs /mnt/newroot/run 2>/dev/null || true
mount -t tmpfs tmpfs /mnt/newroot/tmp 2>/dev/null || true
[ -c /mnt/newroot/dev/console ] || \
    mknod -m 600 /mnt/newroot/dev/console c 5 1 2>/dev/null || true


# Hitung entries tanpa wc/ls pipe — pakai glob
bin_count=0
for f in /mnt/newroot/System/Index/bin/*; do [ -e "$f" ] && bin_count=$((bin_count+1)); done
lib_count=0
for f in /mnt/newroot/System/Index/lib/*; do [ -e "$f" ] && lib_count=$((lib_count+1)); done
p "  Programs diproses: $NR"
p "  System/Index/bin: $bin_count entries"
p "  System/Index/lib: $lib_count entries"

# ── 9. FHS symlinks ──────────────────────────────────────────────────────────
for pair in \
    "bin:/System/Index/bin" \
    "sbin:/System/Index/bin" \
    "lib:/System/Index/lib" \
    "lib64:/System/Index/lib"; do
    lnk="${pair%%:*}"; tgt="${pair#*:}"
    [ -e "/mnt/newroot/$lnk" ] || \
        ln -s "$tgt" "/mnt/newroot/$lnk" 2>/dev/null
done
[ -e /mnt/newroot/usr ] || ln -s "/" /mnt/newroot/usr 2>/dev/null || true

# ── 10. Cari init ─────────────────────────────────────────────────────────────
p "cari init..."

# Tampilkan semua Programs yang ada untuk diagnosis
p "  Programs tersedia:"
for prog_dir in /mnt/newroot/Programs/*/; do
    [ -d "$prog_dir" ] || continue
    pname="${prog_dir%/}"; pname="${pname##*/}"
    p "    $pname"
done

# Cari init binary langsung di setiap program
# GoboLinux 017 pakai: SysVInit, Sysvinit, sysvinit (huruf besar/kecil beda)
INIT=""
for prog_dir in /mnt/newroot/Programs/*/; do
    [ -d "$prog_dir" ] || continue
    pname="${prog_dir%/}"; pname="${pname##*/}"

    # Resolve versi
    cur="${prog_dir}Current"
    if [ -L "$cur" ]; then
        ver=$(readlink "$cur")
        case "$ver" in /*) ;; *) ver="${prog_dir}${ver}" ;; esac
    else
        ver=""
        for vd in "${prog_dir}"*/; do [ -d "$vd" ] && ver="${vd%/}"; done
    fi
    [ -d "$ver" ] || continue

    # Cek sbin/init dan bin/init di setiap program
    for sub in sbin bin; do
        ibin="$ver/$sub/init"
        if [ -x "$ibin" ]; then
            p "  FOUND: $pname/$sub/init"
            INIT="${ibin#/mnt/newroot}"
            break 2
        fi
    done
done

# Fallback: cek path via System/Index
[ -z "$INIT" ] && [ -x /mnt/newroot/System/Index/bin/init ] &&     INIT="/System/Index/bin/init"
[ -z "$INIT" ] && [ -x /mnt/newroot/sbin/init ] && INIT="/sbin/init"
[ -z "$INIT" ] && [ -x /mnt/newroot/bin/init ]  && INIT="/bin/init"

# Systemd fallback
[ -z "$INIT" ] && {
    for sd in         /mnt/newroot/Programs/Systemd/Current/lib/systemd/systemd         /mnt/newroot/Programs/Systemd/Current/bin/systemd         /mnt/newroot/lib/systemd/systemd; do
        [ -x "$sd" ] && { INIT="${sd#/mnt/newroot}"; break; }
    done
}

if [ -z "$INIT" ]; then
    p "  FATAL: copy busybox ke newroot untuk shell debug"
    cp /bin/busybox /mnt/newroot/bin/busybox 2>/dev/null || true
    ln -sf busybox /mnt/newroot/bin/sh 2>/dev/null || true
    INIT="/bin/sh"
fi

# ── /etc setup ───────────────────────────────────────────────────────────────
# Tulis langsung ke /mnt/cow/upper/etc/ (writable layer overlay)
# bypass /mnt/newroot/etc yang mungkin symlink ke squashfs read-only
p "setup /etc..."

# Pastikan etc ada di upper layer (selalu writable)
mkdir -p /mnt/cow/upper/etc

# Salin isi dari System/Settings jika ada
if [ -d /mnt/newroot/System/Settings ]; then
    for f in /mnt/newroot/System/Settings/*; do
        [ -f "$f" ] || continue
        fn="${f##*/}"
        [ -e "/mnt/cow/upper/etc/$fn" ] ||             cp "$f" "/mnt/cow/upper/etc/$fn" 2>/dev/null || true
    done
fi

# Cari inittab dari Programs/Sysvinit
if [ ! -f /mnt/cow/upper/etc/inittab ]; then
    for prog_dir in /mnt/newroot/Programs/*/; do
        [ -d "$prog_dir" ] || continue
        pname="${prog_dir%/}"
        pname="${pname##*/}"
        case "$pname" in
            [Ss]ys[Vv][Ii]nit|[Ss]ysvinit|SYSVINIT) ;;
            *) continue ;;
        esac
        cur="${prog_dir}Current"
        [ -L "$cur" ] || continue
        ver=$(readlink "$cur")
        case "$ver" in
            /*) ;;
            *) ver="${prog_dir}${ver}" ;;
        esac
        if [ -f "$ver/etc/inittab" ]; then
            cp "$ver/etc/inittab" /mnt/cow/upper/etc/inittab
            p "  inittab dari: $pname"
            break
        fi
    done
fi

# Cari BootDriver
BOOTDRIVER="/Programs/Scripts/Current/bin/BootDriver"
for bd in     /mnt/newroot/Programs/Scripts/Current/bin/BootDriver     /mnt/newroot/System/Index/bin/BootDriver     /mnt/newroot/sbin/BootDriver
do
    if [ -x "$bd" ]; then
        BOOTDRIVER="${bd#/mnt/newroot}"
        break
    fi
done
p "  BootDriver: $BOOTDRIVER"

# Generate inittab minimal langsung ke upper layer
if [ ! -f /mnt/cow/upper/etc/inittab ]; then
    p "  Generate inittab..."
    printf '%s\n'         '# /etc/inittab - GoboLinux 017 Live'         'id:3:initdefault:'         "si::sysinit:$BOOTDRIVER"         "l3:3:wait:$BOOTDRIVER RunLevel03"         'ca::ctrlaltdel:/sbin/shutdown -t3 -r now'         '1:2345:respawn:/sbin/getty 38400 tty1'         '2:23:respawn:/sbin/getty 38400 tty2'         > /mnt/cow/upper/etc/inittab
fi

if [ -f /mnt/cow/upper/etc/inittab ]; then
    p "  inittab: ADA di upper/etc"
    # Pastikan /mnt/newroot/etc mengarah ke upper/etc
    if [ -L /mnt/newroot/etc ]; then
        # /etc adalah symlink di squashfs — hapus dan buat direktori
        # (tidak bisa hapus di read-only layer, tapi bisa di upper)
        mkdir -p /mnt/cow/upper/etc
        # Buat whiteout entry agar overlay hide symlink
        # Alternatif: bind mount upper/etc ke /mnt/newroot/etc
        mount --bind /mnt/cow/upper/etc /mnt/newroot/etc 2>/dev/null || true
    elif [ ! -d /mnt/newroot/etc ]; then
        mount --bind /mnt/cow/upper/etc /mnt/newroot/etc 2>/dev/null || true
    fi
    # Verifikasi akhir
    if [ -f /mnt/newroot/etc/inittab ]; then
        p "  /mnt/newroot/etc/inittab: OK"
    else
        p "  WARN: inittab ada di upper tapi tidak terlihat di newroot/etc"
        p "  Coba bind mount..."
        mount --bind /mnt/cow/upper/etc /mnt/newroot/etc 2>/dev/null || true
        [ -f /mnt/newroot/etc/inittab ] && p "  bind mount OK" || p "  bind mount GAGAL"
    fi
else
    p "  FATAL: gagal tulis inittab ke upper/etc"
fi

# fstab minimal
[ -f /mnt/cow/upper/etc/fstab ] || printf '%s\n'     'proc  /proc  proc   defaults  0  0'     'sysfs /sys   sysfs  defaults  0  0'     > /mnt/cow/upper/etc/fstab 2>/dev/null || true

# ── switch_root ───────────────────────────────────────────────────────────────
p "exec switch_root -> $INIT"
exec switch_root /mnt/newroot "$INIT"
p "switch_root GAGAL"
die_shell
INIT_EOF

    chmod 755 "$INITRD_DIR/init"
    info "/init ditulis ($(wc -l < "$INITRD_DIR/init") baris)"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 6: Pack menjadi initramfs
# Format: [early_cpio tidak terkompresi] + [main cpio terkompresi zstd/xz]
# ─────────────────────────────────────────────────────────────────────────────
pack_initrd() {
    log "=== Pack initramfs ==="
    mkdir -p "$(dirname "$OUTPUT_INITRD")"

    log "  Isi INITRD_DIR (top 2 level):"
    find "$INITRD_DIR" -maxdepth 2 | sort | head -40 | while read -r f; do
        local rel="${f#$INITRD_DIR/}"
        [ -d "$f" ] && info "  DIR  $rel/" || info "  FILE $rel"
    done
    info ".ko count : $(find "$INITRD_DIR" -name "*.ko" 2>/dev/null | wc -l)"
    info "Ukuran    : $(du -sh "$INITRD_DIR" | cut -f1)"
    info "init ada  : $([ -f "$INITRD_DIR/init" ] && echo YA || echo TIDAK)"
    info "busybox   : $([ -f "$INITRD_DIR/bin/busybox" ] && echo YA || echo TIDAK)"

    # Porteus/Porteux pakai xz --check=crc32
    # xz lebih aman: semua kernel Linux support CONFIG_RD_XZ=y
    # zstd butuh CONFIG_RD_ZSTD=y yang tidak selalu aktif
    local COMP_EXT="xz"
    local COMP_CMD="xz -9 --check=crc32"
    info "Kompresi: xz --check=crc32 (Porteux-style)"

    # Pack main cpio ke file sementara (JANGAN pakai $() untuk binary data)
    local MAIN_COMP="$WORK/main.cpio.$COMP_EXT"
    log "  Pack main cpio..."
    ( cd "$INITRD_DIR" && find . | sort | cpio -o -H newc --quiet 2>/dev/null )         | $COMP_CMD > "$MAIN_COMP"
    info "  main cpio: $(du -sh "$MAIN_COMP" | cut -f1)"

    # Format porteux: cpio zstd saja (tanpa early_cpio di depan)
    # porteux tidak pakai early_cpio/microcode — microcode diurus oleh kernel/firmware
    # Jika ingin menyertakan microcode GoboLinux: aktifkan blok di bawah
    cp "$MAIN_COMP" "$OUTPUT_INITRD"
    info "Format: porteux-style (zstd cpio, tanpa early_cpio)"

    # [OPSIONAL] Aktifkan jika ingin early_cpio microcode GoboLinux:
    # if [ -s "$WORK/early.cpio" ]; then
    #     cat "$WORK/early.cpio" "$MAIN_COMP" > "$OUTPUT_INITRD"
    # fi

    log "  Output: $OUTPUT_INITRD ($(du -sh "$OUTPUT_INITRD" | cut -f1))"

    # Verifikasi — gunakan main.cpio langsung (bukan output gabungan)
    # karena output gabungan punya early uncompressed di depan
    log "  Verifikasi isi main cpio:"
    local VERIFY_DIR="$WORK/verify"
    rm -rf "$VERIFY_DIR" && mkdir -p "$VERIFY_DIR"

    # Verifikasi sesuai COMP_EXT yang dipilih
    if [ "$COMP_EXT" = "xz" ]; then
        xzcat "$MAIN_COMP" 2>/dev/null | cpio -id --quiet -D "$VERIFY_DIR" 2>/dev/null || true
    elif [ "$COMP_EXT" = "zst" ] || [ "$COMP_EXT" = "zstd" ]; then
        zstdcat "$MAIN_COMP" 2>/dev/null | cpio -id --quiet -D "$VERIFY_DIR" 2>/dev/null || true
    else
        xzcat "$MAIN_COMP" 2>/dev/null | cpio -id --quiet -D "$VERIFY_DIR" 2>/dev/null || true
    fi

    for check in "init" "bin/busybox" "lib/modules"; do
        if [ -e "$VERIFY_DIR/$check" ]; then
            info "    FOUND  : $check"
        else
            warn "    MISSING: $check"
            local found_at
            found_at=$(find "$VERIFY_DIR" -name "$(basename "$check")" 2>/dev/null | head -1)
            [ -n "$found_at" ] && info "      ada di: ${found_at#$VERIFY_DIR/}"
        fi
    done

    info "  Top-level initrd:"
    ls "$VERIFY_DIR/" 2>/dev/null | while read -r d; do info "    $d"; done

    log "=== pack selesai ==="
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log "=== build-initrd.sh (GoboLinux 017 initramfs base) ==="
    log "  Output: $OUTPUT_INITRD"
    [ -n "$GOBO017_INITRD"  ] && log "  initrd GoboLinux 017: $GOBO017_INITRD"
    [ -n "$SLAX_ISO"        ] && warn "  --slax diabaikan (BusyBox dari porteux initrd)"
    [ -n "$PORTEUX_INITRD"  ] && log  "  porteux initrd  : $PORTEUX_INITRD"
    [ -n "$GOBO016_ISO"     ] && warn "  --gobo016 diabaikan"
    [ -n "$GOBO017_ROOT"    ] && warn "  --gobo017root diabaikan (modules dari initramfs)"
    echo ""

    local initrd_file
    initrd_file=$(find_gobo017_initrd)

    local extract_dir
    extract_dir=$(extract_gobo017_initrd "$initrd_file")

    # Bangun base dari GoboLinux 017 main/ (kernel modules, libs, dll)
    build_from_gobo017_main "$extract_dir"

    # Simpan early_cpio (microcode AMD/Intel)
    save_early_cpio "$extract_dir"

    # Ekstrak BusyBox dari porteux initrd ke WORK
    extract_busybox_from_PORTEUX_INITRD

    # Install BusyBox dari WORK ke INITRD_DIR/bin/busybox + semua symlink applet
    install_busybox_to_initrd

    # Tulis /init script porteux-style
    write_init

    # Pack menjadi initrd.zstd
    pack_initrd

    echo ""
    log "=== SELESAI ==="
    echo ""
    echo "initrd siap: $OUTPUT_INITRD"
    echo "Selanjutnya: sudo make iso  atau  sudo make usb DEV=/dev/sdX"
}

main "$@"
