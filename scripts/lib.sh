#!/bin/bash
# lib.sh - Shared functions for VirtualBox Alpine image builder
# This file is sourced by other scripts

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global error flag for cleanup trap
ERROR_OCCURRED=0

# Logging functions - all output to stderr to avoid interfering with function returns
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    ERROR_OCCURRED=1
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

debug_log() {
    [ "${DEBUG_MODE:-false}" = "true" ] && echo -e "${CYAN}[DEBUG]${NC} $1" >&2 || true
}

# Parse size string (e.g., "500M", "1G", "1024") to bytes
# Returns size in megabytes
parse_size_mb() {
    local size="$1"
    local num="${size%[MmGgKk]*}"
    local suffix="${size##*[0-9]}"

    case "${suffix^^}" in
        G) echo $((num * 1024)) ;;
        M) echo "$num" ;;
        K) echo $((num / 1024)) ;;
        "") echo "$num" ;;  # Assume MB if no suffix
        *) error "Invalid size suffix: $suffix (use M, G, or K)" ;;
    esac
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root (use sudo)"
    fi
}

# Check if a command exists
check_command() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if ! command -v "$cmd" &>/dev/null; then
        error "Command '$cmd' not found. Install with: sudo pacman -S $pkg"
    fi
}

# Check all prerequisites for the build
check_prerequisites() {
    log "Checking prerequisites..."

    local missing=()

    # Required tools and their packages
    declare -A tools=(
        ["parted"]="parted"
        ["mkfs.vfat"]="dosfstools"
        ["mkfs.ext4"]="e2fsprogs"
        ["mksquashfs"]="squashfs-tools"
        ["syslinux"]="syslinux"
        ["wget"]="wget"
        ["losetup"]="util-linux"
    )

    for cmd in "${!tools[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("${tools[$cmd]}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        # Remove duplicates
        local unique_missing=($(echo "${missing[@]}" | tr ' ' '\n' | sort -u))
        error "Missing packages. Install with:\n  sudo pacman -S ${unique_missing[*]}"
    fi

    info "All prerequisites satisfied"
}

# Setup a loop device for an image file
# Usage: setup_loop_device <image_file>
# Returns: loop device path (e.g., /dev/loop0)
setup_loop_device() {
    local image="$1"
    local loop

    loop=$(losetup -f --show -P "$image") || error "Failed to setup loop device for $image"
    sleep 1
    partprobe "$loop" 2>/dev/null || true
    sleep 1

    echo "$loop"
}

# Detach a loop device
# Usage: detach_loop_device <loop_device>
detach_loop_device() {
    local loop="$1"

    if [ -n "$loop" ] && [ -e "$loop" ]; then
        sync
        losetup -d "$loop" 2>/dev/null || true
    fi
}

# Mount a partition
# Usage: mount_partition <device> <mountpoint> [options]
mount_partition() {
    local device="$1"
    local mountpoint="$2"
    local options="${3:-}"

    mkdir -p "$mountpoint"

    if [ -n "$options" ]; then
        mount -o "$options" "$device" "$mountpoint" || error "Failed to mount $device to $mountpoint"
    else
        mount "$device" "$mountpoint" || error "Failed to mount $device to $mountpoint"
    fi
}

# Unmount a mountpoint (with lazy unmount fallback)
# Usage: unmount_safe <mountpoint>
unmount_safe() {
    local mountpoint="$1"

    if mountpoint -q "$mountpoint" 2>/dev/null; then
        umount "$mountpoint" 2>/dev/null || umount -l "$mountpoint" 2>/dev/null || true
    fi
}

# Cleanup function for trap
# Usage: Set CLEANUP_MOUNTS array and CLEANUP_LOOP before calling
cleanup_on_exit() {
    local exit_code=$?

    if [ "$ERROR_OCCURRED" -eq 1 ]; then
        exit_code=1
    fi

    # If debug mode and error, keep mounted
    if [ "${DEBUG_MODE:-false}" = "true" ] && [ $exit_code -ne 0 ]; then
        warn "Debug mode: Keeping mounts for inspection"
        warn "Cleanup manually when done"
        return $exit_code
    fi

    log "Cleaning up..."

    # Unmount in reverse order
    if [ -n "${CLEANUP_MOUNTS:-}" ]; then
        for ((i=${#CLEANUP_MOUNTS[@]}-1; i>=0; i--)); do
            unmount_safe "${CLEANUP_MOUNTS[$i]}"
        done
    fi

    # Detach loop device
    if [ -n "${CLEANUP_LOOP:-}" ]; then
        detach_loop_device "$CLEANUP_LOOP"
    fi

    return $exit_code
}

# Download a file if it doesn't exist
# Usage: download_file <url> <output_path>
download_file() {
    local url="$1"
    local output="$2"

    if [ -f "$output" ]; then
        info "Using cached: $(basename "$output")"
        return 0
    fi

    log "Downloading: $(basename "$output")"
    wget -q --show-progress -O "$output" "$url" || error "Failed to download $url"
}

# Convert path to absolute path
# Usage: to_absolute_path <path>
to_absolute_path() {
    local path="$1"

    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        echo "$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")"
    fi
}

# Validate that a file exists
# Usage: validate_file <path> <description>
validate_file() {
    local path="$1"
    local desc="${2:-File}"

    if [ ! -f "$path" ]; then
        error "$desc not found: $path"
    fi
}

# Validate that a directory exists
# Usage: validate_dir <path> <description>
validate_dir() {
    local path="$1"
    local desc="${2:-Directory}"

    if [ ! -d "$path" ]; then
        error "$desc not found: $path"
    fi
}

# Get the script's directory (where lib.sh is located)
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    while [ -L "$source" ]; do
        local dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ $source != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}

# Get the project root directory (parent of scripts/)
get_project_root() {
    local script_dir
    script_dir="$(get_script_dir)"
    dirname "$script_dir"
}

# Write version info to a file
# Usage: write_version_file <output_path> <version> <mode>
write_version_file() {
    local output="$1"
    local version="$2"
    local mode="$3"

    cat > "$output" <<EOF
VERSION=$version
BUILD_MODE=$mode
BUILD_DATE=$(date -u +%Y-%m-%d_%H:%M:%S_UTC)
BUILD_HOST=$(hostname)
EOF

    info "Version file written: $output"
}

# Display a configuration summary
# Usage: show_config <key1> <val1> <key2> <val2> ...
show_config() {
    info "Configuration:"
    while [ $# -ge 2 ]; do
        local key="$1"
        local val="$2"
        printf "  %-20s %s\n" "$key:" "$val" >&2
        shift 2
    done
    echo "" >&2
}
