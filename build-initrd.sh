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
    while read -r f; do
    echo "    ${f#$slax_initrd_dir/}"
    done < <(find "$slax_initrd_dir" -not -type d | head -20)

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
	    while read -r f; do
             echo "    ${f#$cramfs_mnt/}"
			    done < <(find "$cramfs_mnt" -not -type d | head -40)

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
# ─────────────────────────────────────────────────────────────────────────────
# Terinspirasi dari GoboLinux 016 InitRDScripts/bin/startGoboLinux
# BusyBox dari Slax (statik, musl/uClibc)
#
# Urutan kerja (mengikuti logika startGoboLinux GoboLinux 016):
#   1. Mount pseudo-filesystems
#   2. Jalankan mdev untuk populate /dev
#   3. Parse cmdline kernel
#   4. Probe media → cari direktori /porteus/
#   5. (opsional) copy2ram
#   6. Mount semua .xzm via losetup + mount squashfs → OverlayFS
#   7. Bangun GoboLinux System/Links di newroot
#   8. switch_root ke GoboLinux 017

export PATH=/bin:/sbin

# ── Fungsi utilitas (style GoboLinux InitRDScripts) ──────────────────────────
print_status() { echo "GoboLinux: $*"; }
warn()         { echo "GoboLinux [WARN]: $*" >&2; }
emergency_shell() {
    echo ""
    echo "=== EMERGENCY SHELL ==="
    echo "Ketik 'exit' untuk mencoba boot ulang"
    exec /bin/sh
}

# ── 1. Pseudo-filesystems ─────────────────────────────────────────────────────
mount -t proc     proc  /proc
mount -t sysfs    sysfs /sys
mount -t devtmpfs dev   /dev 2>/dev/null || mount -t tmpfs tmpfs /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts   devpts /dev/pts 2>/dev/null || true
mount -t tmpfs    tmpfs  /tmp
mount -t tmpfs    tmpfs  /run

print_status "Kernel $(uname -r)"

# ── 2. Load modul kernel dulu, BARU populate /dev ───────────────────────────
# Urutan ini penting untuk Hyper-V: hv_storvsc harus load sebelum
# disk SCSI muncul di /dev, dan squashfs/overlay/loop wajib ada
# sebelum mount .xzm dilakukan.
print_status "Load kernel modules..."
for mod in squashfs overlay loop \
           hv_vmbus hv_storvsc hv_netvsc hv_utils \
           virtio virtio_pci virtio_blk virtio_net \
           sd_mod sr_mod iso9660 vfat exfat; do
    modprobe "$mod" 2>/dev/null || true
done

# Setelah modul load, jalankan mdev agar device nodes muncul
# /proc/sys/kernel/hotplug tidak tersedia di kernel GoboLinux 017
# (CONFIG_UEVENT_HELPER sudah deprecated), jadi langsung mdev -s
mdev -s 2>/dev/null || true

# Hyper-V SCSI butuh waktu ~1-2 detik setelah hv_storvsc load
# sebelum /dev/sda muncul — tunggu dengan polling
wait_for_devices() {
    local waited=0
    local max_wait=10
    while [ $waited -lt $max_wait ]; do
        # Cek apakah ada minimal satu block device
        for dev in /dev/sr? /dev/sd? /dev/vd? /dev/hd? /dev/mmcblk?; do
            [ -b "$dev" ] && return 0
        done
        sleep 1
        mdev -s 2>/dev/null || true
        waited=$((waited + 1))
        print_status "  Menunggu device... ($waited/${max_wait}s)"
    done
    return 1
}
wait_for_devices || warn "Timeout menunggu block devices"

# Debug: tampilkan semua block device yang terdeteksi
print_status "Block devices:"
for dev in /dev/sr? /dev/sd?? /dev/sd? /dev/vd? /dev/mmcblk?p? /dev/mmcblk? /dev/hd?; do
    [ -b "$dev" ] && echo "  found: $dev $(blkid "$dev" 2>/dev/null | grep -o 'TYPE="[^"]*"' || true)"
done

# ── 3. Parse cmdline ──────────────────────────────────────────────────────────
FROM_PATH=""
CHANGES_PATH=""
COPY2RAM=0
NOMAGIC=0
LOAD_LIST=""

for p in $(cat /proc/cmdline); do
    case "$p" in
        from=*)     FROM_PATH="${p#from=}"       ;;
        changes=*)  CHANGES_PATH="${p#changes=}" ;;
        copy2ram)   COPY2RAM=1                   ;;
        nomagic)    NOMAGIC=1                    ;;
        load=*)     LOAD_LIST="$LOAD_LIST ${p#load=}" ;;
    esac
done

# ── 4. Probe media — cari /porteus/base/*.xzm ────────────────────────────────
print_status "Mencari media boot..."

PORTEUS_DIR=""
MEDIA_MNT=""

try_mount_and_find() {
    local dev="$1" fs="$2" mnt="$3"
    mkdir -p "$mnt"
    mount -t "$fs" -o ro "$dev" "$mnt" 2>/dev/null || return 1
    if [ -d "$mnt/porteus/base" ] && \
       ls "$mnt/porteus/base/"*.xzm >/dev/null 2>&1; then
        print_status "  -> $dev ($fs): OK"
        return 0
    fi
    umount "$mnt" 2>/dev/null || true
    return 1
}

scan_media() {
    local SCAN_MNT="/mnt/media/scan"
    mkdir -p "$SCAN_MNT"
    # Optical drive duluan (ISO boot), lalu disk
    for dev in /dev/sr? /dev/sr?? \
               /dev/sd? /dev/sd?? \
               /dev/vd? /dev/hd? \
               /dev/mmcblk?p? /dev/mmcblk?; do
        [ -b "$dev" ] || continue
        print_status "  Coba: $dev"
        for fs in iso9660 udf vfat exfat ext4 ext3 ext2; do
            if try_mount_and_find "$dev" "$fs" "$SCAN_MNT"; then
                PORTEUS_DIR="$SCAN_MNT/porteus"
                MEDIA_MNT="$SCAN_MNT"
                return 0
            fi
        done
        # Coba partisi di dalam disk ini
        for part in "${dev}1" "${dev}2" "${dev}p1" "${dev}p2"; do
            [ -b "$part" ] || continue
            for fs in vfat exfat ext4 ext3 ext2 iso9660; do
                if try_mount_and_find "$part" "$fs" "$SCAN_MNT"; then
                    PORTEUS_DIR="$SCAN_MNT/porteus"
                    MEDIA_MNT="$SCAN_MNT"
                    return 0
                fi
            done
        done
    done
    return 1
}

if [ -n "$FROM_PATH" ] && [ -d "$FROM_PATH/porteus/base" ]; then
    PORTEUS_DIR="$FROM_PATH/porteus"
    print_status "  Dari cmdline from=: $PORTEUS_DIR"
else
    scan_media || true
fi

if [ -z "$PORTEUS_DIR" ]; then
    warn "Tidak bisa menemukan /porteus/base/*.xzm!"
    warn "Block devices yang ada:"
    ls -la /dev/sd* /dev/sr* /dev/vd* /dev/hd* 2>/dev/null || warn "  (tidak ada)"
    warn "Isi /dev:"
    ls /dev/
    emergency_shell
fi

# ── 5. Copy to RAM (opsional) ─────────────────────────────────────────────────
if [ "$COPY2RAM" = "1" ]; then
    print_status "copy2ram: menyalin ke RAM..."
    RAM_MNT="/mnt/media/ram"
    mkdir -p "$RAM_MNT"
    # Estimasi ukuran
    SZ=$(du -sk "$PORTEUS_DIR" 2>/dev/null | cut -f1)
    SZ_MB=$(( (SZ / 1024) + 64 ))
    mount -t tmpfs -o "size=${SZ_MB}m" tmpfs "$RAM_MNT"
    cp -a "$PORTEUS_DIR" "$RAM_MNT/"
    sync
    # Umount media fisik
    [ -n "$MEDIA_MNT" ] && umount "$MEDIA_MNT" 2>/dev/null || true
    PORTEUS_DIR="$RAM_MNT/porteus"
    print_status "  Semua modul ada di RAM (${SZ_MB}MB)"
fi

# ── 6. Mount .xzm → OverlayFS ─────────────────────────────────────────────────
# GoboLinux 016 mount satu squashfs utama; kita mount banyak .xzm
# dan tumpuk dengan OverlayFS (seperti Porteus)
print_status "Mounting modul .xzm..."

XZM_BASE="/mnt/xzm"
OVERLAY_UPPER="/mnt/overlay/upper"
OVERLAY_WORK="/mnt/overlay/work"
NEWROOT="/mnt/newroot"
mkdir -p "$XZM_BASE" "$OVERLAY_UPPER" "$OVERLAY_WORK" "$NEWROOT"

LOWER_DIRS=""
IDX=0

mount_one_xzm() {
    local xzm="$1"
    local mpt="$XZM_BASE/$IDX"
    mkdir -p "$mpt"
    if mount -t squashfs -o loop,ro "$xzm" "$mpt" 2>/dev/null; then
        print_status "  + $(basename "$xzm")"
        if [ -z "$LOWER_DIRS" ]; then
            LOWER_DIRS="$mpt"
        else
            LOWER_DIRS="$LOWER_DIRS:$mpt"
        fi
        IDX=$((IDX + 1))
        return 0
    else
        warn "  ! Gagal mount: $(basename "$xzm")"
        return 1
    fi
}

# base/*.xzm (wajib, urutan numerik)
for xzm in $(ls "$PORTEUS_DIR/base/"*.xzm 2>/dev/null | sort); do
    mount_one_xzm "$xzm"
done

# modules/*.xzm (aktif setiap boot)
for xzm in $(ls "$PORTEUS_DIR/modules/"*.xzm 2>/dev/null | sort); do
    mount_one_xzm "$xzm"
done

# optional via load= cmdline
for name in $LOAD_LIST; do
    for xzm in \
        "$PORTEUS_DIR/optional/$name" \
        "$PORTEUS_DIR/optional/${name}.xzm"
    do
        [ -f "$xzm" ] && mount_one_xzm "$xzm" && break
    done
done

[ -n "$LOWER_DIRS" ] || { warn "Tidak ada .xzm berhasil di-mount!"; emergency_shell; }

# Upper layer: tmpfs (default) atau persistent (changes=)
if [ "$NOMAGIC" != "1" ] && [ -n "$CHANGES_PATH" ]; then
    mkdir -p "$CHANGES_PATH" "$OVERLAY_WORK"
    UPPER="$CHANGES_PATH"
else
    mount -t tmpfs tmpfs "$OVERLAY_UPPER"
    mkdir -p "$OVERLAY_UPPER" "$OVERLAY_WORK"
    UPPER="$OVERLAY_UPPER"
fi

print_status "Mounting OverlayFS..."
mount -t overlay overlay \
    -o "lowerdir=$LOWER_DIRS,upperdir=$UPPER,workdir=$OVERLAY_WORK" \
    "$NEWROOT" \
|| { warn "OverlayFS gagal!"; emergency_shell; }

print_status "  newroot: $NEWROOT"

# ── 7. Setup GoboLinux System/Links ──────────────────────────────────────────
# Direplikasi dari logika GoboLinux 016 startGoboLinux:
# "the SquashFS images are mounted, the pivot operation to make it
#  the root directory is performed"
# Kita tambahkan: build System/Links sebelum pivot/switch_root
print_status "Membangun GoboLinux System/Links..."

[ -d "$NEWROOT/Programs" ] || { warn "Programs/ tidak ada di newroot"; }

build_links() {
    local root="$1"
    local prog_dir="$root/Programs"
    local links_dir="$root/System/Links"

    mkdir -p \
        "$links_dir/Executables" \
        "$links_dir/Libraries" \
        "$links_dir/Headers" \
        "$links_dir/Settings" \
        "$links_dir/Manuals"

    [ -d "$prog_dir" ] || return 0

    find "$prog_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | \
    while read -r prog; do
        local name; name="$(basename "$prog")"

        # Resolve Current → versi aktif
        local ver=""
        if [ -L "$prog/Current" ]; then
            ver="$(readlink -f "$prog/Current" 2>/dev/null)"
        fi
        [ -d "$ver" ] || ver="$(find "$prog" -mindepth 1 -maxdepth 1 \
            -type d 2>/dev/null | sort -V | tail -1)"
        [ -d "$ver" ] || continue

        # Buat Current jika belum ada
        [ -e "$prog/Current" ] || ln -snf "$ver" "$prog/Current" 2>/dev/null

        # Executables: bin/ sbin/
        for sub in bin sbin; do
            [ -d "$ver/$sub" ] || continue
            find "$ver/$sub" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | \
            while read -r f; do
                local dst="$links_dir/Executables/$(basename "$f")"
                [ -e "$dst" ] || ln -s "$f" "$dst" 2>/dev/null
            done
        done

        # Libraries: lib/ lib64/
        for sub in lib lib64; do
            [ -d "$ver/$sub" ] || continue
            find "$ver/$sub" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | \
            while read -r f; do
                local dst="$links_dir/Libraries/$(basename "$f")"
                [ -e "$dst" ] || ln -s "$f" "$dst" 2>/dev/null
            done
        done

        # Settings: etc/ (symlink seluruh direktori per program)
        [ -d "$ver/etc" ] && {
            local sdst="$links_dir/Settings/$name"
            [ -e "$sdst" ] || ln -s "$ver/etc" "$sdst" 2>/dev/null
        }
    done
}

build_links "$NEWROOT"
print_status "  System/Links selesai"

# ── FHS compat (seperti GoboLinux 016 via legacy symlinks) ───────────────────
# GoboLinux 016 sudah memiliki symlinks ini di ROLayer; kita pastikan ada
for pair in \
    "/bin:/System/Links/Executables" \
    "/sbin:/System/Links/Executables" \
    "/lib:/System/Links/Libraries" \
    "/lib64:/System/Links/Libraries"
do
    link="${pair%%:*}"
    tgt="${pair#*:}"
    [ -e "$NEWROOT$link" ] || ln -s "$tgt" "$NEWROOT$link" 2>/dev/null || true
done
[ -e "$NEWROOT/usr" ] || ln -s "/" "$NEWROOT/usr" 2>/dev/null || true

# System/Kernel links
if [ -d "$NEWROOT/Programs/Linux" ]; then
    linux_dir="$NEWROOT/Programs/Linux"
    kver=$(find "$linux_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
           | grep -v Current | sort -V | tail -1 | xargs basename 2>/dev/null || true)
    if [ -n "$kver" ]; then
        mkdir -p "$NEWROOT/System/Kernel"
        kpath="$linux_dir/$kver"
        [ -d "$kpath/boot"        ] && \
            ln -snf "$kpath/boot"        "$NEWROOT/System/Kernel/Boot"    2>/dev/null || true
        [ -d "$kpath/lib/modules" ] && \
            ln -snf "$kpath/lib/modules" "$NEWROOT/System/Kernel/Modules" 2>/dev/null || true
        print_status "  System/Kernel: Linux $kver"
    fi
fi

# ── 8. Handoff ke GoboLinux ───────────────────────────────────────────────────
# Seperti GoboLinux 016: mount ulang pseudo-fs di newroot, lalu switch_root
# (GoboLinux 016 pakai pivot_root; kita pakai switch_root karena initramfs)
print_status "Handoff ke GoboLinux 017..."

for fs_arg in "proc proc /proc" "sysfs sysfs /sys" "devtmpfs dev /dev" "tmpfs tmpfs /run"; do
    t="${fs_arg%% *}"; rest="${fs_arg#* }"; src="${rest%% *}"; dst="${rest#* }"
    mount -t "$t" "$src" "$NEWROOT/$dst" 2>/dev/null || \
    mount --bind "/$dst" "$NEWROOT/$dst" 2>/dev/null || true
done
mkdir -p "$NEWROOT/dev/pts"
mount -t devpts devpts "$NEWROOT/dev/pts" 2>/dev/null || true

# Cari init GoboLinux (GoboLinux 016: /sbin/init memanggil BootDriver)
NEWROOT_INIT=""
for candidate in \
    "$NEWROOT/sbin/init" \
    "$NEWROOT/System/Links/Executables/init" \
    "$NEWROOT/bin/init" \
    "$NEWROOT/Programs/Sysvinit/Current/sbin/init" \
    "$NEWROOT/Programs/Scripts/Current/bin/StartGoboLinux"
do
    [ -x "$candidate" ] && { NEWROOT_INIT="${candidate#$NEWROOT}"; break; }
done

[ -n "$NEWROOT_INIT" ] || NEWROOT_INIT="/bin/sh"

print_status "switch_root -> $NEWROOT_INIT"
exec switch_root "$NEWROOT" "$NEWROOT_INIT"

# Tidak seharusnya sampai sini
warn "switch_root gagal!"
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
