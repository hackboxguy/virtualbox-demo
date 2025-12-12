#!/bin/bash
#
# install-to-image.sh - Helper script for installing packages to VirtualBox image
#
# This script mounts a raw disk image and installs files to the data partition.
# It can be used with CMake to deploy applications to the image.
#
# Usage:
#   sudo ./install-to-image.sh --image=IMAGE.raw --source=DIR --dest=/opt/myapp
#
# CMake Integration:
#   add_custom_target(install-to-image
#       COMMAND sudo ${CMAKE_SOURCE_DIR}/tools/install-to-image.sh
#               --image=/path/to/image.raw
#               --source=${CMAKE_INSTALL_PREFIX}
#               --dest=/opt/myapp
#       DEPENDS install
#   )
#
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source libraries
source "${PROJECT_ROOT}/scripts/lib.sh"

# Command line arguments
IMAGE_FILE=""
SOURCE_DIR=""
DEST_PATH=""
PARTITION=3  # Data partition by default

show_usage() {
    cat <<EOF
Install files to VirtualBox disk image

Usage:
  sudo $0 --image=IMAGE.raw --source=DIR --dest=PATH [OPTIONS]

Required Arguments:
  --image=FILE          Path to raw disk image
  --source=DIR          Source directory to copy
  --dest=PATH           Destination path inside image

Optional Arguments:
  --partition=N         Partition number (default: 3 for data partition)
  --help, -h            Show this help

Examples:
  sudo $0 --image=alpine-vbox.raw --source=./build/install --dest=/opt/myapp
  sudo $0 --image=alpine-vbox.raw --source=./config --dest=/etc/myapp --partition=2

EOF
    exit 0
}

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --image=*)      IMAGE_FILE="${arg#*=}" ;;
            --source=*)     SOURCE_DIR="${arg#*=}" ;;
            --dest=*)       DEST_PATH="${arg#*=}" ;;
            --partition=*)  PARTITION="${arg#*=}" ;;
            --help|-h)      show_usage ;;
            *)              error "Unknown argument: $arg" ;;
        esac
    done

    [ -z "$IMAGE_FILE" ] && error "Missing required argument: --image"
    [ -z "$SOURCE_DIR" ] && error "Missing required argument: --source"
    [ -z "$DEST_PATH" ] && error "Missing required argument: --dest"

    IMAGE_FILE="$(to_absolute_path "$IMAGE_FILE")"
    SOURCE_DIR="$(to_absolute_path "$SOURCE_DIR")"

    validate_file "$IMAGE_FILE" "Disk image"
    validate_dir "$SOURCE_DIR" "Source directory"
}

main() {
    parse_arguments "$@"

    check_root

    log "Installing to image..."
    info "Image: $IMAGE_FILE"
    info "Source: $SOURCE_DIR"
    info "Destination: $DEST_PATH"
    info "Partition: $PARTITION"

    # Setup loop device
    local loop
    loop=$(setup_loop_device "$IMAGE_FILE")
    trap "detach_loop_device '$loop'" EXIT

    # Mount partition
    local mount_point="/tmp/install-to-image-$$"
    mkdir -p "$mount_point"
    mount "${loop}p${PARTITION}" "$mount_point"
    trap "umount '$mount_point'; rmdir '$mount_point'; detach_loop_device '$loop'" EXIT

    # Create destination directory
    local full_dest="${mount_point}${DEST_PATH}"
    mkdir -p "$full_dest"

    # Copy files
    log "Copying files..."
    cp -av "${SOURCE_DIR}/." "$full_dest/"

    # Set ownership (default user uid/gid 1000)
    chown -R 1000:1000 "$full_dest"

    # Sync and unmount
    sync
    umount "$mount_point"
    rmdir "$mount_point"
    detach_loop_device "$loop"
    trap - EXIT

    log "Installation complete!"
    info "Files installed to ${DEST_PATH} in image"
}

main "$@"
