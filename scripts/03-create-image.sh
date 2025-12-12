#!/bin/bash
#
# 03-create-image.sh - Create bootable disk image
#
# This script creates a partitioned disk image with:
#   - Partition 1: Boot (FAT32, syslinux bootloader)
#   - Partition 2: Root (SquashFS or ext4 for dev-mode)
#   - Partition 3: Data (ext4)
#
# Usage:
#   sudo ./03-create-image.sh --rootfs=/path/to/rootfs --output=/path/to/output \
#     --ospart=500M --datapart=1G
#
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source configuration and libraries
source "${PROJECT_ROOT}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

# Command line arguments
ROOTFS_DIR=""
OUTPUT_DIR=""
OS_PART_SIZE="${DEFAULT_OS_PART_SIZE}"
DATA_PART_SIZE="${DEFAULT_DATA_PART_SIZE}"
BOOT_PART_SIZE="${DEFAULT_BOOT_SIZE}"
DEV_MODE=false
DEBUG_MODE=false

# Calculated variables
BOOT_PART_SIZE_MB=0
OS_PART_SIZE_MB=0
DATA_PART_SIZE_MB=0
TOTAL_SIZE_MB=0
IMAGE_FILE=""
LOOP_DEVICE=""

# Cleanup tracking
CLEANUP_LOOP=""
CLEANUP_MOUNTS=()

show_usage() {
    cat <<EOF
Create bootable disk image from Alpine rootfs

Usage:
  sudo $0 --rootfs=DIR --output=DIR [OPTIONS]

Required Arguments:
  --rootfs=DIR          Path to Alpine rootfs directory
  --output=DIR          Output directory for disk image

Optional Arguments:
  --ospart=SIZE         Root partition size (default: ${DEFAULT_OS_PART_SIZE})
  --datapart=SIZE       Data partition size (default: ${DEFAULT_DATA_PART_SIZE})
  --bootpart=SIZE       Boot partition size (default: ${DEFAULT_BOOT_SIZE})
  --dev-mode            Create writable ext4 rootfs instead of SquashFS
  --debug               Keep mounted on error for debugging
  --help, -h            Show this help

Output:
  Creates ${IMAGE_NAME_PREFIX}.raw in the output directory

EOF
    exit 0
}

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --rootfs=*)     ROOTFS_DIR="${arg#*=}" ;;
            --output=*)     OUTPUT_DIR="${arg#*=}" ;;
            --ospart=*)     OS_PART_SIZE="${arg#*=}" ;;
            --datapart=*)   DATA_PART_SIZE="${arg#*=}" ;;
            --bootpart=*)   BOOT_PART_SIZE="${arg#*=}" ;;
            --dev-mode)     DEV_MODE=true ;;
            --debug)        DEBUG_MODE=true ;;
            --help|-h)      show_usage ;;
            *)              error "Unknown argument: $arg" ;;
        esac
    done

    [ -z "$ROOTFS_DIR" ] && error "Missing required argument: --rootfs"
    [ -z "$OUTPUT_DIR" ] && error "Missing required argument: --output"

    ROOTFS_DIR="$(to_absolute_path "$ROOTFS_DIR")"
    OUTPUT_DIR="$(to_absolute_path "$OUTPUT_DIR")"

    validate_dir "$ROOTFS_DIR" "Rootfs directory"

    # Parse partition sizes
    BOOT_PART_SIZE_MB=$(parse_size_mb "$BOOT_PART_SIZE")
    OS_PART_SIZE_MB=$(parse_size_mb "$OS_PART_SIZE")
    DATA_PART_SIZE_MB=$(parse_size_mb "$DATA_PART_SIZE")

    # Calculate total size (add 16MB for MBR and alignment)
    TOTAL_SIZE_MB=$((BOOT_PART_SIZE_MB + OS_PART_SIZE_MB + DATA_PART_SIZE_MB + 16))

    IMAGE_FILE="${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw"
}

# Cleanup function for trap
cleanup() {
    cleanup_on_exit
}

create_disk_image() {
    log "Creating disk image..."

    mkdir -p "$OUTPUT_DIR"

    # Remove existing image
    rm -f "$IMAGE_FILE"

    # Create sparse image file
    info "Image size: ${TOTAL_SIZE_MB}MB"
    dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=0 seek="$TOTAL_SIZE_MB" status=none

    info "Disk image created: $IMAGE_FILE"
}

partition_image() {
    log "Partitioning disk image..."

    # Calculate partition boundaries (in sectors, 512 bytes/sector)
    local boot_start=2048  # Start at 1MB for alignment
    local boot_end=$((boot_start + BOOT_PART_SIZE_MB * 2048 - 1))
    local os_start=$((boot_end + 1))
    local os_end=$((os_start + OS_PART_SIZE_MB * 2048 - 1))
    local data_start=$((os_end + 1))

    # Create MBR partition table
    parted -s "$IMAGE_FILE" mklabel msdos

    # Create partitions
    parted -s "$IMAGE_FILE" mkpart primary fat32 ${boot_start}s ${boot_end}s
    parted -s "$IMAGE_FILE" set 1 boot on
    parted -s "$IMAGE_FILE" mkpart primary ext4 ${os_start}s ${os_end}s
    parted -s "$IMAGE_FILE" mkpart primary ext4 ${data_start}s 100%

    # Show partition layout
    info "Partition layout:"
    parted -s "$IMAGE_FILE" print
}

setup_loop() {
    log "Setting up loop device..."

    LOOP_DEVICE=$(setup_loop_device "$IMAGE_FILE")
    CLEANUP_LOOP="$LOOP_DEVICE"

    # Wait for partition devices
    sleep 2
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 1

    # Verify partitions exist
    for i in 1 2 3; do
        if [ ! -e "${LOOP_DEVICE}p${i}" ]; then
            error "Partition ${i} not found: ${LOOP_DEVICE}p${i}"
        fi
    done

    info "Loop device: $LOOP_DEVICE"
}

format_partitions() {
    log "Formatting partitions..."

    # Format boot partition (FAT32)
    info "Formatting boot partition (FAT32)..."
    mkfs.vfat -F 32 -n BOOT "${LOOP_DEVICE}p1"

    # Format/prepare OS partition
    if [ "$DEV_MODE" = "true" ]; then
        info "Formatting OS partition (ext4 - dev mode)..."
        mkfs.ext4 -L ROOTFS -q "${LOOP_DEVICE}p2"
    else
        info "OS partition will be SquashFS (created later)"
    fi

    # Format data partition (ext4)
    info "Formatting data partition (ext4)..."
    mkfs.ext4 -L DATA -q "${LOOP_DEVICE}p3"

    info "Partitions formatted"
}

install_bootloader() {
    log "Installing bootloader (syslinux)..."

    local boot_mount="${OUTPUT_DIR}/mnt_boot"
    mkdir -p "$boot_mount"

    # Mount boot partition
    mount "${LOOP_DEVICE}p1" "$boot_mount"
    CLEANUP_MOUNTS+=("$boot_mount")

    # Install syslinux to boot partition
    syslinux --install "${LOOP_DEVICE}p1"

    # Install MBR
    dd if=/usr/lib/syslinux/bios/mbr.bin of="$LOOP_DEVICE" bs=440 count=1 conv=notrunc

    # Copy ldlinux.c32 to root (MUST be in same directory as ldlinux.sys)
    cp /usr/lib/syslinux/bios/ldlinux.c32 "${boot_mount}/" 2>/dev/null || true

    # Copy syslinux modules to syslinux directory
    mkdir -p "${boot_mount}/syslinux"
    cp /usr/lib/syslinux/bios/*.c32 "${boot_mount}/syslinux/" 2>/dev/null || true

    info "Bootloader installed"

    # Keep boot partition mounted for kernel installation
}

copy_kernel_and_initramfs() {
    log "Installing kernel and initramfs..."

    local boot_mount="${OUTPUT_DIR}/mnt_boot"

    # Find kernel in rootfs
    local kernel_file=""
    for kf in "${ROOTFS_DIR}/boot/vmlinuz-virt" "${ROOTFS_DIR}/boot/vmlinuz-"*; do
        if [ -f "$kf" ]; then
            kernel_file="$kf"
            break
        fi
    done

    if [ -z "$kernel_file" ]; then
        error "Kernel not found in rootfs"
    fi

    # Copy kernel
    cp "$kernel_file" "${boot_mount}/vmlinuz-virt"
    info "Kernel installed: $(basename "$kernel_file")"

    # Create custom initramfs
    create_custom_initramfs "$boot_mount"

    # Create syslinux configuration
    create_syslinux_config "$boot_mount"

    # Unmount boot partition
    sync
    umount "$boot_mount"
    CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$boot_mount}")

    info "Kernel and initramfs installed"
}

create_custom_initramfs() {
    local boot_mount="$1"
    local initramfs_work="${OUTPUT_DIR}/initramfs_work"

    log "Creating custom initramfs..."

    # Clean and create work directory
    rm -rf "$initramfs_work"
    mkdir -p "$initramfs_work"

    # Create initramfs directory structure
    mkdir -p "${initramfs_work}"/{bin,sbin,etc,proc,sys,dev,mnt,newroot,lib}
    mkdir -p "${initramfs_work}/mnt"/{rootfs,data,overlay}

    # Copy busybox from rootfs
    if [ -f "${ROOTFS_DIR}/bin/busybox" ]; then
        cp "${ROOTFS_DIR}/bin/busybox" "${initramfs_work}/bin/busybox"
        chmod +x "${initramfs_work}/bin/busybox"

        # Create essential symlinks for all commands needed by init script
        for cmd in sh ash mount umount switch_root mkdir cat echo sleep mknod \
                   ls cp mv rm ln chmod chown grep sed awk cut head tail \
                   true false test [ expr dmesg lsmod modprobe find \
                   basename dirname readlink dd; do
            ln -sf busybox "${initramfs_work}/bin/$cmd"
        done

        # Also create sbin symlinks
        for cmd in switch_root; do
            ln -sf ../bin/busybox "${initramfs_work}/sbin/$cmd"
        done
    else
        error "Busybox not found in rootfs"
    fi

    # Copy musl libc (required for dynamically linked busybox)
    # Alpine uses musl, so we need to copy the dynamic linker
    if [ -f "${ROOTFS_DIR}/lib/ld-musl-x86_64.so.1" ]; then
        cp "${ROOTFS_DIR}/lib/ld-musl-x86_64.so.1" "${initramfs_work}/lib/"
        info "Copied musl libc for initramfs"
    elif [ -f "${ROOTFS_DIR}/lib/libc.musl-x86_64.so.1" ]; then
        cp "${ROOTFS_DIR}/lib/libc.musl-x86_64.so.1" "${initramfs_work}/lib/"
        # Create symlink expected by dynamic linker
        ln -sf libc.musl-x86_64.so.1 "${initramfs_work}/lib/ld-musl-x86_64.so.1"
        info "Copied musl libc for initramfs"
    else
        warn "musl libc not found - busybox may need to be statically linked"
    fi

    # Copy our custom init script
    local init_src="${PROJECT_ROOT}/initramfs/init"
    if [ -f "$init_src" ]; then
        cp "$init_src" "${initramfs_work}/init"
        chmod +x "${initramfs_work}/init"
    else
        error "Custom init script not found: $init_src"
    fi

    # Copy kernel modules for storage drivers
    local kver=""
    for kdir in "${ROOTFS_DIR}/lib/modules"/*; do
        if [ -d "$kdir" ]; then
            kver=$(basename "$kdir")
            break
        fi
    done

    if [ -n "$kver" ] && [ -d "${ROOTFS_DIR}/lib/modules/${kver}" ]; then
        info "Copying kernel modules for version: $kver"
        mkdir -p "${initramfs_work}/lib/modules/${kver}/kernel/drivers"

        # Copy essential storage driver modules
        local mod_src="${ROOTFS_DIR}/lib/modules/${kver}/kernel/drivers"
        local mod_dst="${initramfs_work}/lib/modules/${kver}/kernel/drivers"

        # ATA/SATA/IDE drivers
        if [ -d "${mod_src}/ata" ]; then
            cp -a "${mod_src}/ata" "${mod_dst}/" 2>/dev/null || true
        fi

        # SCSI drivers (needed for sd_mod)
        if [ -d "${mod_src}/scsi" ]; then
            cp -a "${mod_src}/scsi" "${mod_dst}/" 2>/dev/null || true
        fi

        # Block drivers
        if [ -d "${mod_src}/block" ]; then
            cp -a "${mod_src}/block" "${mod_dst}/" 2>/dev/null || true
        fi

        # Virtio drivers
        if [ -d "${mod_src}/virtio" ]; then
            cp -a "${mod_src}/virtio" "${mod_dst}/" 2>/dev/null || true
        fi

        # Filesystem modules (squashfs, overlay, ext4)
        local fs_src="${ROOTFS_DIR}/lib/modules/${kver}/kernel/fs"
        local fs_dst="${initramfs_work}/lib/modules/${kver}/kernel/fs"
        mkdir -p "$fs_dst"

        for fs in squashfs overlay overlayfs ext4; do
            # Check if it's a directory
            if [ -d "${fs_src}/${fs}" ]; then
                cp -a "${fs_src}/${fs}" "${fs_dst}/" 2>/dev/null || true
                info "Copied ${fs} filesystem module (dir)"
            fi
            # Also check if it's a single .ko file (with optional compression)
            for kofile in "${fs_src}/${fs}.ko"*; do
                if [ -f "$kofile" ]; then
                    cp -a "$kofile" "${fs_dst}/" 2>/dev/null || true
                    info "Copied ${fs} filesystem module (file: $(basename "$kofile"))"
                fi
            done
        done

        # Copy ext4 dependencies from kernel/fs (jbd2, mbcache)
        for dep in jbd2 mbcache; do
            # Check if it's a directory
            if [ -d "${fs_src}/${dep}" ]; then
                cp -a "${fs_src}/${dep}" "${fs_dst}/" 2>/dev/null || true
                info "Copied ${dep} module (dir)"
            fi
            # Also check if it's a single .ko file
            for kofile in "${fs_src}/${dep}.ko"*; do
                if [ -f "$kofile" ]; then
                    cp -a "$kofile" "${fs_dst}/" 2>/dev/null || true
                    info "Copied ${dep} module (file)"
                fi
            done
        done

        # Copy crypto/lib modules needed by ext4 (crc16, crc32c, libcrc32c)
        local crypto_src="${ROOTFS_DIR}/lib/modules/${kver}/kernel/crypto"
        local crypto_dst="${initramfs_work}/lib/modules/${kver}/kernel/crypto"
        local lib_src="${ROOTFS_DIR}/lib/modules/${kver}/kernel/lib"
        local lib_dst="${initramfs_work}/lib/modules/${kver}/kernel/lib"

        mkdir -p "$crypto_dst" "$lib_dst"

        # Copy crc modules
        for mod in crc16 crc32c_generic libcrc32c crc32c_intel; do
            for src_dir in "$crypto_src" "$lib_src"; do
                if [ -f "${src_dir}/${mod}.ko"* ]; then
                    cp -a "${src_dir}/${mod}.ko"* "$(dirname "$src_dir" | sed "s|$ROOTFS_DIR|$initramfs_work|")/${mod}.ko"* 2>/dev/null || true
                    info "Copied ${mod} module"
                fi
            done
        done

        # Alternative: copy entire crypto and lib directories if they exist (simpler)
        if [ -d "$crypto_src" ]; then
            cp -a "$crypto_src" "$(dirname "$crypto_dst")/" 2>/dev/null || true
            info "Copied crypto modules"
        fi
        if [ -d "$lib_src" ]; then
            cp -a "$lib_src" "$(dirname "$lib_dst")/" 2>/dev/null || true
            info "Copied lib modules"
        fi

        # Copy modules.dep and related files
        for f in modules.dep modules.dep.bin modules.alias modules.alias.bin modules.symbols modules.symbols.bin modules.builtin modules.builtin.bin; do
            if [ -f "${ROOTFS_DIR}/lib/modules/${kver}/${f}" ]; then
                cp "${ROOTFS_DIR}/lib/modules/${kver}/${f}" "${initramfs_work}/lib/modules/${kver}/" 2>/dev/null || true
            fi
        done

        info "Kernel modules copied"
    else
        warn "No kernel modules found in rootfs"
    fi

    # Create initramfs cpio archive
    (cd "$initramfs_work" && find . | cpio -o -H newc 2>/dev/null | gzip -9) > "${boot_mount}/initramfs-custom"

    info "Custom initramfs created"

    # Cleanup
    rm -rf "$initramfs_work"
}

create_syslinux_config() {
    local boot_mount="$1"

    log "Creating syslinux configuration..."

    # Ensure syslinux directory exists
    mkdir -p "${boot_mount}/syslinux"

    if [ "$DEV_MODE" = "true" ]; then
        # Dev mode: boot directly with ext4 rootfs
        cat > "${boot_mount}/syslinux/syslinux.cfg" <<EOF
DEFAULT linux
PROMPT 0
TIMEOUT 30

LABEL linux
    LINUX /vmlinuz-virt
    INITRD /initramfs-custom
    APPEND root=/dev/sda2 rootfstype=ext4 rw console=tty0 console=ttyS0,115200n8 quiet
EOF
    else
        # Production mode: boot with SquashFS + overlay
        cat > "${boot_mount}/syslinux/syslinux.cfg" <<EOF
DEFAULT linux
PROMPT 0
TIMEOUT 30

LABEL linux
    LINUX /vmlinuz-virt
    INITRD /initramfs-custom
    APPEND root=/dev/sda2 data=/dev/sda3 console=tty0 console=ttyS0,115200n8 quiet
EOF
    fi

    # Also create a copy at root for compatibility
    cp "${boot_mount}/syslinux/syslinux.cfg" "${boot_mount}/syslinux.cfg"

    info "Syslinux configuration created"
}

install_rootfs() {
    log "Installing rootfs to image..."

    if [ "$DEV_MODE" = "true" ]; then
        install_rootfs_ext4
    else
        install_rootfs_squashfs
    fi
}

install_rootfs_ext4() {
    log "Copying rootfs to ext4 partition (dev mode)..."

    local rootfs_mount="${OUTPUT_DIR}/mnt_rootfs"
    mkdir -p "$rootfs_mount"

    # Mount rootfs partition
    mount "${LOOP_DEVICE}p2" "$rootfs_mount"
    CLEANUP_MOUNTS+=("$rootfs_mount")

    # Copy rootfs
    cp -a "${ROOTFS_DIR}/." "$rootfs_mount/"

    # Unmount
    sync
    umount "$rootfs_mount"
    CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$rootfs_mount}")

    info "Rootfs copied to ext4 partition"
}

install_rootfs_squashfs() {
    log "Creating SquashFS rootfs..."

    local squashfs_file="${OUTPUT_DIR}/rootfs.squashfs"

    # Create SquashFS image
    mksquashfs "$ROOTFS_DIR" "$squashfs_file" \
        -comp xz \
        -b 256K \
        -Xbcj x86 \
        -noappend \
        -no-progress

    local squashfs_size
    squashfs_size=$(du -h "$squashfs_file" | cut -f1)
    info "SquashFS created: $squashfs_size"

    # Check if SquashFS fits in partition
    local squashfs_size_mb
    squashfs_size_mb=$(du -m "$squashfs_file" | cut -f1)
    if [ "$squashfs_size_mb" -gt "$OS_PART_SIZE_MB" ]; then
        error "SquashFS (${squashfs_size_mb}MB) exceeds partition size (${OS_PART_SIZE_MB}MB)"
    fi

    # Write SquashFS directly to partition
    log "Writing SquashFS to partition..."
    dd if="$squashfs_file" of="${LOOP_DEVICE}p2" bs=4M status=progress

    # Cleanup temporary file
    rm -f "$squashfs_file"

    info "SquashFS installed to partition"
}

initialize_data_partition() {
    log "Initializing data partition..."

    local data_mount="${OUTPUT_DIR}/mnt_data"
    mkdir -p "$data_mount"

    # Mount data partition
    mount "${LOOP_DEVICE}p3" "$data_mount"
    CLEANUP_MOUNTS+=("$data_mount")

    # Create directory structure
    for dir in "${DATA_PARTITION_DIRS[@]}"; do
        mkdir -p "${data_mount}/${dir}"
    done

    # Set ownership for user home directory
    chown "${DEFAULT_USER_UID}:${DEFAULT_USER_GID}" "${data_mount}/home/${DEFAULT_USERNAME}"

    # Create a marker file
    echo "Data partition initialized $(date -u +%Y-%m-%d_%H:%M:%S_UTC)" > "${data_mount}/.initialized"

    # Unmount
    sync
    umount "$data_mount"
    CLEANUP_MOUNTS=("${CLEANUP_MOUNTS[@]/$data_mount}")

    info "Data partition initialized"
}

finalize_image() {
    log "Finalizing image..."

    # Detach loop device
    sync
    detach_loop_device "$LOOP_DEVICE"
    CLEANUP_LOOP=""

    # Calculate final image size
    local final_size
    final_size=$(du -h "$IMAGE_FILE" | cut -f1)

    info "Image finalized: $IMAGE_FILE ($final_size)"
}

main() {
    parse_arguments "$@"

    # Check root
    check_root

    log "Creating bootable disk image..."
    info "Rootfs: $ROOTFS_DIR"
    info "Output: $OUTPUT_DIR"
    info "Boot partition: ${BOOT_PART_SIZE_MB}MB"
    info "OS partition: ${OS_PART_SIZE_MB}MB"
    info "Data partition: ${DATA_PART_SIZE_MB}MB"
    info "Total size: ${TOTAL_SIZE_MB}MB"
    info "Dev mode: $DEV_MODE"

    # Setup cleanup trap
    trap cleanup EXIT

    # Build steps
    create_disk_image
    partition_image
    setup_loop
    format_partitions
    install_bootloader
    copy_kernel_and_initramfs
    install_rootfs
    initialize_data_partition
    finalize_image

    # Clear trap on success
    trap - EXIT

    echo ""
    echo "=========================================="
    log "Disk image created successfully!"
    echo "=========================================="
    echo ""
    echo "Image file: $IMAGE_FILE"
    echo "Size: $(du -h "$IMAGE_FILE" | cut -f1)"
    echo ""
    echo "Next step: Convert to VirtualBox format:"
    echo "  ${SCRIPT_DIR}/04-convert-to-vbox.sh \\"
    echo "    --input=$IMAGE_FILE \\"
    echo "    --vmname=alpine-demo"
    echo ""
}

main "$@"
