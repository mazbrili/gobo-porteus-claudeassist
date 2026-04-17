#!/bin/bash
# build-initrd.sh
# ─────────────────────────────────────────────────────────────────────────────
# Membangun initramfs untuk GoboLinux 017 Live (Porteus-style)
# dengan mengambil inspirasi dari dua sumber:
#
#   1. GoboLinux 016 initrd  — formatnya CramFS, berisi:
#        - BusyBox statik
#        - InitRDScripts (startGoboLinux, dll)
#        - Mini GoboLinux environment (Programs/Bash, Scripts, dll)
#      Script startGoboLinux-nya yang kita pelajari strukturnya,
#      lalu kita tulis ulang untuk mendukung .xzm Porteus-style.
#
#   2. Slax initramfs  — berisi hanya satu binary: busybox statik
#      (dikompilasi terhadap uClibc/musl, sangat kecil ~1MB)
#      Ini yang kita pakai sebagai /bin/busybox di initrd baru kita.
#
# HASIL:
#   initrd.xz = cpio.xz berisi:
#     /bin/busybox          ← dari Slax ISO
#     /bin/<applet symlinks>
#     /init                 ← script terinspirasi GoboLinux 016 startGoboLinux
#                             + diextend untuk mount .xzm Porteus-style
#     /etc/             skeleton minimal
#     /dev/             device nodes
#     /mnt/             mount points
#
# Penggunaan:
#   sudo bash build-initrd.sh \
#       --gobo016  GoboLinux-016.01-x86_64.iso \
#       --slax     slax-*.iso \
#       --gobo017root /path/to/gobo017-unsquashed \
#       --output   /path/to/output/initrd.xz
#
# Jika --gobo016 tidak ada, script akan mengekstrak BusyBox dari --slax saja
# dan menulis /init dari nol (terinspirasi logika GoboLinux 016).
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Parse argumen ─────────────────────────────────────────────────────────────
GOBO016_ISO=""
SLAX_ISO=""
GOBO017_ROOT=""
OUTPUT_INITRD=""

while [ $# -gt 0 ]; do
    case "$1" in
        --gobo016)     GOBO016_ISO="$2";   shift 2 ;;
        --slax)        SLAX_ISO="$2";      shift 2 ;;
        --gobo017root) GOBO017_ROOT="$2";  shift 2 ;;
        --output)      OUTPUT_INITRD="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,40p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) echo "Argumen tidak dikenal: $1"; exit 1 ;;
    esac
done

[ -n "$OUTPUT_INITRD" ] || { echo "ERROR: --output wajib"; exit 1; }
[ "$(id -u)" = "0" ]    || { echo "ERROR: harus root (sudo)"; exit 1; }

WORK="$(mktemp -d /tmp/gobo-initrd-XXXXXX)"
trap 'cleanup' EXIT

cleanup() {
    # Umount semua yang masih ter-mount di WORK
    for mnt in "$WORK"/mnt-*; do
        umount "$mnt" 2>/dev/null || true
    done
    rm -rf "$WORK"
}

G='\033[0;32m' Y='\033[1;33m' R='\033[0;31m' C='\033[0;36m' N='\033[0m'
log()  { echo -e "${G}[$(date +%H:%M:%S)]${N} $*"; }
info() { echo -e "${C}  ↳${N} $*"; }
warn() { echo -e "${Y}[WARN]${N} $*"; }
die()  { echo -e "${R}[ERROR]${N} $*" >&2; exit 1; }

INITRD_DIR="$WORK/initrd"

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 1: Cari BusyBox dari Slax ISO
# Slax menyimpan busybox statik langsung di dalam initramfs-nya
# Format: cpio.xz (Slax 9+) atau cpio.gz (Slax lama)
# ─────────────────────────────────────────────────────────────────────────────
extract_busybox_from_slax() {
    log "Mengekstrak BusyBox dari Slax..."
    [ -f "$SLAX_ISO" ] || die "Slax ISO tidak ditemukan: $SLAX_ISO"

    local slax_mnt="$WORK/mnt-slax"
    mkdir -p "$slax_mnt"
    mount -o loop,ro "$SLAX_ISO" "$slax_mnt"
    info "Slax ISO di-mount: $slax_mnt"

    # Tampilkan isi ISO Slax
    info "Isi Slax ISO:"
    find "$slax_mnt" -maxdepth 3 | sort | while read -r f; do
        [ -d "$f" ] && continue
        local sz; sz=$(du -sh "$f" 2>/dev/null | cut -f1)
        echo "    $sz  ${f#$slax_mnt/}"
    done

    # Cari initramfs Slax
    # Slax 9+: /slax/boot/initrfs.img  atau  /boot/initrd.img
    local slax_initrd=""
    for candidate in \
        "$slax_mnt/slax/boot/initrfs.img" \
        "$slax_mnt/slax/boot/initrd.img" \
        "$slax_mnt/boot/initrd.img" \
        "$slax_mnt/boot/initramfs.img" \
        "$slax_mnt/boot/initrfs.img"
    do
        [ -f "$candidate" ] && { slax_initrd="$candidate"; break; }
    done

    # Fallback: cari file cpio apapun
    if [ -z "$slax_initrd" ]; then
        slax_initrd=$(find "$slax_mnt" -not -type d | while read -r f; do
            file -b "$f" | grep -qi "cpio\|gzip\|XZ\|Zstandard" && echo "$f" && break
        done | head -1)
    fi

    [ -n "$slax_initrd" ] || die "Initramfs Slax tidak ditemukan dalam ISO"
    info "Initramfs Slax: ${slax_initrd#$slax_mnt/}"
    info "Format: $(file -b "$slax_initrd" | cut -c1-60)"

    # Ekstrak initramfs Slax ke tmp dir
    local slax_initrd_dir="$WORK/slax-initrd"
    mkdir -p "$slax_initrd_dir"
    cd "$slax_initrd_dir"

    local fmt; fmt=$(file -b "$slax_initrd")
    if echo "$fmt" | grep -qi "XZ"; then
        xzcat "$slax_initrd" | cpio -id --quiet 2>/dev/null
    elif echo "$fmt" | grep -qi "gzip"; then
        zcat "$slax_initrd" | cpio -id --quiet 2>/dev/null
    elif echo "$fmt" | grep -qi "Zstandard"; then
        zstdcat "$slax_initrd" | cpio -id --quiet 2>/dev/null
    else
        # Coba semua
        xzcat   "$slax_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null || \
        zcat    "$slax_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null || \
        zstdcat "$slax_initrd" 2>/dev/null | cpio -id --quiet 2>/dev/null || \
        die "Tidak bisa mengekstrak initramfs Slax"
    fi
    cd - >/dev/null

    info "Isi initramfs Slax:"
    find "$slax_initrd_dir" -not -type d | head -20 | while read -r f; do
        echo "    ${f#$slax_initrd_dir/}"
    done

    # Cari binary busybox
    local bb=""
    for candidate in \
        "$slax_initrd_dir/bin/busybox" \
        "$slax_initrd_dir/busybox" \
        "$slax_initrd_dir/usr/bin/busybox"
    do
        [ -f "$candidate" ] && { bb="$candidate"; break; }
    done

    # Fallback: cari binary ELF statik apapun yang namanya busybox
    if [ -z "$bb" ]; then
        bb=$(find "$slax_initrd_dir" -name "busybox" 2>/dev/null | head -1)
    fi

    [ -n "$bb" ] || die "BusyBox tidak ditemukan dalam initramfs Slax"

    info "BusyBox ditemukan: ${bb#$slax_initrd_dir/}"
    info "Format: $(file -b "$bb" | cut -c1-60)"
    info "Ukuran: $(du -sh "$bb" | cut -f1)"

    # Salin ke WORK untuk digunakan
    cp "$bb" "$WORK/busybox"
    chmod +x "$WORK/busybox"

    umount "$slax_mnt"
    log "BusyBox dari Slax berhasil diekstrak"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 2: Ambil struktur init dari GoboLinux 016 initrd (CramFS)
# Format: mkfs.cramfs -> perlu mount sebagai loop dengan filesystem cramfs
# ─────────────────────────────────────────────────────────────────────────────
extract_gobo016_initrd_structure() {
    log "Membaca struktur GoboLinux 016 initrd..."
    [ -f "$GOBO016_ISO" ] || { warn "GoboLinux 016 ISO tidak ada: $GOBO016_ISO"; return 0; }

    local gobo16_mnt="$WORK/mnt-gobo016"
    local cramfs_mnt="$WORK/mnt-cramfs"
    mkdir -p "$gobo16_mnt" "$cramfs_mnt"

    mount -o loop,ro "$GOBO016_ISO" "$gobo16_mnt"
    info "GoboLinux 016 ISO di-mount"

    # Cari initrd di ISO GoboLinux 016
    # Format: isolinux/initrd (CramFS)
    local initrd016=""
    for candidate in \
        "$gobo16_mnt/isolinux/initrd" \
        "$gobo16_mnt/boot/isolinux/initrd" \
        "$gobo16_mnt/isolinux/initrd.img"
    do
        [ -f "$candidate" ] && { initrd016="$candidate"; break; }
    done

    if [ -z "$initrd016" ]; then
        # Scan: cari file CramFS
        initrd016=$(find "$gobo16_mnt" -not -type d | while read -r f; do
            file -b "$f" | grep -qi "CramFS\|Linux.*cramfs" && echo "$f" && break
        done | head -1)
    fi

    if [ -z "$initrd016" ]; then
        warn "initrd GoboLinux 016 tidak ditemukan — akan tulis /init dari nol"
        umount "$gobo16_mnt"
        return 0
    fi

    info "GoboLinux 016 initrd: ${initrd016#$gobo16_mnt/}"
    info "Format: $(file -b "$initrd016")"

    # Mount CramFS
    if mount -t cramfs -o loop,ro "$initrd016" "$cramfs_mnt" 2>/dev/null; then
        info "CramFS ter-mount di $cramfs_mnt"
        info "Isi GoboLinux 016 initrd:"
        find "$cramfs_mnt" -not -type d | sort | head -40 | while read -r f; do
            echo "    ${f#$cramfs_mnt/}"
        done

        # Salin semua isi initrd 016 ke referensi
        cp -a "$cramfs_mnt/." "$WORK/gobo016-initrd/" 2>/dev/null || true
        umount "$cramfs_mnt"
    else
        # CramFS tidak bisa di-mount langsung, coba ekstrak sebagai cpio
        warn "Mount CramFS gagal — coba ekstrak alternatif"
        cd "$WORK" && mkdir -p gobo016-initrd
        zcat "$initrd016" 2>/dev/null | cpio -id --quiet -D gobo016-initrd 2>/dev/null || \
        xzcat "$initrd016" 2>/dev/null | cpio -id --quiet -D gobo016-initrd 2>/dev/null || true
        cd - >/dev/null
    fi

    umount "$gobo16_mnt"
    log "Referensi GoboLinux 016 initrd selesai"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 3: Bangun skeleton initramfs
# ─────────────────────────────────────────────────────────────────────────────
build_skeleton() {
    log "Membangun skeleton initramfs..."
    mkdir -p "$INITRD_DIR"

    # Hierarki direktori
    mkdir -p \
        "$INITRD_DIR/bin" \
        "$INITRD_DIR/sbin" \
        "$INITRD_DIR/lib" \
        "$INITRD_DIR/lib64" \
        "$INITRD_DIR/lib/modules" \
        "$INITRD_DIR/proc" \
        "$INITRD_DIR/sys" \
        "$INITRD_DIR/dev" \
        "$INITRD_DIR/dev/pts" \
        "$INITRD_DIR/tmp" \
        "$INITRD_DIR/run" \
        "$INITRD_DIR/mnt" \
        "$INITRD_DIR/mnt/media" \
        "$INITRD_DIR/mnt/xzm" \
        "$INITRD_DIR/mnt/overlay/upper" \
        "$INITRD_DIR/mnt/overlay/work" \
        "$INITRD_DIR/mnt/newroot" \
        "$INITRD_DIR/etc"

    # Device nodes minimal (GoboLinux 016 style)
    mknod -m 600 "$INITRD_DIR/dev/console" c 5 1
    mknod -m 666 "$INITRD_DIR/dev/null"    c 1 3
    mknod -m 666 "$INITRD_DIR/dev/zero"    c 1 5
    mknod -m 666 "$INITRD_DIR/dev/random"  c 1 8
    mknod -m 444 "$INITRD_DIR/dev/urandom" c 1 9
    mknod -m 666 "$INITRD_DIR/dev/tty"     c 5 0
    mknod -m 660 "$INITRD_DIR/dev/tty1"    c 4 1

    info "Skeleton dibuat"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 4: Install BusyBox + applet symlinks
# ─────────────────────────────────────────────────────────────────────────────
install_busybox() {
    log "Menginstal BusyBox..."
    local bb_src="$WORK/busybox"

    # Fallback jika Slax tidak disediakan
    if [ ! -f "$bb_src" ]; then
        warn "BusyBox dari Slax tidak ada, mencari alternatif..."
        # Coba dari host
        for candidate in /bin/busybox /usr/bin/busybox; do
            if [ -f "$candidate" ] && file "$candidate" | grep -qi "statically linked"; then
                cp "$candidate" "$bb_src"
                warn "Menggunakan BusyBox host: $candidate"
                break
            fi
        done
        [ -f "$bb_src" ] || die "BusyBox tidak tersedia. Sediakan Slax ISO via --slax"
    fi

    cp "$bb_src" "$INITRD_DIR/bin/busybox"
    chmod 755 "$INITRD_DIR/bin/busybox"

    # Daftar applet yang dibutuhkan untuk boot GoboLinux + mount .xzm
    # Diambil dari kebutuhan nyata startGoboLinux + xzm loader
    local applets=(
        # Shell & dasar
        sh ash echo printf cat tee
        # Filesystem & mount
        mount umount losetup
        switch_root pivot_root chroot
        mkdir rm mv cp ln ls
        # Device
        mknod
        # Modul kernel
        modprobe insmod lsmod
        # Proses
        sleep kill killall ps
        # Teks
        grep sed awk cut head tail sort uniq wc
        find xargs
        # Disk
        blkid lsblk fdisk
        # Kompresi (untuk debugging)
        gunzip xzcat zcat
        # Jaringan (opsional, untuk PXE)
        ifconfig ip
        # Lainnya
        true false test expr
        free df du
        dmesg
        uname
        date
    )

    for app in "${applets[@]}"; do
        ln -sf busybox "$INITRD_DIR/bin/$app" 2>/dev/null || true
    done

    # Beberapa tool juga di sbin
    for app in switch_root pivot_root modprobe insmod blkid losetup; do
        ln -sf ../bin/busybox "$INITRD_DIR/sbin/$app" 2>/dev/null || true
    done

    info "BusyBox $(file -b "$INITRD_DIR/bin/busybox" | cut -c1-50)"
    info "$(ls "$INITRD_DIR/bin/" | wc -l) file di /bin/"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 5: Tulis /init
# Terinspirasi dari GoboLinux 016 startGoboLinux + adaptasi Porteus-style .xzm
# ─────────────────────────────────────────────────────────────────────────────
write_init() {
    log "Menulis /init (terinspirasi GoboLinux 016 startGoboLinux)..."

    # Cek apakah ada script asli GoboLinux 016 sebagai referensi
    local gobo016_script="$WORK/gobo016-initrd"
    if [ -d "$gobo016_script" ]; then
        info "Referensi GoboLinux 016 initrd tersedia di: $gobo016_script"
        if [ -f "$gobo016_script/bin/startGoboLinux" ]; then
            info "Ditemukan: bin/startGoboLinux"
            info "5 baris pertama:"
            head -5 "$gobo016_script/bin/startGoboLinux" | while read -r l; do
                echo "    $l"
            done
        fi
    fi

    cat > "$INITRD_DIR/init" << 'INIT_EOF'
#!/bin/sh
# /init — GoboLinux 017 Live, Porteus-style
# BusyBox dari Slax + logika GoboLinux 016 startGoboLinux

export PATH=/bin:/sbin

print_status() { echo "GoboLinux: $*"; }
warn()         { echo "GoboLinux [WARN]: $*"; }

emergency_shell() {
    echo ""
    echo "=== EMERGENCY SHELL ==="
    echo "Diagnosis:"
    echo "--- /proc/mounts ---"
    cat /proc/mounts 2>/dev/null
    echo "--- /sys/block ---"
    ls /sys/block/ 2>/dev/null
    echo "--- /dev ---"
    ls /dev/ 2>/dev/null
    echo "--- kernel cmdline ---"
    cat /proc/cmdline 2>/dev/null
    echo "--- dmesg tail ---"
    dmesg 2>/dev/null | tail -20
    echo ""
    exec /bin/sh
}

# ── 1. Pseudo-filesystems ────────────────────────────────────────────────────
mount -t proc     proc  /proc
mount -t sysfs    sysfs /sys
mount -t devtmpfs dev   /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /run

print_status "Kernel: $(uname -r)"

# ── 2. Buat device nodes dari /sys/block secara langsung ────────────────────
# TIDAK mengandalkan mdev, udev, atau modprobe — semua dilakukan manual
# menggunakan informasi dari /sys yang selalu tersedia di kernel modern.
# Ini bekerja di Hyper-V, QEMU, VirtualBox, dan bare metal.

make_blk_nodes() {
    print_status "Membuat block device nodes dari /sys/block..."
    local made=0

    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        local name dev_file maj min

        name="$(basename "$blk")"
        dev_file="$blk/dev"
        [ -f "$dev_file" ] || continue

        # Baca major:minor langsung dari /sys/block/<name>/dev
        local majmin; majmin="$(cat "$dev_file")"
        maj="${majmin%%:*}"
        min="${majmin##*:}"

        local node="/dev/$name"
        [ -b "$node" ] || mknod "$node" b "$maj" "$min" 2>/dev/null || true
        [ -b "$node" ] && { print_status "  blk: $node ($maj:$min)"; made=$((made+1)); }

        # Buat juga node untuk setiap partisi
        for part in "$blk/${name}"[0-9] "$blk/${name}"[0-9][0-9] \
                    "$blk/${name}p"[0-9] "$blk/${name}p"[0-9][0-9]; do
            [ -d "$part" ] || continue
            local pname; pname="$(basename "$part")"
            local pdev_file="$part/dev"
            [ -f "$pdev_file" ] || continue
            local pmajmin; pmajmin="$(cat "$pdev_file")"
            local pmaj="${pmajmin%%:*}"
            local pmin="${pmajmin##*:}"
            local pnode="/dev/$pname"
            [ -b "$pnode" ] || mknod "$pnode" b "$pmaj" "$pmin" 2>/dev/null || true
            [ -b "$pnode" ] && { print_status "  part: $pnode ($pmaj:$pmin)"; made=$((made+1)); }
        done
    done

    print_status "Total: $made block nodes dibuat"
    return 0
}

# Buat juga char device untuk optical drives via /sys/class/block
make_chr_nodes() {
    for cd in /sys/class/block/sr* /sys/class/block/scd*; do
        [ -d "$cd" ] || continue
        local name; name="$(basename "$cd")"
        local dev_file="$cd/dev"
        [ -f "$dev_file" ] || continue
        local majmin; majmin="$(cat "$dev_file")"
        local maj="${majmin%%:*}" min="${majmin##*:}"
        local node="/dev/$name"
        [ -b "$node" ] || mknod "$node" b "$maj" "$min" 2>/dev/null || true
        print_status "  optical: $node ($maj:$min)"
    done
}

make_blk_nodes
make_chr_nodes

# ── 3. Tunggu device Hyper-V / virtio yang mungkin belum muncul di /sys ─────
# Hyper-V dan virtio-blk kadang butuh waktu setelah kernel init.
# Kita tunggu sampai /sys/block punya minimal 1 entry selain 'loop*' dan 'ram*'

wait_real_device() {
    local waited=0
    while [ $waited -lt 15 ]; do
        for blk in /sys/block/*; do
            local name; name="$(basename "$blk" 2>/dev/null)"
            case "$name" in
                loop*|ram*|zram*) continue ;;
                ""|"*") continue ;;
            esac
            [ -d "$blk" ] && return 0
        done
        sleep 1
        waited=$((waited+1))
        print_status "  Tunggu disk... ${waited}s"
        # Ulangi buat nodes — device baru mungkin muncul di /sys
        make_blk_nodes 2>/dev/null
    done
    return 1
}

wait_real_device || warn "Tidak ada disk terdeteksi setelah 15 detik"

# ── 4. Parse cmdline ─────────────────────────────────────────────────────────
FROM_PATH=""
CHANGES_PATH=""
COPY2RAM=0
NOMAGIC=0
LOAD_LIST=""

for p in $(cat /proc/cmdline); do
    case "$p" in
        from=*)    FROM_PATH="${p#from=}"       ;;
        changes=*) CHANGES_PATH="${p#changes=}" ;;
        copy2ram)  COPY2RAM=1                   ;;
        nomagic)   NOMAGIC=1                    ;;
        load=*)    LOAD_LIST="$LOAD_LIST ${p#load=}" ;;
    esac
done

# ── 5. Cari /porteus/base/*.xzm di semua block device ───────────────────────
print_status "Mencari media boot..."

PORTEUS_DIR=""
MEDIA_MNT=""
SCAN_MNT="/mnt/media/scan"
mkdir -p "$SCAN_MNT"

try_mount_find() {
    local dev="$1" fs="$2"
    # Umount dulu kalau masih ter-mount
    umount "$SCAN_MNT" 2>/dev/null || true
    mount -t "$fs" -o ro "$dev" "$SCAN_MNT" 2>/dev/null || return 1
    if [ -d "$SCAN_MNT/porteus/base" ] && \
       ls "$SCAN_MNT/porteus/base/"*.xzm >/dev/null 2>&1; then
        return 0
    fi
    umount "$SCAN_MNT" 2>/dev/null || true
    return 1
}

scan_all_devices() {
    # Kumpulkan semua block device dari /sys/block
    local devlist=""
    for blk in /sys/block/*; do
        local name; name="$(basename "$blk")"
        case "$name" in loop*|ram*|zram*) continue ;; esac
        [ -b "/dev/$name" ] || continue

        # Coba seluruh disk dulu (untuk ISO yang tidak berpartisi)
        devlist="$devlist /dev/$name"

        # Lalu partisi-partisinya
        for part in /dev/${name}[0-9] /dev/${name}[0-9][0-9] \
                    /dev/${name}p[0-9] /dev/${name}p[0-9][0-9]; do
            [ -b "$part" ] && devlist="$devlist $part"
        done
    done

    print_status "Scan devices: $devlist"

    for dev in $devlist; do
        [ -b "$dev" ] || continue
        print_status "  -> $dev"
        for fs in iso9660 udf vfat exfat ext4 ext3 ext2; do
            if try_mount_find "$dev" "$fs"; then
                PORTEUS_DIR="$SCAN_MNT/porteus"
                MEDIA_MNT="$SCAN_MNT"
                print_status "  FOUND: $dev ($fs) -> $PORTEUS_DIR"
                return 0
            fi
        done
    done
    return 1
}

if [ -n "$FROM_PATH" ]; then
    # from= bisa berupa device (from=/dev/sda1) atau path (from=/porteus)
    case "$FROM_PATH" in
        /dev/*)
            for fs in iso9660 vfat ext4 ext3 ext2 udf; do
                try_mount_find "$FROM_PATH" "$fs" && {
                    PORTEUS_DIR="$SCAN_MNT/porteus"
                    MEDIA_MNT="$SCAN_MNT"
                    break
                }
            done ;;
        *)
            [ -d "$FROM_PATH/porteus/base" ] && PORTEUS_DIR="$FROM_PATH/porteus" ;;
    esac
fi

[ -z "$PORTEUS_DIR" ] && scan_all_devices || true

if [ -z "$PORTEUS_DIR" ]; then
    warn "GAGAL menemukan /porteus/base/*.xzm"
    warn "/sys/block:"
    ls /sys/block/ 2>/dev/null
    warn "/dev:"
    ls /dev/ 2>/dev/null
    emergency_shell
fi

# ── 6. Copy to RAM (opsional) ────────────────────────────────────────────────
if [ "$COPY2RAM" = "1" ]; then
    print_status "copy2ram: menyalin ke RAM..."
    RAM_MNT="/mnt/ram"
    mkdir -p "$RAM_MNT"
    SZ=$(du -sk "$PORTEUS_DIR" 2>/dev/null | cut -f1)
    SZ_MB=$(( (SZ / 1024) + 128 ))
    mount -t tmpfs -o "size=${SZ_MB}m" tmpfs "$RAM_MNT"
    cp -a "$PORTEUS_DIR/." "$RAM_MNT/"
    sync
    [ -n "$MEDIA_MNT" ] && umount "$MEDIA_MNT" 2>/dev/null || true
    PORTEUS_DIR="$RAM_MNT"
    print_status "  Selesai (${SZ_MB}MB di RAM)"
fi

# ── 7. Mount .xzm → OverlayFS ────────────────────────────────────────────────
print_status "Mounting modul .xzm..."

XZM_BASE="/mnt/xzm"
UPPER="/mnt/overlay/upper"
WORK="/mnt/overlay/work"
NEWROOT="/mnt/newroot"
mkdir -p "$XZM_BASE" "$UPPER" "$WORK" "$NEWROOT"

LOWER=""
IDX=0

mount_xzm() {
    local f="$1"
    local mpt="$XZM_BASE/$IDX"
    mkdir -p "$mpt"
    if mount -t squashfs -o loop,ro "$f" "$mpt" 2>/dev/null; then
        print_status "  + $(basename "$f")"
        [ -z "$LOWER" ] && LOWER="$mpt" || LOWER="$LOWER:$mpt"
        IDX=$((IDX+1))
        return 0
    fi
    warn "  gagal: $(basename "$f")"
    return 1
}

for xzm in $(ls "$PORTEUS_DIR/base/"*.xzm 2>/dev/null | sort); do
    mount_xzm "$xzm"
done
for xzm in $(ls "$PORTEUS_DIR/modules/"*.xzm 2>/dev/null | sort); do
    mount_xzm "$xzm"
done
for name in $LOAD_LIST; do
    for f in "$PORTEUS_DIR/optional/$name" "$PORTEUS_DIR/optional/${name}.xzm"; do
        [ -f "$f" ] && mount_xzm "$f" && break
    done
done

[ -n "$LOWER" ] || { warn "Tidak ada .xzm berhasil di-mount"; emergency_shell; }

# Upper layer
if [ "$NOMAGIC" = "1" ] || [ -z "$CHANGES_PATH" ]; then
    mount -t tmpfs tmpfs "$UPPER"
    UPPER_DIR="$UPPER"
else
    mkdir -p "$CHANGES_PATH"
    UPPER_DIR="$CHANGES_PATH"
fi
mkdir -p "$UPPER_DIR" "$WORK"

mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=$UPPER_DIR,workdir=$WORK" \
    "$NEWROOT" || { warn "OverlayFS gagal"; emergency_shell; }

print_status "OverlayFS OK: $NEWROOT"

# ── 8. GoboLinux System/Links ────────────────────────────────────────────────
print_status "Membangun System/Links..."

[ -d "$NEWROOT/Programs" ] && \
find "$NEWROOT/Programs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | \
while read -r prog; do
    local name; name="$(basename "$prog")"
    local ver=""
    [ -L "$prog/Current" ] && ver="$(readlink -f "$prog/Current" 2>/dev/null)"
    [ -d "$ver" ] || ver="$(find "$prog" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
    [ -d "$ver" ] || continue
    [ -e "$prog/Current" ] || ln -snf "$ver" "$prog/Current" 2>/dev/null

    mkdir -p "$NEWROOT/System/Links/Executables" \
             "$NEWROOT/System/Links/Libraries"

    for sub in bin sbin; do
        [ -d "$ver/$sub" ] && find "$ver/$sub" -maxdepth 1 \( -type f -o -type l \) | \
        while read -r f; do
            local d="$NEWROOT/System/Links/Executables/$(basename "$f")"
            [ -e "$d" ] || ln -s "$f" "$d" 2>/dev/null
        done
    done
    for sub in lib lib64; do
        [ -d "$ver/$sub" ] && find "$ver/$sub" -maxdepth 1 \( -type f -o -type l \) | \
        while read -r f; do
            local d="$NEWROOT/System/Links/Libraries/$(basename "$f")"
            [ -e "$d" ] || ln -s "$f" "$d" 2>/dev/null
        done
    done
done

# FHS symlinks
for pair in "bin:/System/Links/Executables" "sbin:/System/Links/Executables" \
            "lib:/System/Links/Libraries"   "lib64:/System/Links/Libraries"; do
    lnk="${pair%%:*}"; tgt="${pair#*:}"
    [ -e "$NEWROOT/$lnk" ] || ln -s "$tgt" "$NEWROOT/$lnk" 2>/dev/null || true
done
[ -e "$NEWROOT/usr" ] || ln -s "/" "$NEWROOT/usr" 2>/dev/null || true

# ── 9. Handoff ───────────────────────────────────────────────────────────────
print_status "switch_root..."

for fsinfo in "proc:proc:/proc" "sysfs:sysfs:/sys" "devtmpfs:dev:/dev" "tmpfs:tmpfs:/run"; do
    t="${fsinfo%%:*}"; rest="${fsinfo#*:}"; src="${rest%%:*}"; dst="${rest#*:}"
    mount -t "$t" "$src" "$NEWROOT/$dst" 2>/dev/null || \
    mount --bind "/$dst" "$NEWROOT/$dst" 2>/dev/null || true
done
mkdir -p "$NEWROOT/dev/pts"
mount -t devpts devpts "$NEWROOT/dev/pts" 2>/dev/null || true

INIT=""
for c in "$NEWROOT/sbin/init" "$NEWROOT/System/Links/Executables/init" \
          "$NEWROOT/bin/init"  "$NEWROOT/Programs/Sysvinit/Current/sbin/init"; do
    [ -x "$c" ] && { INIT="${c#$NEWROOT}"; break; }
done
[ -n "$INIT" ] || INIT="/bin/sh"

print_status "exec: switch_root $NEWROOT $INIT"
exec switch_root "$NEWROOT" "$INIT"

warn "switch_root gagal"
emergency_shell
INIT_EOF

    chmod 755 "$INITRD_DIR/init"
    info "/init ditulis ($(wc -l < "$INITRD_DIR/init") baris)"
}

# ─────────────────────────────────────────────────────────────────────────────
# TAHAP 6: Pack menjadi initramfs cpio.xz
# ─────────────────────────────────────────────────────────────────────────────
pack_initrd() {
    log "Packing initramfs -> $OUTPUT_INITRD..."
    mkdir -p "$(dirname "$OUTPUT_INITRD")"

    cd "$INITRD_DIR"

    local COMP_CMD
    if command -v xz &>/dev/null; then
        # xz --check=crc32: format yang diterima kernel Linux dan GoboLinux 016/017
        COMP_CMD="xz -9 --check=crc32"
        info "Kompresi: xz (kernel-compatible)"
    else
        die "xz tidak ditemukan: apt install xz-utils"
    fi

    find . | sort | cpio -o -H newc --quiet | $COMP_CMD > "$OUTPUT_INITRD"
    cd - >/dev/null

    local size; size=$(du -sh "$OUTPUT_INITRD" | cut -f1)
    log "Initramfs selesai: $OUTPUT_INITRD ($size)"

    # Verifikasi: pastikan /init ada dalam cpio
    if xzcat "$OUTPUT_INITRD" 2>/dev/null | cpio -t --quiet 2>/dev/null | grep -q "^init$"; then
        info "Verifikasi: /init ditemukan dalam initramfs ✓"
    else
        warn "Verifikasi: /init mungkin tidak ada dalam initramfs!"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log "=== build-initrd.sh ==="
    log "Strategi: GoboLinux 016 init logic + Slax BusyBox"
    [ -n "$GOBO016_ISO"   ] && log "GoboLinux 016 ISO : $GOBO016_ISO"
    [ -n "$SLAX_ISO"      ] && log "Slax ISO          : $SLAX_ISO"
    [ -n "$GOBO017_ROOT"  ] && log "GoboLinux 017 root: $GOBO017_ROOT"
    log "Output initrd     : $OUTPUT_INITRD"
    echo ""

    mkdir -p "$WORK/gobo016-initrd"

    # Langkah 1: BusyBox dari Slax
    [ -n "$SLAX_ISO" ] && extract_busybox_from_slax

    # Langkah 2: Referensi init dari GoboLinux 016
    [ -n "$GOBO016_ISO" ] && extract_gobo016_initrd_structure

    # Langkah 3-5: Build initrd
    build_skeleton
    install_busybox
    write_init
    pack_initrd

    echo ""
    log "=== SELESAI ==="
    echo ""
    echo "Selanjutnya:"
    echo "  Salin ke output Porteus:"
    echo "  cp $OUTPUT_INITRD /path/to/porteus-gobolinux/boot/syslinux/initrd.xz"
}

main "$@"
