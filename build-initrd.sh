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

    while read -r f; do

    echo " ${f#$slax_initrd_dir/}"
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
        echo " ${f#$cramfs_mnt/}"
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
# TAHAP 3b: Salin modul kernel dari GoboLinux 017 ke dalam initramfs
# Ini WAJIB agar modprobe bisa load sr_mod, cdrom, squashfs, overlay, loop
# tanpa perlu modul ini built-in di kernel
# ─────────────────────────────────────────────────────────────────────────────
copy_kernel_modules() {
    [ -n "$GOBO017_ROOT" ] || { warn "GOBO017_ROOT tidak disetel — skip copy modules"; return 0; }
    [ -d "$GOBO017_ROOT" ] || { warn "GOBO017_ROOT tidak ada: $GOBO017_ROOT"; return 0; }

    log "Menyalin modul kernel dari GoboLinux 017..."

    # Cari direktori modules di Programs/Linux/<ver>/lib/modules/<kver>/
    local kver_dir=""
    local linux_prog="$GOBO017_ROOT/Programs/Linux"

    if [ -d "$linux_prog" ]; then
        # Resolve Current
        local linux_cur="$linux_prog/Current"
        [ -L "$linux_cur" ] && linux_cur=$(readlink -f "$linux_cur")
        [ -d "$linux_cur" ] || linux_cur=$(find "$linux_prog" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)

        # Cari di lib/modules/
        kver_dir=$(find "$linux_cur/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
        info "Programs/Linux: $linux_cur"
    fi

    # Fallback: cari di /lib/modules/ langsung di gobo-root
    if [ -z "$kver_dir" ]; then
        kver_dir=$(find "$GOBO017_ROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
    fi

    [ -n "$kver_dir" ] || { warn "Direktori modules tidak ditemukan di GoboLinux 017"; return 0; }

    local kver
    kver=$(basename "$kver_dir")
    info "Kernel versi: $kver"
    info "Sumber modules: $kver_dir"

    # Modul yang WAJIB ada di initramfs untuk boot via ISO/USB
    # Dikelompokkan per fungsi
    local REQUIRED_MODULES=(
        # Optical drive — KRITIS untuk boot dari ISO/CD
        "kernel/drivers/cdrom/cdrom.ko"
        "kernel/drivers/scsi/sr_mod.ko"

        # SCSI generic (dibutuhkan sr_mod)
        "kernel/drivers/scsi/scsi_mod.ko"
        "kernel/drivers/scsi/scsi_common.ko"

        # Filesystem untuk mount media
        "kernel/fs/isofs/isofs.ko"
        "kernel/fs/squashfs/squashfs.ko"
        "kernel/fs/overlayfs/overlay.ko"
        "kernel/fs/fat/fat.ko"
        "kernel/fs/fat/vfat.ko"
        "kernel/fs/nls/nls_cp437.ko"
        "kernel/fs/nls/nls_iso8859-1.ko"
        "kernel/fs/nls/nls_utf8.ko"

        # Loop device
        "kernel/drivers/block/loop.ko"

        # Hyper-V
        "kernel/drivers/hv/hv_vmbus.ko"
        "kernel/drivers/scsi/hv_storvsc.ko"
        "kernel/drivers/net/hyperv/hv_netvsc.ko"
        "kernel/drivers/hv/hv_utils.ko"

        # VirtIO (QEMU/KVM)
        "kernel/drivers/virtio/virtio.ko"
        "kernel/drivers/virtio/virtio_ring.ko"
        "kernel/drivers/virtio/virtio_pci.ko"
        "kernel/drivers/block/virtio_blk.ko"
        "kernel/drivers/net/virtio_net.ko"
        "kernel/drivers/scsi/virtio_scsi.ko"

        # USB Storage (boot dari USB)
        "kernel/drivers/usb/storage/usb-storage.ko"
        "kernel/drivers/usb/host/xhci-hcd.ko"
        "kernel/drivers/usb/host/xhci-pci.ko"
        "kernel/drivers/usb/host/ehci-hcd.ko"
        "kernel/drivers/usb/host/ehci-pci.ko"
    )

    # Salin modul ke initramfs dengan struktur yang sama
    local dst_base="$INITRD_DIR/lib/modules/$kver"
    mkdir -p "$dst_base"

    local copied=0 missing=0
    for rel in "${REQUIRED_MODULES[@]}"; do
        local src="$kver_dir/$rel"
        if [ -f "$src" ]; then
            local dst_dir="$dst_base/$(dirname "$rel")"
            mkdir -p "$dst_dir"
            cp "$src" "$dst_dir/"
            copied=$((copied+1))
        else
            # Coba cari dengan nama file saja (path bisa berbeda antar versi)
            local fname; fname=$(basename "$rel")
            local found; found=$(find "$kver_dir" -name "$fname" 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                local rel_found="${found#$kver_dir/}"
                local dst_dir="$dst_base/$(dirname "$rel_found")"
                mkdir -p "$dst_dir"
                cp "$found" "$dst_dir/"
                copied=$((copied+1))
                info "  found (alt path): $fname"
            else
                warn "  tidak ada: $fname"
                missing=$((missing+1))
            fi
        fi
    done

    # Salin modules.dep, modules.alias, modules.order agar modprobe bekerja
    for meta in modules.dep modules.dep.bin modules.alias modules.alias.bin                 modules.order modules.builtin modules.builtin.bin                 modules.devname modules.softdep; do
        [ -f "$kver_dir/$meta" ] && cp "$kver_dir/$meta" "$dst_base/"
    done

    # Buat symlink /lib/modules/<kver> -> path yang benar agar modprobe menemukan
    mkdir -p "$INITRD_DIR/lib/modules"

    info "Modul disalin: $copied, tidak ditemukan: $missing"
    log "Copy kernel modules selesai: $kver"
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
# BusyBox (Slax) + modul kernel dari GoboLinux 017
# Tidak pakai 'basename' sebagai command — pakai parameter expansion
# Tidak pakai 'local' di luar fungsi

export PATH=/bin:/sbin

print_status() { echo "GoboLinux: $*"; }
warn()         { echo "GoboLinux [WARN]: $*"; }

emergency_shell() {
    echo "=== EMERGENCY SHELL ==="
    echo "--- cmdline:"; cat /proc/cmdline
    echo "--- /sys/block:"; ls /sys/block/ 2>/dev/null
    echo "--- /dev:"; ls /dev/ 2>/dev/null
    echo "--- modules:"; cat /proc/modules 2>/dev/null | cut -d' ' -f1
    echo "--- dmesg:"; dmesg 2>/dev/null | tail -30
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

# ── 2. Load modul kernel dengan insmod eksplisit (tanpa dependency modprobe) ─
# modprobe butuh modules.dep yang lengkap dan benar.
# insmod lebih reliable di initramfs karena kita kontrol urutan sendiri.
# Modul sudah disalin oleh copy_kernel_modules() di build-initrd.sh.
print_status "Loading modules..."

KVER=$(uname -r)
MDIR="/lib/modules/$KVER"

# Helper: cari file .ko di mana saja dalam MDIR, load dengan insmod
load_mod() {
    modname="$1"
    # Cari file .ko — ganti - dengan [ _-] untuk match keduanya
    kofile=$(find "$MDIR" -name "${modname}.ko" -o -name "${modname}.ko.xz" \
             -o -name "${modname}.ko.zst" 2>/dev/null | head -1)
    # Coba juga dengan dash diganti underscore dan sebaliknya
    if [ -z "$kofile" ]; then
        alt=$(echo "$modname" | tr '-' '_')
        kofile=$(find "$MDIR" -name "${alt}.ko" 2>/dev/null | head -1)
    fi
    if [ -z "$kofile" ]; then
        alt=$(echo "$modname" | tr '_' '-')
        kofile=$(find "$MDIR" -name "${alt}.ko" 2>/dev/null | head -1)
    fi
    if [ -n "$kofile" ]; then
        insmod "$kofile" 2>/dev/null && \
            print_status "  insmod: $modname" || \
            print_status "  skip (sudah ada?): $modname"
        return 0
    fi
    # Fallback ke modprobe jika insmod tidak bisa
    modprobe "$modname" 2>/dev/null && print_status "  modprobe: $modname" || true
    return 0
}

# Urutan eksplisit — dependency dulu
# SCSI core
load_mod scsi_mod
load_mod scsi_common

# Hyper-V: hv_vmbus WAJIB sebelum hv_storvsc
load_mod hv_vmbus
load_mod hv_storvsc
load_mod hv_utils

# VirtIO (QEMU/KVM)
load_mod virtio
load_mod virtio_ring
load_mod virtio_pci
load_mod virtio_blk
load_mod virtio_scsi

# Optical drive
load_mod cdrom
load_mod sr_mod

# Filesystem
load_mod isofs
load_mod squashfs
load_mod overlay
load_mod loop
load_mod fat
load_mod vfat

# USB (untuk boot dari USB)
load_mod usb_common
load_mod usbcore
load_mod xhci_hcd
load_mod xhci_pci
load_mod ehci_hcd
load_mod ehci_pci
load_mod usb_storage

# ── 3. Buat device nodes dari /sys/block ─────────────────────────────────────
# Gunakan parameter expansion bukan basename (lebih portable di ash BusyBox)
print_status "Buat device nodes..."

make_node() {
    sysf="$1"
    node="$2"
    [ -f "$sysf" ] || return 1
    mm=$(cat "$sysf")
    mknod "$node" b "${mm%%:*}" "${mm##*:}" 2>/dev/null || true
    [ -b "$node" ] && print_status "  $node (${mm%%:*}:${mm##*:})"
}

scan_and_make_nodes() {
    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        # Pakai ${blk##*/} bukan basename — tidak butuh basename applet
        bname="${blk##*/}"
        make_node "$blk/dev" "/dev/$bname"
        # Partisi
        for part in "$blk/$bname"[0-9] "$blk/${bname}"[0-9][0-9] \
                    "$blk/${bname}p"[0-9] "$blk/${bname}p"[0-9][0-9]; do
            [ -d "$part" ] || continue
            pname="${part##*/}"
            make_node "$part/dev" "/dev/$pname"
        done
    done
    # Optical via /sys/class/block
    for cd in /sys/class/block/sr* /sys/class/block/scd*; do
        [ -d "$cd" ] || continue
        cdname="${cd##*/}"
        make_node "$cd/dev" "/dev/$cdname"
    done
}

scan_and_make_nodes

# ── 4. Tunggu storage device muncul di /sys/block ────────────────────────────
print_status "Tunggu storage device..."
waited=0
while [ $waited -lt 20 ]; do
    found=0
    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        bname="${blk##*/}"
        case "$bname" in
            loop*|ram*|zram*|"*") continue ;;
        esac
        found=1
        break
    done

    if [ $found -eq 1 ]; then
        print_status "  Storage muncul setelah ${waited}s"
        scan_and_make_nodes
        break
    fi

    sleep 1
    waited=$((waited+1))
    print_status "  ${waited}s..."

    # Retry load modul Hyper-V (kadang perlu beberapa detik)
    load_mod hv_vmbus   2>/dev/null
    load_mod hv_storvsc 2>/dev/null
    load_mod virtio_blk 2>/dev/null
    load_mod sr_mod     2>/dev/null
done

print_status "Storage devices:"
for blk in /sys/block/*; do
    [ -d "$blk" ] || continue
    bname="${blk##*/}"
    case "$bname" in loop*|ram*|zram*) continue ;; esac
    print_status "  /dev/$bname"
done

# ── 5. Parse cmdline ─────────────────────────────────────────────────────────
FROM_PATH=""
CHANGES_PATH=""
COPY2RAM=0
NOMAGIC=0
LOAD_LIST=""

for p in $(cat /proc/cmdline); do
    case "$p" in
        from=*)    FROM_PATH="${p#from=}"            ;;
        changes=*) CHANGES_PATH="${p#changes=}"      ;;
        copy2ram)  COPY2RAM=1                        ;;
        nomagic)   NOMAGIC=1                         ;;
        load=*)    LOAD_LIST="$LOAD_LIST ${p#load=}" ;;
    esac
done

# ── 6. Cari /porteus/base/*.xzm ──────────────────────────────────────────────
print_status "Cari media boot..."
PORTEUS_DIR=""
MEDIA_MNT=""
SCAN_MNT="/mnt/scan"
mkdir -p "$SCAN_MNT"

try_one() {
    tdev="$1" tfs="$2"
    umount "$SCAN_MNT" 2>/dev/null || true
    mount -t "$tfs" -o ro "$tdev" "$SCAN_MNT" 2>/dev/null || return 1
    if [ -d "$SCAN_MNT/porteus/base" ] && \
       ls "$SCAN_MNT/porteus/base/"*.xzm >/dev/null 2>&1; then
        return 0
    fi
    umount "$SCAN_MNT" 2>/dev/null || true
    return 1
}

scan_devices() {
    for blk in /sys/block/*; do
        [ -d "$blk" ] || continue
        bname="${blk##*/}"
        case "$bname" in loop*|ram*|zram*) continue ;; esac
        [ -b "/dev/$bname" ] || continue

        for tdev in "/dev/$bname" \
                    "/dev/${bname}1" "/dev/${bname}2" \
                    "/dev/${bname}p1" "/dev/${bname}p2"; do
            [ -b "$tdev" ] || continue
            print_status "  try: $tdev"
            for tfs in iso9660 udf vfat exfat ext4 ext3 ext2; do
                if try_one "$tdev" "$tfs"; then
                    PORTEUS_DIR="$SCAN_MNT/porteus"
                    MEDIA_MNT="$SCAN_MNT"
                    print_status "  FOUND: $tdev ($tfs)"
                    return 0
                fi
            done
        done
    done
    return 1
}

if [ -n "$FROM_PATH" ]; then
    case "$FROM_PATH" in
        /dev/*)
            for tfs in iso9660 udf vfat ext4 ext3 ext2; do
                try_one "$FROM_PATH" "$tfs" && {
                    PORTEUS_DIR="$SCAN_MNT/porteus"
                    MEDIA_MNT="$SCAN_MNT"
                    break
                }
            done ;;
        *) [ -d "$FROM_PATH/porteus/base" ] && PORTEUS_DIR="$FROM_PATH/porteus" ;;
    esac
fi

[ -z "$PORTEUS_DIR" ] && { scan_devices || true; }

if [ -z "$PORTEUS_DIR" ]; then
    warn "Tidak menemukan /porteus/base/*.xzm"
    emergency_shell
fi

# ── 7. Copy to RAM ───────────────────────────────────────────────────────────
if [ "$COPY2RAM" = "1" ]; then
    print_status "copy2ram..."
    mkdir -p /mnt/ram
    SZ=$(du -sk "$PORTEUS_DIR" 2>/dev/null | cut -f1)
    SZ_MB=$(( (SZ / 1024) + 128 ))
    mount -t tmpfs -o "size=${SZ_MB}m" tmpfs /mnt/ram
    cp -a "$PORTEUS_DIR/." /mnt/ram/
    sync
    [ -n "$MEDIA_MNT" ] && umount "$MEDIA_MNT" 2>/dev/null || true
    PORTEUS_DIR="/mnt/ram"
fi

# ── 8. Mount .xzm → OverlayFS ────────────────────────────────────────────────
print_status "Mount .xzm..."
mkdir -p /mnt/xzm /mnt/up /mnt/wk /mnt/new
LOWER="" IDX=0

mount_xzm() {
    xf="$1"
    xmpt="/mnt/xzm/$IDX"
    mkdir -p "$xmpt"
    if mount -t squashfs -o loop,ro "$xf" "$xmpt" 2>/dev/null; then
        xname="${xf##*/}"
        print_status "  + $xname"
        if [ -z "$LOWER" ]; then LOWER="$xmpt"
        else LOWER="$LOWER:$xmpt"; fi
        IDX=$((IDX+1))
        return 0
    fi
    xname="${xf##*/}"
    warn "  gagal: $xname"
    return 1
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

[ -n "$LOWER" ] || { warn "Tidak ada .xzm di-mount"; emergency_shell; }

if [ "$NOMAGIC" = "1" ] || [ -z "$CHANGES_PATH" ]; then
    mount -t tmpfs tmpfs /mnt/up
    UP_DIR=/mnt/up
else
    mkdir -p "$CHANGES_PATH"
    UP_DIR="$CHANGES_PATH"
fi
mkdir -p "$UP_DIR" /mnt/wk

mount -t overlay overlay \
    -o "lowerdir=$LOWER,upperdir=$UP_DIR,workdir=/mnt/wk" \
    /mnt/new \
    || { warn "OverlayFS gagal"; emergency_shell; }
print_status "OverlayFS OK"

# ── 9. GoboLinux System/Links ────────────────────────────────────────────────
print_status "System/Links..."
if [ -d /mnt/new/Programs ]; then
    for prog in /mnt/new/Programs/*/; do
        [ -d "$prog" ] || continue
        pname="${prog%/}"
        pname="${pname##*/}"
        if [ -L "${prog}Current" ]; then
            ver=$(readlink -f "${prog}Current" 2>/dev/null)
        else
            ver=$(find "$prog" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
        fi
        [ -d "$ver" ] || continue
        [ -e "${prog}Current" ] || ln -snf "$ver" "${prog}Current" 2>/dev/null
        mkdir -p /mnt/new/System/Links/Executables \
                 /mnt/new/System/Links/Libraries
        for sub in bin sbin; do
            [ -d "$ver/$sub" ] || continue
            for f in "$ver/$sub/"*; do
                [ -e "$f" ] || continue
                fname="${f##*/}"
                dst="/mnt/new/System/Links/Executables/$fname"
                [ -e "$dst" ] || ln -s "$f" "$dst" 2>/dev/null
            done
        done
        for sub in lib lib64; do
            [ -d "$ver/$sub" ] || continue
            for f in "$ver/$sub/"*; do
                [ -e "$f" ] || continue
                fname="${f##*/}"
                dst="/mnt/new/System/Links/Libraries/$fname"
                [ -e "$dst" ] || ln -s "$f" "$dst" 2>/dev/null
            done
        done
    done
fi
for pair in "bin:/System/Links/Executables" "sbin:/System/Links/Executables" \
            "lib:/System/Links/Libraries"   "lib64:/System/Links/Libraries"; do
    lnk="${pair%%:*}"; tgt="${pair#*:}"
    [ -e "/mnt/new/$lnk" ] || ln -s "$tgt" "/mnt/new/$lnk" 2>/dev/null || true
done
[ -e /mnt/new/usr ] || ln -s "/" /mnt/new/usr 2>/dev/null || true

# ── 10. switch_root ──────────────────────────────────────────────────────────
print_status "switch_root..."
for fsinfo in "proc:proc:/proc" "sysfs:sysfs:/sys" "devtmpfs:dev:/dev" "tmpfs:tmpfs:/run"; do
    t="${fsinfo%%:*}"; rest="${fsinfo#*:}"; src="${rest%%:*}"; dst="${rest#*:}"
    mount -t "$t" "$src" "/mnt/new/$dst" 2>/dev/null || \
    mount --bind "/$dst" "/mnt/new/$dst" 2>/dev/null || true
done
mkdir -p /mnt/new/dev/pts
mount -t devpts devpts /mnt/new/dev/pts 2>/dev/null || true

INIT=""
for c in /mnt/new/sbin/init /mnt/new/System/Links/Executables/init \
          /mnt/new/bin/init  /mnt/new/Programs/Sysvinit/Current/sbin/init; do
    [ -x "$c" ] && { INIT="${c#/mnt/new}"; break; }
done
[ -n "$INIT" ] || INIT="/bin/sh"

print_status "exec switch_root -> $INIT"
exec switch_root /mnt/new "$INIT"

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

    # Langkah 3: Build skeleton
    build_skeleton

    # Langkah 3b: Salin modul kernel dari GoboLinux 017 (WAJIB untuk sr_mod, dll)
    copy_kernel_modules

    # Langkah 4-6: Install busybox, tulis init, pack
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
