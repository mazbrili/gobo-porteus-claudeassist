#!/bin/bash
# modify-initrd.sh
# ─────────────────────────────────────────────────────────────────────────────
# Memodifikasi initrd GoboLinux agar mampu:
#   1. Menemukan dan mount semua .xzm dari /porteus/base/ via OverlayFS
#   2. Menjalankan GoboLinux link builder (System/Links) setelah overlay
#   3. Kompatibel dengan cheatcode Porteus: from=, changes=, copy2ram, dll
#
# Usage:
#   sudo bash modify-initrd.sh <initrd-input> <initrd-output>
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

INITRD_IN="${1:-}"
INITRD_OUT="${2:-}"
WORK="$(mktemp -d)"

[ -z "$INITRD_IN"  ] && { echo "Usage: $0 <initrd-in> <initrd-out>"; exit 1; }
[ -z "$INITRD_OUT" ] && { echo "Usage: $0 <initrd-in> <initrd-out>"; exit 1; }
[ -f "$INITRD_IN"  ] || { echo "File tidak ada: $INITRD_IN"; exit 1; }

trap 'rm -rf "$WORK"' EXIT

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ── Deteksi format initrd ──────────────────────────────────────────────────
log "Mendeteksi format initrd..."
MAGIC=$(file "$INITRD_IN")
echo "  Format: $MAGIC"

mkdir -p "$WORK/initrd"
cd "$WORK/initrd"

if echo "$MAGIC" | grep -q "gzip"; then
    zcat "$INITRD_IN" | cpio -id --quiet
elif echo "$MAGIC" | grep -q "XZ"; then
    xzcat "$INITRD_IN" | cpio -id --quiet
elif echo "$MAGIC" | grep -q "Zstandard"; then
    zstdcat "$INITRD_IN" | cpio -id --quiet
else
    # Coba xz dulu (GoboLinux 017 biasanya xz)
    xzcat "$INITRD_IN" | cpio -id --quiet || \
    zcat  "$INITRD_IN" | cpio -id --quiet
fi

log "Initrd diekstrak. Isi:"
ls -la .

# ── Sisipkan modul loader .xzm Porteus-style ──────────────────────────────
log "Membuat xzm-loader.sh..."
cat > "$WORK/initrd/xzm-loader.sh" << 'LOADER_EOF'
#!/bin/sh
# xzm-loader.sh — dimuat dari /init GoboLinux
# Mount semua .xzm dari /porteus/base/ menggunakan OverlayFS
# lalu jalankan GoboLinux link builder

XZM_MNTBASE="/mnt/xzm"
OVERLAY_WORK="/mnt/overlay-work"
OVERLAY_UPPER="/mnt/overlay-upper"
NEWROOT="/mnt/newroot"
PORTEUS_DIR=""

# ── Fungsi: temukan direktori porteus di media ──────────────────────────────
find_porteus_dir() {
    local from_param=""
    # Parse kernel cmdline
    for param in $(cat /proc/cmdline); do
        case "$param" in
            from=*) from_param="${param#from=}" ;;
        esac
    done

    if [ -n "$from_param" ]; then
        # Mount device/ISO yang ditunjuk 'from='
        # (logika penuh ada di init GoboLinux asli)
        PORTEUS_DIR="$from_param"
    else
        # Default: cari /porteus di semua partisi
        for dev in /dev/sd?? /dev/sd? /dev/mmcblk?p?; do
            [ -b "$dev" ] || continue
            mount -o ro "$dev" /mnt/tmp 2>/dev/null || continue
            if [ -d /mnt/tmp/porteus/base ]; then
                PORTEUS_DIR="/mnt/tmp/porteus"
                break
            fi
            umount /mnt/tmp 2>/dev/null || true
        done
    fi
    echo "$PORTEUS_DIR"
}

# ── Fungsi: mount satu .xzm ────────────────────────────────────────────────
mount_xzm() {
    local xzm_file="$1"
    local idx="$2"
    local mnt_point="$XZM_MNTBASE/$idx"

    mkdir -p "$mnt_point"
    if mount -t squashfs -o loop,ro "$xzm_file" "$mnt_point" 2>/dev/null; then
        echo "  Mounted: $(basename "$xzm_file") -> $mnt_point"
        echo "$mnt_point"
        return 0
    else
        echo "  GAGAL: $(basename "$xzm_file")" >&2
        return 1
    fi
}

# ── Main loader ─────────────────────────────────────────────────────────────
main() {
    mkdir -p "$XZM_MNTBASE" "$OVERLAY_WORK" "$OVERLAY_UPPER" "$NEWROOT"
    mkdir -p /mnt/tmp

    # Temukan direktori porteus
    find_porteus_dir
    [ -d "$PORTEUS_DIR/base" ] || {
        echo "ERROR: /porteus/base tidak ditemukan"
        return 1
    }

    # Mount semua .xzm dalam urutan alfanumerik
    local lower_dirs=""
    local idx=0
    for xzm in $(ls "$PORTEUS_DIR/base/"*.xzm 2>/dev/null | sort); do
        mpt=$(mount_xzm "$xzm" "$idx") && {
            [ -n "$lower_dirs" ] && lower_dirs="$mpt:$lower_dirs" || lower_dirs="$mpt"
            idx=$((idx + 1))
        }
    done

    # Mount modul dari /porteus/modules/ (aktif setiap boot)
    for xzm in $(ls "$PORTEUS_DIR/modules/"*.xzm 2>/dev/null | sort); do
        mpt=$(mount_xzm "$xzm" "$idx") && {
            lower_dirs="$mpt:$lower_dirs"
            idx=$((idx + 1))
        }
    done

    # Cek cheatcode load= untuk optional modules
    for param in $(cat /proc/cmdline); do
        case "$param" in
            load=*)
                xzm_path="${param#load=}"
                mpt=$(mount_xzm "$xzm_path" "$idx") && {
                    lower_dirs="$mpt:$lower_dirs"
                    idx=$((idx + 1))
                }
                ;;
        esac
    done

    [ -n "$lower_dirs" ] || { echo "ERROR: tidak ada .xzm ter-mount"; return 1; }

    # Cek cheatcode: changes=
    local changes_dir="$OVERLAY_UPPER"
    for param in $(cat /proc/cmdline); do
        case "$param" in
            changes=*) changes_dir="${param#changes=}" ;;
            nomagic)   changes_dir="$OVERLAY_UPPER" ;;  # tmpfs saja
        esac
    done

    # Mount OverlayFS
    echo "Mounting OverlayFS..."
    echo "  lower: $lower_dirs"
    echo "  upper: $changes_dir"
    mount -t overlay overlay \
        -o "lowerdir=$lower_dirs,upperdir=$changes_dir,workdir=$OVERLAY_WORK" \
        "$NEWROOT"

    # Jalankan GoboLinux link builder di newroot
    if [ -x "$NEWROOT/usr/lib/gobo/gobo-link-builder" ]; then
        echo "Membangun System/Links GoboLinux..."
        chroot "$NEWROOT" /usr/lib/gobo/gobo-link-builder \
            /Programs /System/Links 2>/dev/null || true
    fi

    echo "OverlayFS siap. Switch root ke $NEWROOT"
}

main "$@"
LOADER_EOF

chmod +x "$WORK/initrd/xzm-loader.sh"

# ── Sisipkan gobo-link-builder ke initrd ──────────────────────────────────
log "Menyisipkan gobo-link-builder..."
mkdir -p "$WORK/initrd/usr/lib/gobo"
cat > "$WORK/initrd/usr/lib/gobo/gobo-link-builder" << 'GLB_EOF'
#!/bin/sh
# gobo-link-builder minimal untuk initrd
# Versi lengkap ada di 001-base.xzm
PROGRAMS="${1:-/Programs}"
LINKS="${2:-/System/Links}"

for category in Executables Libraries Headers Settings Manuals; do
    mkdir -p "$LINKS/$category"
done

find "$PROGRAMS" -mindepth 1 -maxdepth 1 -type d | sort | while read -r prog; do
    name="$(basename "$prog")"
    # Resolve Current
    if [ -L "$prog/Current" ]; then
        ver="$(readlink -f "$prog/Current")"
    else
        ver="$(find "$prog" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)"
    fi
    [ -d "$ver" ] || continue

    # bin & sbin -> Executables
    for subdir in bin sbin; do
        [ -d "$ver/$subdir" ] && find "$ver/$subdir" -maxdepth 1 \( -type f -o -type l \) | while read -r f; do
            dst="$LINKS/Executables/$(basename "$f")"
            [ -e "$dst" ] || ln -s "$f" "$dst"
        done
    done

    # lib & lib64 -> Libraries
    for subdir in lib lib64; do
        [ -d "$ver/$subdir" ] && find "$ver/$subdir" -maxdepth 1 \( -type f -o -type l \) | while read -r f; do
            dst="$LINKS/Libraries/$(basename "$f")"
            [ -e "$dst" ] || ln -s "$f" "$dst"
        done
    done
done

# FHS symlinks
[ -e /bin     ] || ln -s /System/Links/Executables /bin
[ -e /sbin    ] || ln -s /System/Links/Executables /sbin
[ -e /lib     ] || ln -s /System/Links/Libraries   /lib
[ -e /lib64   ] || ln -s /System/Links/Libraries   /lib64
[ -e /usr/bin ] || { mkdir -p /usr; ln -s /System/Links/Executables /usr/bin; }
[ -e /usr/lib ] || ln -s /System/Links/Libraries   /usr/lib
GLB_EOF

chmod +x "$WORK/initrd/usr/lib/gobo/gobo-link-builder"

# ── Patch /init GoboLinux ────────────────────────────────────────────────────
log "Mem-patch /init..."
INIT_FILE="$WORK/initrd/init"
[ -f "$INIT_FILE" ] || INIT_FILE=$(find "$WORK/initrd" -name "init" -maxdepth 2 | head -1)

if [ -f "$INIT_FILE" ]; then
    # Sisipkan pemanggilan xzm-loader.sh sebelum switch_root
    cp "$INIT_FILE" "${INIT_FILE}.orig"

    INJECT='
# ── GoboLinux Porteus-style xzm loader ──
if [ -f /xzm-loader.sh ]; then
    . /xzm-loader.sh
fi
# ── End xzm loader ──
'
    # Cari baris sebelum exec switch_root / exec /sbin/init
    LINE=$(grep -n "exec.*switch_root\|exec.*sbin/init\|exec.*chroot" "$INIT_FILE" \
           | head -1 | cut -d: -f1 || echo "")

    if [ -n "$LINE" ]; then
        head -n $((LINE - 1)) "$INIT_FILE" > "${INIT_FILE}.new"
        echo "$INJECT"                      >> "${INIT_FILE}.new"
        tail -n +"$LINE" "$INIT_FILE"       >> "${INIT_FILE}.new"
        mv "${INIT_FILE}.new" "$INIT_FILE"
        log "  Patch berhasil di baris $LINE"
    else
        # Append ke akhir sebagai fallback
        echo "$INJECT" >> "$INIT_FILE"
        warn "  exec switch_root tidak ditemukan, snippet di-append ke akhir"
    fi
    chmod +x "$INIT_FILE"
else
    warn "File /init tidak ditemukan dalam initrd — sisipkan xzm-loader.sh manual"
fi

# ── Repack initrd ─────────────────────────────────────────────────────────
log "Repacking initrd -> $INITRD_OUT"
cd "$WORK/initrd"
find . | cpio -o -H newc --quiet | xz -9 --check=crc32 > "$INITRD_OUT"
cd -

SIZE=$(du -sh "$INITRD_OUT" | cut -f1)
log "Selesai: $INITRD_OUT ($SIZE)"
