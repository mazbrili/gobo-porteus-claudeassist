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
            warn "BusyBox tidak ditemukan di $main_dir/bin/busybox"
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

    # ── Jika input adalah ISO Porteus: mount dan ambil initrd dari dalamnya ──
    if echo "$fmt" | grep -qi "ISO 9660\|UDF\|CD-ROM"; then
        log "  Input adalah ISO — mount dan ambil initrd..."
        mkdir -p "$porteux_iso_mnt"
        if mount -o loop,ro "$porteux_input" "$porteux_iso_mnt" 2>/dev/null; then

            log "  Isi boot/ dalam ISO:"
            find "$porteux_iso_mnt/boot" -maxdepth 2 2>/dev/null | sort | \
                while read -r f; do info "    ${f#$porteux_iso_mnt}"; done

            for candidate in \
                "$porteux_iso_mnt/boot/syslinux/initrd.xz" \
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
    if [ -d "$INITRD_DIR/System/Links/Executables" ]; then
        gobo_path="/System/Links/Executables:/System/Links/Libraries:$gobo_path"
        info "Menggunakan System/Links PATH"
    fi

    cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# /init — GoboLinux 017 Live, porteux-style
# Fokus: Perbaikan TTY dan Deteksi CD-ROM QEMU

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/System/Links/Executables

p() { echo "[init] $*"; }

# Perbaikan fungsi Shell Darurat agar TTY bisa diakses
die_shell() {
    p "=== SHELL DARURAT ==="
    p "Periksa apakah /dev/sr0 atau /dev/sd* ada di bawah ini:"
    ls -l /dev/sr* /dev/sd* /dev/vd* 2>/dev/null
    p "Isi /proc/partitions:"
    cat /proc/partitions 2>/dev/null
    
    # Memaksa shell menggunakan console agar job control aktif
    exec setsid sh -c 'exec sh </dev/console >/dev/console 2>&1'
}

# ── 1. Pseudo-filesystems ────────────────────────────────────────────────────
mount -t proc     proc  /proc    2>/dev/null
mount -t sysfs    sysfs /sys     2>/dev/null
# Penting: devtmpfs sangat disarankan agar QEMU otomatis membuat /dev/sr0
mount -t devtmpfs dev   /dev     2>/dev/null || mount -t tmpfs tmpfs /dev 2>/dev/null

mkdir -p /dev/pts /dev/shm /tmp /run
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs  tmpfs  /dev/shm 2>/dev/null

# Pastikan node dasar ada untuk shell
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null
[ -c /dev/tty ]     || mknod -m 666 /dev/tty     c 5 0 2>/dev/null

p "kernel: $(uname -r)"

# ── 2. Load Kernel Modules (Penting untuk Q35 & SATA) ────────────────────────
p "loading hardware drivers..."
# ahci & libahci: Untuk kontroler SATA di mesin Q35
# sr_mod & cdrom: Untuk pembaca CD-ROM
# sd_mod: Untuk akses disk (SATA diperlakukan seperti SCSI)
# isofs: Untuk membaca format ISO9660
for mod in libahci ahci cdrom sr_mod sd_mod isofs squashfs overlay loop; do
    modprobe $mod 2>/dev/null
done
sleep 3

# ── 3. Parse cmdline ─────────────────────────────────────────────────────────
FROM_PATH=""
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        from=*) FROM_PATH="${arg#from=}" ;;
    esac
done

# ── 4. Cari Media (Metode Non-Awk) ───────────────────────────────────────────
p "mencari media..."
porteux_DIR=""
mkdir -p /mnt/scan

try_mount() {
    dev="$1"; fs="$2"
    [ -b "$dev" ] || return 1
    p "  mencoba $dev ($fs)..."
    mount -t "$fs" -o ro "$dev" /mnt/scan 2>/dev/null || return 1
    
    # Cek folder porteux
    if [ -d "/mnt/scan/porteux/base" ]; then
        porteux_DIR="/mnt/scan/porteux"
        return 0
    elif [ -n "$FROM_PATH" ] && [ -d "/mnt/scan${FROM_PATH}/base" ]; then
        porteux_DIR="/mnt/scan${FROM_PATH}"
        return 0
    fi
    
    umount /mnt/scan 2>/dev/null
    return 1
}

scan_all() {
    # 1. Cek spesifik sr* (CD-ROM QEMU)
    for sr in /dev/sr*; do
        [ -b "$sr" ] && try_mount "$sr" "iso9660" && return 0
    done

    # 2. Cek semua di /proc/partitions (Disk/USB)
    while read major minor blocks name; do
        case "$name" in
            ""|name|loop*|ram*|zram*) continue ;;
        esac
        
        for fs in vfat ext4 ntfs iso9660; do
            try_mount "/dev/$name" "$fs" && return 0
        done
    done < /proc/partitions
    
    return 1
}

if ! scan_all; then
    p "GAGAL: Media tidak ditemukan."
    die_shell
fi

p "Media ditemukan di: $porteux_DIR"

# ── 5. Setup OverlayFS ───────────────────────────────────────────────────────
p "assembling modules..."
mkdir -p /mnt/xzm /mnt/up /mnt/wk /mnt/newroot
LOWER=""
IDX=0

for xzm in "$porteux_DIR/base/"*.xzm; do
    [ -f "$xzm" ] || continue
    mp="/mnt/xzm/$IDX"
    mkdir -p "$mp"
    if mount -t squashfs -o loop,ro "$xzm" "$mp" 2>/dev/null; then
        LOWER="${LOWER:+$LOWER:}$mp"
        IDX=$((IDX+1))
    fi
done

mount -t tmpfs tmpfs /mnt/up
mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=/mnt/up,workdir=/mnt/wk" /mnt/newroot || die_shell

# ── 6. Transisi ke GoboLinux ─────────────────────────────────────────────────
p "pindah ke newroot..."
mount --move /dev  /mnt/newroot/dev
mount --move /proc /mnt/newroot/proc
mount --move /sys  /mnt/newroot/sys

# Pastikan init ada
INIT="/sbin/init"
[ -x "/mnt/newroot/System/Links/Executables/init" ] && INIT="/System/Links/Executables/init"

exec switch_root /mnt/newroot "$INIT"

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

    # Install BusyBox dari porteux initrd (lebih lengkap dari GoboLinux)
    # porteux BusyBox: statik, semua applet tersedia (mount, mknod, switch_root, dll)
    extract_busybox_from_PORTEUX_INITRD

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
