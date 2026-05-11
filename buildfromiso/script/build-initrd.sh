#!/bin/bash
# build-initrd.sh
# ─────────────────────────────────────────────────────────────────────────────
# Membangun initramfs untuk GoboLinux 017 Live (Porteus-style)
#
# STRATEGI BARU (berdasarkan temuan):
#   GoboLinux 017 initramfs bisa diekstrak dengan unmkinitramfs dan berisi:
#     early/  — microcode AMD/Intel
#     main/   — filesystem lengkap termasuk:
#               Programs/Linux/6.12.16/lib/modules/6.12.16-Gobo/kernel/
#               bin/busybox, sbin/*, lib/*, dll
#
#   Kita GUNAKAN main/ dari initramfs GoboLinux 017 sebagai base,
#   lalu GANTI /init-nya dengan init kita yang mount .xzm Porteus-style.
#   BusyBox dan semua modul kernel sudah ada di dalamnya.
#
# Usage:
#   sudo bash build-initrd.sh \
#     --gobo017initrd /path/to/initramfs-gobo-orig \
#     --porteus-initrd /path/to/porteus/boot/syslinux/initrd.xz \
#     --output        /path/to/initrd.xz
#
# --porteus-initrd: initrd.xz dari ISO Porteus — sumber BusyBox statik.
#   Porteus memakai BusyBox statik dengan semua applet lengkap.
#   Jika tidak disediakan, script mencari di PORTEUS_INITRD env atau auto-detect.
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
PORTEUS_INITRD="${PORTEUS_INITRD:-}"  # initrd.xz Porteus untuk BusyBox
# Argumen lama tetap diterima tapi diabaikan (backward compat)
GOBO016_ISO=""
SLAX_ISO=""
GOBO017_ROOT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --gobo017initrd) GOBO017_INITRD="$2"; shift 2 ;;
        --output)        OUTPUT_INITRD="$2";  shift 2 ;;
        # Backward compat — diabaikan
        --porteus-initrd) PORTEUS_INITRD="$2"; shift 2 ;;
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
# TAHAP 3c: Ganti/lengkapi BusyBox dengan versi dari Porteus
# Porteus BusyBox dikompilasi statik dengan applet lengkap (tail, grep, tr, dll)
# GoboLinux mungkin tidak punya BusyBox atau versi dinamis yang tidak cocok
# ─────────────────────────────────────────────────────────────────────────────
install_busybox_from_porteus() {
    log "=== Install BusyBox dari Porteus ==="

    # Cari path BusyBox dari file yang ditulis build-gobo-live.sh
    local bb_path=""
    local path_file="$(dirname "$OUTPUT_INITRD")/../../.busybox-path"
    path_file="$(realpath "$path_file" 2>/dev/null || echo "$path_file")"

    if [ -f "$path_file" ]; then
        bb_path=$(cat "$path_file")
        info "Path dari .busybox-path: $bb_path"
    fi

    # Jika tidak ada di path_file, cari langsung dari WORK_DIR
    if [ -z "$bb_path" ] || [ ! -f "$bb_path" ]; then
        # Coba cari di /tmp/gobo-live-*/busybox-from-porteus
        bb_path=$(find /tmp -maxdepth 2 -name "busybox-from-porteus" 2>/dev/null | head -1 || true)
        [ -n "$bb_path" ] && info "BusyBox ditemukan via scan: $bb_path"
    fi

    if [ -z "$bb_path" ] || [ ! -f "$bb_path" ]; then
        warn "BusyBox dari Porteus tidak tersedia"
        warn "Pastikan PORTEUS_ISO disetel saat make build"
        info "Cek apakah /bin/busybox sudah ada di initramfs GoboLinux..."
        if [ -f "$INITRD_DIR/bin/busybox" ]; then
            info "  Ada: $(file -b "$INITRD_DIR/bin/busybox" | cut -c1-60)"
        else
            warn "  TIDAK ADA — boot mungkin gagal karena tidak ada shell/mount"
        fi
        return 0
    fi

    info "BusyBox Porteus: $bb_path"
    info "  Format : $(file -b "$bb_path" | cut -c1-60)"
    info "  Ukuran : $(du -sh "$bb_path" | cut -f1)"

    # Pastikan ini BusyBox statik (lebih reliable di initramfs)
    if file "$bb_path" | grep -qi "statically linked"; then
        info "  Statik : YA (ideal untuk initramfs)"
    else
        warn "  Statik : TIDAK — dynamic linked, mungkin butuh library"
    fi

    # Salin ke /bin/busybox di initramfs
    mkdir -p "$INITRD_DIR/bin"
    cp "$bb_path" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"
    info "  Disalin ke: $INITRD_DIR/bin/busybox"

    # Buat symlinks applet yang dibutuhkan /init
    # Porteus BusyBox punya semua ini
    local applets=(
        sh ash cat echo ls mkdir rm mv cp ln
        mount umount losetup mknod
        sleep true false test
        cat echo printf
        dmesg uname
        switch_root
        find xargs
        sort
    )
    local linked=0
    for app in "${applets[@]}"; do
        local dst="$INITRD_DIR/bin/$app"
        if [ ! -e "$dst" ]; then
            ln -sf busybox "$dst" 2>/dev/null && linked=$((linked+1)) || true
        fi
    done
    # Juga buat di /sbin untuk switch_root
    mkdir -p "$INITRD_DIR/sbin"
    for app in switch_root mknod mount umount; do
        [ -e "$INITRD_DIR/sbin/$app" ] ||             ln -sf ../bin/busybox "$INITRD_DIR/sbin/$app" 2>/dev/null || true
    done

    info "  $linked symlinks applet dibuat"
    log "BusyBox dari Porteus terpasang"
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
# TAHAP 2b: Ekstrak BusyBox dari initrd.xz Porteus
# Porteus initrd.xz berisi BusyBox statik yang dikompilasi dengan semua
# applet yang dibutuhkan (mount, mknod, switch_root, sleep, dll).
# Ini menggantikan BusyBox dari GoboLinux yang mungkin tidak ada.
# ─────────────────────────────────────────────────────────────────────────────
extract_busybox_from_porteus_initrd() {
    log "=== Ekstrak BusyBox dari Porteus initrd ==="

    # Resolve path initrd Porteus
    local porteus_initrd="$PORTEUS_INITRD"

    # Auto-detect: cari initrd.xz Porteus di lokasi standar output build
    if [ -z "$porteus_initrd" ]; then
        local output_syslinux
        output_syslinux="$(dirname "$OUTPUT_INITRD")"
        for candidate in             "$output_syslinux/porteus-initrd.xz"             "$output_syslinux/../../../boot/syslinux/initrd.xz.porteus"
        do
            [ -f "$candidate" ] && { porteus_initrd="$candidate"; break; }
        done
    fi

    if [ -z "$porteus_initrd" ] || [ ! -f "$porteus_initrd" ]; then
        warn "Porteus initrd tidak ditemukan — BusyBox tidak diinstall"
        warn "Gunakan: --porteus-initrd /path/to/porteus/initrd.xz"
        warn "Atau set: PORTEUS_INITRD=/path make initrd"
        return 0
    fi

    log "  Porteus initrd: $porteus_initrd"
    log "  Format: $(file -b "$porteus_initrd" | cut -c1-60)"
    log "  Ukuran: $(du -sh "$porteus_initrd" | cut -f1)"

    # Ekstrak ke direktori sementara
    local porteus_extract="$WORK/porteus-initrd-extract"
    mkdir -p "$porteus_extract"

    local fmt
    fmt=$(file -b "$porteus_initrd")

    log "  Mengekstrak Porteus initrd..."
    if echo "$fmt" | grep -qi "XZ"; then
        xzcat "$porteus_initrd" | cpio -id --quiet -D "$porteus_extract" 2>/dev/null || true
    elif echo "$fmt" | grep -qi "gzip"; then
        zcat "$porteus_initrd" | cpio -id --quiet -D "$porteus_extract" 2>/dev/null || true
    elif echo "$fmt" | grep -qi "Zstandard"; then
        zstdcat "$porteus_initrd" | cpio -id --quiet -D "$porteus_extract" 2>/dev/null || true
    else
        # Coba semua format
        xzcat   "$porteus_initrd" 2>/dev/null | cpio -id --quiet -D "$porteus_extract" 2>/dev/null ||         zcat    "$porteus_initrd" 2>/dev/null | cpio -id --quiet -D "$porteus_extract" 2>/dev/null ||         zstdcat "$porteus_initrd" 2>/dev/null | cpio -id --quiet -D "$porteus_extract" 2>/dev/null ||         { warn "Gagal mengekstrak Porteus initrd"; return 0; }
    fi

    log "  Isi Porteus initrd (top level):"
    ls "$porteus_extract/" 2>/dev/null | while read -r d; do info "    $d"; done

    # Cari binary busybox
    local bb_src=""
    for candidate in         "$porteus_extract/bin/busybox"         "$porteus_extract/usr/bin/busybox"         "$porteus_extract/busybox"
    do
        [ -f "$candidate" ] || continue
        local ftype; ftype=$(file -b "$candidate")
        if echo "$ftype" | grep -qi "ELF"; then
            bb_src="$candidate"
            info "  BusyBox ditemukan: ${candidate#$porteus_extract/}"
            info "    $(file -b "$candidate" | cut -c1-60)"
            info "    Ukuran: $(du -sh "$candidate" | cut -f1)"
            break
        fi
    done

    if [ -z "$bb_src" ]; then
        warn "  BusyBox tidak ditemukan dalam Porteus initrd"
        # Tampilkan isi bin/ untuk diagnosis
        log "  Isi bin/ Porteus initrd:"
        ls "$porteus_extract/bin/" 2>/dev/null | while read -r f; do info "    $f"; done
        return 0
    fi

    # Install BusyBox ke INITRD_DIR
    log "  Install BusyBox ke initramfs..."
    mkdir -p "$INITRD_DIR/bin" "$INITRD_DIR/sbin"
    cp "$bb_src" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"

    # Buat symlink applet dari busybox --list
    # Gunakan daftar hardcode yang paling penting (portable, tidak butuh busybox --list)
    local APPLETS_BIN="sh ash bash cat echo printf ls mkdir rm mv cp ln
        mount umount losetup mknod modprobe insmod lsmod
        sleep kill ps grep sed awk cut head find xargs sort
        blkid lsblk fdisk df du free dmesg uname date
        gunzip xzcat zcat zstdcat cpio tar gzip
        ifconfig ip route ping
        chroot switch_root pivot_root
        true false test expr read"

    local APPLETS_SBIN="switch_root pivot_root modprobe insmod blkid
        losetup udevd udevadm mdev"

    local count_bin=0 count_sbin=0
    for app in $APPLETS_BIN; do
        ln -sf busybox "$INITRD_DIR/bin/$app" 2>/dev/null && count_bin=$((count_bin+1)) || true
    done
    for app in $APPLETS_SBIN; do
        ln -sf ../bin/busybox "$INITRD_DIR/sbin/$app" 2>/dev/null && count_sbin=$((count_sbin+1)) || true
    done

    info "  Symlink: $count_bin di /bin/, $count_sbin di /sbin/"

    # Salin juga lib yang dibutuhkan BusyBox jika dynamic
    if echo "$(file -b "$bb_src")" | grep -qi "dynamically linked"; then
        warn "  BusyBox Porteus adalah dynamic linked — menyalin shared libraries..."
        ldd "$bb_src" 2>/dev/null | grep -o '/[^ ]*' | while read -r lib; do
            [ -f "$lib" ] || continue
            local libdir; libdir="$(dirname "$lib")"
            mkdir -p "$INITRD_DIR$libdir"
            cp "$lib" "$INITRD_DIR$libdir/" 2>/dev/null || true
            info "    lib: $lib"
        done
    else
        info "  BusyBox statik — tidak perlu shared libraries"
    fi

    log "  BusyBox dari Porteus berhasil diinstall"
    log "  Test: $("$INITRD_DIR/bin/busybox" echo "busybox OK" 2>/dev/null || echo "tidak bisa ditest di host")"
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

    cat > "$INITRD_DIR/init" << INIT_EOF
#!/bin/sh
# /init — GoboLinux 017 Live, Porteus-style
# Hanya pakai: sh built-in, mount, mknod, sleep, cat, echo, dmesg

export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/System/Links/Executables

p() { echo "[init] $*"; }

die_shell() {
    p "=== SHELL DARURAT ==="
    p "cmdline: $(cat /proc/cmdline 2>/dev/null)"
    p "sys/block: $(echo /sys/block/*)"
    p "dev: $(echo /dev/sd* /dev/sr* /dev/hd* /dev/vd* 2>/dev/null)"
    dmesg 2>/dev/null
    exec /bin/sh
}

# ── 1. Pseudo-filesystems ────────────────────────────────────────────────────
mount -t proc     proc  /proc  2>/dev/null
mount -t sysfs    sysfs /sys   2>/dev/null
mount -t devtmpfs dev   /dev   2>/dev/null || mount -t tmpfs tmpfs /dev 2>/dev/null
mkdir -p /dev/pts /tmp /run
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /tmp       2>/dev/null || true
mount -t tmpfs tmpfs /run       2>/dev/null || true
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null
[ -c /dev/null    ] || mknod -m 666 /dev/null    c 1 3 2>/dev/null
[ -c /dev/tty     ] || mknod -m 666 /dev/tty     c 5 0 2>/dev/null
p "kernel: $(uname -r 2>/dev/null)"

# ── 2. Device nodes dari /sys/block ──────────────────────────────────────────
make_nodes() {
    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        bn="${blk##*/}"
        case "$bn" in loop*|ram*|zram*|dm*) continue ;; esac
        [ -f "$blk/dev" ] || continue
        mm=$(cat "$blk/dev")
        [ -b "/dev/$bn" ] || mknod "/dev/$bn" b "${mm%%:*}" "${mm##*:}" 2>/dev/null
        p "  node: /dev/$bn"
        for part in "$blk/${bn}"[0-9] "$blk/${bn}"[0-9][0-9]                     "$blk/${bn}p"[0-9] "$blk/${bn}p"[0-9][0-9]; do
            [ -d "$part" ] || continue
            pn="${part##*/}"
            [ -f "$part/dev" ] || continue
            pm=$(cat "$part/dev")
            [ -b "/dev/$pn" ] || mknod "/dev/$pn" b "${pm%%:*}" "${pm##*:}" 2>/dev/null
        done
    done
    for sr in /sys/class/block/sr* /sys/class/block/scd*; do
        [ -d "$sr" ] || continue
        sn="${sr##*/}"
        [ -f "$sr/dev" ] || continue
        sm=$(cat "$sr/dev")
        [ -b "/dev/$sn" ] || mknod "/dev/$sn" b "${sm%%:*}" "${sm##*:}" 2>/dev/null
        p "  node: /dev/$sn (optical)"
    done
}
p "device nodes..."
make_nodes

# ── 3. Tunggu storage ────────────────────────────────────────────────────────
p "tunggu storage..."
i=0
while [ $i -lt 30 ]; do
    found=""
    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        n="${blk##*/}"
        case "$n" in sd*|hd*|vd*|xvd*|nvme*|mmcblk*|sr*|scd*) found="$n"; break ;; esac
    done
    if [ -n "$found" ]; then
        p "  storage: $found (${i}s)"
        make_nodes
        break
    fi
    i=$((i+1))
    p "  ${i}s /sys/block: $(echo /sys/block/*)"
    sleep 1
    if [ $i -eq 5 ]; then
        p "--- dmesg ---"
        dmesg 2>/dev/null
        p "--- end dmesg ---"
    fi
done

# ── 4. Parse cmdline ─────────────────────────────────────────────────────────
FROM_PATH="" CHANGES_PATH="" COPY2RAM=0 NOMAGIC=0 LOAD_LIST=""
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        from=*)    FROM_PATH="${arg#from=}"            ;;
        changes=*) CHANGES_PATH="${arg#changes=}"      ;;
        copy2ram)  COPY2RAM=1                          ;;
        nomagic)   NOMAGIC=1                           ;;
        load=*)    LOAD_LIST="$LOAD_LIST ${arg#load=}" ;;
    esac
done

# ── 5. Cari /porteus/base/*.xzm ──────────────────────────────────────────────
p "cari media..."
PORTEUS_DIR="" MEDIA_MNT=""
mkdir -p /mnt/scan

try_mount() {
    umount /mnt/scan 2>/dev/null || true
    mount -t "$2" -o ro "$1" /mnt/scan 2>/dev/null || return 1
    if [ -d /mnt/scan/porteus/base ]; then
        for xzm in /mnt/scan/porteus/base/*.xzm; do
            [ -f "$xzm" ] && return 0
        done
    fi
    umount /mnt/scan 2>/dev/null || true
    return 1
}

scan_all() {
    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        bn="${blk##*/}"
        case "$bn" in loop*|ram*|zram*|dm*) continue ;; esac
        for dev in "/dev/$bn" "/dev/${bn}1" "/dev/${bn}2"                    "/dev/${bn}p1" "/dev/${bn}p2"; do
            [ -b "$dev" ] || continue
            p "  try: $dev"
            for fs in iso9660 udf vfat exfat ext4 ext3 ext2; do
                if try_mount "$dev" "$fs"; then
                    PORTEUS_DIR=/mnt/scan/porteus
                    MEDIA_MNT=/mnt/scan
                    p "  FOUND: $dev ($fs)"
                    return 0
                fi
            done
        done
    done
    return 1
}

if [ -n "$FROM_PATH" ]; then
    case "$FROM_PATH" in
        /dev/*) for fs in iso9660 udf vfat ext4 ext3 ext2; do
                    try_mount "$FROM_PATH" "$fs" && {
                        PORTEUS_DIR=/mnt/scan/porteus; MEDIA_MNT=/mnt/scan; break; }
                done ;;
        *) [ -d "$FROM_PATH/porteus/base" ] && PORTEUS_DIR="$FROM_PATH/porteus" ;;
    esac
fi
[ -z "$PORTEUS_DIR" ] && { scan_all || true; }

if [ -z "$PORTEUS_DIR" ]; then
    p "GAGAL menemukan porteus/ — sys/block: $(echo /sys/block/*)"
    dmesg 2>/dev/null
    die_shell
fi
p "media: $PORTEUS_DIR"

# ── 6. Copy to RAM ───────────────────────────────────────────────────────────
if [ "$COPY2RAM" = "1" ]; then
    p "copy2ram..."
    mkdir -p /mnt/ram
    mount -t tmpfs tmpfs /mnt/ram
    cp -a "$PORTEUS_DIR/." /mnt/ram/
    sync
    [ -n "$MEDIA_MNT" ] && umount "$MEDIA_MNT" 2>/dev/null || true
    PORTEUS_DIR=/mnt/ram
fi

# ── 7. Mount .xzm -> OverlayFS ───────────────────────────────────────────────
p "mount .xzm..."
mkdir -p /mnt/xzm /mnt/up /mnt/wk /mnt/new
LOWER="" IDX=0
mount_xzm() {
    mp="/mnt/xzm/$IDX"
    mkdir -p "$mp"
    if mount -t squashfs -o loop,ro "$1" "$mp" 2>/dev/null; then
        p "  +${1##*/}"
        LOWER="${LOWER:+$LOWER:}$mp"
        IDX=$((IDX+1))
        return 0
    fi
    p "  GAGAL: ${1##*/}"
}
for xzm in "$PORTEUS_DIR/base/"*.xzm; do
    [ -f "$xzm" ] && mount_xzm "$xzm"
done
for xzm in "$PORTEUS_DIR/modules/"*.xzm; do
    [ -f "$xzm" ] && mount_xzm "$xzm"
done
for name in $LOAD_LIST; do
    for xf in "$PORTEUS_DIR/optional/$name" "$PORTEUS_DIR/optional/${name}.xzm"; do
        [ -f "$xf" ] && mount_xzm "$xf" && break
    done
done

[ -n "$LOWER" ] || { p "tidak ada .xzm ter-mount"; die_shell; }
p "  $IDX modul di-mount"

if [ "$NOMAGIC" = "1" ] || [ -z "$CHANGES_PATH" ]; then
    mount -t tmpfs tmpfs /mnt/up; UP=/mnt/up
else
    mkdir -p "$CHANGES_PATH"; UP="$CHANGES_PATH"
fi
mkdir -p /mnt/wk
mount -t overlay overlay     -o "lowerdir=$LOWER,upperdir=$UP,workdir=/mnt/wk"     /mnt/new || { p "OverlayFS gagal"; die_shell; }
p "overlay OK"

# ── Eksekusi InitializeCurrent: buat symlink Current di /Programs ─────────────
# Script ini dihasilkan oleh generate_current_script() di build-gobo-live.sh
# dan berisi: ln -snf "<ver>" "/Programs/<App>/Current" untuk setiap program
INIT_CURRENT="/mnt/new/System/Settings/BootScripts/InitializeCurrent"
if [ -x "$INIT_CURRENT" ]; then
    p "Menjalankan InitializeCurrent..."
    # Jalankan dalam konteks /mnt/new agar path /Programs/* benar
    chroot /mnt/new /System/Settings/BootScripts/InitializeCurrent 2>/dev/null ||     sh "$INIT_CURRENT" 2>/dev/null || true
    p "  InitializeCurrent selesai"
else
    p "  InitializeCurrent tidak ada — Current akan dibuat manual"
fi

# ── 8. GoboLinux System/Links ────────────────────────────────────────────────
p "System/Links..."
if [ -d /mnt/new/Programs ]; then
    for prog in /mnt/new/Programs/*/; do
        [ -d "$prog" ] || continue
        if [ -L "${prog}Current" ]; then
            ver=$(readlink -f "${prog}Current" 2>/dev/null)
        else
            ver=""
            for vd in "$prog"/*/; do
                [ -d "$vd" ] && ver="$vd"
            done
            ver="${ver%/}"
        fi
        [ -d "$ver" ] || continue
        [ -e "${prog}Current" ] || ln -snf "$ver" "${prog}Current" 2>/dev/null
        mkdir -p /mnt/new/System/Links/Executables /mnt/new/System/Links/Libraries
        for sub in bin sbin; do
            [ -d "$ver/$sub" ] || continue
            for f in "$ver/$sub/"*; do
                [ -e "$f" ] || continue
                dst="/mnt/new/System/Links/Executables/${f##*/}"
                [ -e "$dst" ] || ln -s "$f" "$dst" 2>/dev/null
            done
        done
        for sub in lib lib64; do
            [ -d "$ver/$sub" ] || continue
            for f in "$ver/$sub/"*; do
                [ -e "$f" ] || continue
                dst="/mnt/new/System/Links/Libraries/${f##*/}"
                [ -e "$dst" ] || ln -s "$f" "$dst" 2>/dev/null
            done
        done
    done
fi
for pair in "bin:/System/Links/Executables" "sbin:/System/Links/Executables"             "lib:/System/Links/Libraries"   "lib64:/System/Links/Libraries"; do
    lnk="${pair%%:*}"; tgt="${pair#*:}"
    [ -e "/mnt/new/$lnk" ] || ln -s "$tgt" "/mnt/new/$lnk" 2>/dev/null || true
done
[ -e /mnt/new/usr ] || ln -s "/" /mnt/new/usr 2>/dev/null || true

# ── 9. Setup /dev di newroot ─────────────────────────────────────────────────
p "setup newroot..."
mkdir -p /mnt/new/dev /mnt/new/proc /mnt/new/sys /mnt/new/run /mnt/new/tmp
mount --bind /dev /mnt/new/dev 2>/dev/null ||     mount -t devtmpfs devtmpfs /mnt/new/dev 2>/dev/null || true
mkdir -p /mnt/new/dev/pts
mount --bind /dev/pts /mnt/new/dev/pts 2>/dev/null ||     mount -t devpts devpts /mnt/new/dev/pts 2>/dev/null || true
[ -c /mnt/new/dev/console ] || mknod /mnt/new/dev/console c 5 1 2>/dev/null
[ -c /mnt/new/dev/tty     ] || mknod /mnt/new/dev/tty     c 5 0 2>/dev/null
[ -c /mnt/new/dev/null    ] || mknod /mnt/new/dev/null    c 1 3 2>/dev/null
chmod 600 /mnt/new/dev/console 2>/dev/null || true
chmod 666 /mnt/new/dev/tty    2>/dev/null || true
chmod 666 /mnt/new/dev/null   2>/dev/null || true
mount -t proc  proc  /mnt/new/proc 2>/dev/null || true
mount -t sysfs sysfs /mnt/new/sys  2>/dev/null || true
mount -t tmpfs tmpfs /mnt/new/run  2>/dev/null || true
mount -t tmpfs tmpfs /mnt/new/tmp  2>/dev/null || true

# ── 10. Cari dan exec init GoboLinux ─────────────────────────────────────────
p "cari init..."
p "  newroot: $(echo /mnt/new/*)"
INIT=""
for c in /mnt/new/sbin/init /mnt/new/System/Links/Executables/init           /mnt/new/bin/init  /mnt/new/Programs/Sysvinit/Current/sbin/init           /mnt/new/Programs/Systemd/Current/lib/systemd/systemd; do
    if [ -x "$c" ]; then
        INIT="${c#/mnt/new}"
        p "  init: $INIT"
        break
    fi
done
if [ -z "$INIT" ]; then
    p "  init tidak ditemukan, Programs/:"
    for d in /mnt/new/Programs/*/; do
        [ -d "$d" ] && p "    ${d##/mnt/new/}"
    done
    INIT=/bin/sh
fi
p "exec switch_root -> $INIT"
exec switch_root /mnt/new "$INIT"
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

    # Pilih kompresi
    local COMP_EXT COMP_CMD
    if command -v zstd &>/dev/null; then
        COMP_EXT="zst"
        COMP_CMD="zstd -9 --long"
        info "Kompresi: zstd"
    else
        COMP_EXT="xz"
        COMP_CMD="xz -9 --check=crc32"
        info "Kompresi: xz"
    fi

    # Pack main cpio ke file sementara (JANGAN pakai $() untuk binary data)
    local MAIN_COMP="$WORK/main.cpio.$COMP_EXT"
    log "  Pack main cpio..."
    ( cd "$INITRD_DIR" && find . | sort | cpio -o -H newc --quiet 2>/dev/null )         | $COMP_CMD > "$MAIN_COMP"
    info "  main cpio: $(du -sh "$MAIN_COMP" | cut -f1)"

    # Gabung: early (uncompressed) + main (compressed)
    if [ -s "$WORK/early.cpio" ]; then
        cat "$WORK/early.cpio" "$MAIN_COMP" > "$OUTPUT_INITRD"
        info "Format: early($(du -sh "$WORK/early.cpio" | cut -f1)) + main"
    else
        cp "$MAIN_COMP" "$OUTPUT_INITRD"
        info "Format: main only"
    fi

    log "  Output: $OUTPUT_INITRD ($(du -sh "$OUTPUT_INITRD" | cut -f1))"

    # Verifikasi — gunakan main.cpio langsung (bukan output gabungan)
    # karena output gabungan punya early uncompressed di depan
    log "  Verifikasi isi main cpio:"
    local VERIFY_DIR="$WORK/verify"
    rm -rf "$VERIFY_DIR" && mkdir -p "$VERIFY_DIR"

    if [ "$COMP_EXT" = "zst" ]; then
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
    [ -n "$SLAX_ISO"        ] && warn "  --slax diabaikan (BusyBox dari Porteus initrd)"
    [ -n "$PORTEUS_INITRD"  ] && log  "  Porteus initrd  : $PORTEUS_INITRD"
    [ -n "$GOBO016_ISO"     ] && warn "  --gobo016 diabaikan"
    [ -n "$GOBO017_ROOT"    ] && warn "  --gobo017root diabaikan (modules dari initramfs)"
    echo ""

    local initrd_file
    initrd_file=$(find_gobo017_initrd)

    local extract_dir
    extract_dir=$(extract_gobo017_initrd "$initrd_file")

    build_from_gobo017_main "$extract_dir"
    install_busybox_from_porteus
    save_early_cpio "$extract_dir"

    # Tahap 2b: Install BusyBox dari Porteus initrd
    # (GoboLinux 017 initramfs tidak selalu punya BusyBox yang kompatibel)
    extract_busybox_from_porteus_initrd

    write_init
    pack_initrd

    echo ""
    log "=== SELESAI ==="
    echo ""
    echo "initrd siap: $OUTPUT_INITRD"
    echo "Selanjutnya: sudo make iso  atau  sudo make usb DEV=/dev/sdX"
}

main "$@"
