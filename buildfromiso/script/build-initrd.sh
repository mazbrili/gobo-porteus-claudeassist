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
    # --- TAMBAHAN LOGIKA DEKOMPRESI MODUL ---
    log "  Memeriksa kompresi modul kernel (.zst)..."
    local kver_path
    kver_path=$(find "$INITRD_DIR" -path "*/lib/modules/*" -type d -maxdepth 1 | head -1)
    
    if [ -d "$kver_path" ]; then
        local kver; kver=$(basename "$kver_path")
        info "  Dekompresi modul untuk kernel: $kver"
        
        # Cari file .zst, dekompresi, lalu hapus aslinya
        if command -v zstd &>/dev/null; then
            find "$kver_path" -name "*.ko.zst" -exec zstd -d --rm {} \; 2>/dev/null || true
            info "  Dekompresi selesai (.ko.zst -> .ko)"
            
            # UPDATE modules.dep
            # Ini sangat penting agar modprobe tidak mencari file .zst yang sudah hilang
            if command -v depmod &>/dev/null; then
                info "  Memperbarui modules.dep..."
                depmod -b "$INITRD_DIR" "$kver"
            else
                warn "  depmod tidak ditemukan di host, modules.dep mungkin tidak akurat!"
            fi
        else
            warn "  zstd tidak ditemukan di host! Modul tetap dalam format .zst (berisiko gagal boot)."
        fi
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

    cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# /init — GoboLinux 017 Live, Porteus-style
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
PORTEUS_DIR=""
mkdir -p /mnt/scan

try_mount() {
    dev="$1"; fs="$2"
    [ -b "$dev" ] || return 1
    p "  mencoba $dev ($fs)..."
    mount -t "$fs" -o ro "$dev" /mnt/scan 2>/dev/null || return 1
    
    # Cek folder porteus
    if [ -d "/mnt/scan/porteus/base" ]; then
        PORTEUS_DIR="/mnt/scan/porteus"
        return 0
    elif [ -n "$FROM_PATH" ] && [ -d "/mnt/scan${FROM_PATH}/base" ]; then
        PORTEUS_DIR="/mnt/scan${FROM_PATH}"
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

p "Media ditemukan di: $PORTEUS_DIR"

# ── 5. Setup OverlayFS ───────────────────────────────────────────────────────
p "assembling modules..."
mkdir -p /mnt/xzm /mnt/up /mnt/wk /mnt/newroot
LOWER=""
IDX=0

for xzm in "$PORTEUS_DIR/base/"*.xzm; do
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

    # Porteus pakai xz --check=crc32 (bukan zstd)
    # Format ini kompatibel dengan syslinux dan semua bootloader
    local COMP_EXT="xz"
    local COMP_CMD="xz -9 --check=crc32"
    info "Kompresi: xz (Porteus-style)"

    # Pack main cpio ke file sementara (JANGAN pakai $() untuk binary data)
    local MAIN_COMP="$WORK/main.cpio.$COMP_EXT"
    log "  Pack main cpio..."
    ( cd "$INITRD_DIR" && find . | sort | cpio -o -H newc --quiet 2>/dev/null )         | $COMP_CMD > "$MAIN_COMP"
    info "  main cpio: $(du -sh "$MAIN_COMP" | cut -f1)"

    # Format Porteus: cpio xz saja (tanpa early_cpio di depan)
    # Porteus tidak pakai early_cpio/microcode — microcode diurus oleh kernel/firmware
    # Jika ingin menyertakan microcode GoboLinux: aktifkan blok di bawah
    cp "$MAIN_COMP" "$OUTPUT_INITRD"
    info "Format: Porteus-style (xz cpio, tanpa early_cpio)"

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

    # Bangun base dari GoboLinux 017 main/ (kernel modules, libs, dll)
    build_from_gobo017_main "$extract_dir"

    # Simpan early_cpio (microcode AMD/Intel)
    save_early_cpio "$extract_dir"

    # Install BusyBox dari Porteus initrd (lebih lengkap dari GoboLinux)
    # Porteus BusyBox: statik, semua applet tersedia (mount, mknod, switch_root, dll)
    extract_busybox_from_porteus_initrd

    # Tulis /init script Porteus-style
    write_init

    # Pack menjadi initrd.xz
    pack_initrd

    echo ""
    log "=== SELESAI ==="
    echo ""
    echo "initrd siap: $OUTPUT_INITRD"
    echo "Selanjutnya: sudo make iso  atau  sudo make usb DEV=/dev/sdX"
}

main "$@"
