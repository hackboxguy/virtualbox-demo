#!/bin/bash
#
# chroot-helper.sh - Alpine Linux chroot setup and teardown utilities
#
# This script provides functions for setting up and managing Alpine Linux
# chroot environments for cross-compilation and image customization.
#
# Usage:
#   source scripts/chroot-helper.sh
#   setup_alpine_chroot /path/to/rootfs
#   run_in_chroot /path/to/rootfs "apk update"
#   teardown_alpine_chroot /path/to/rootfs

set -e

# Source library if not already loaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${NC:-}" ]; then
    source "${SCRIPT_DIR}/lib.sh"
fi

# Track mounted filesystems for cleanup
declare -a CHROOT_MOUNTS=()

# Setup Alpine chroot environment
# Usage: setup_alpine_chroot <rootfs_path>
setup_alpine_chroot() {
    local rootfs="$1"

    if [ ! -d "$rootfs" ]; then
        error "Rootfs directory not found: $rootfs"
    fi

    log "Setting up chroot environment: $rootfs"

    # Mount pseudo-filesystems
    mount -t proc proc "${rootfs}/proc"
    CHROOT_MOUNTS+=("${rootfs}/proc")

    mount -t sysfs sys "${rootfs}/sys"
    CHROOT_MOUNTS+=("${rootfs}/sys")

    mount --bind /dev "${rootfs}/dev"
    CHROOT_MOUNTS+=("${rootfs}/dev")

    mount --bind /dev/pts "${rootfs}/dev/pts"
    CHROOT_MOUNTS+=("${rootfs}/dev/pts")

    # Setup DNS resolution
    if [ -f /etc/resolv.conf ]; then
        cp -L /etc/resolv.conf "${rootfs}/etc/resolv.conf"
    fi

    # Verify chroot works
    if ! chroot "$rootfs" /bin/sh -c "echo 'Chroot test successful'" >/dev/null 2>&1; then
        teardown_alpine_chroot "$rootfs"
        error "Chroot test failed for: $rootfs"
    fi

    info "Chroot environment ready"
}

# Teardown Alpine chroot environment
# Usage: teardown_alpine_chroot <rootfs_path>
teardown_alpine_chroot() {
    local rootfs="$1"

    log "Tearing down chroot environment: $rootfs"

    # Unmount in reverse order
    for ((i=${#CHROOT_MOUNTS[@]}-1; i>=0; i--)); do
        local mount_point="${CHROOT_MOUNTS[$i]}"
        if mountpoint -q "$mount_point" 2>/dev/null; then
            umount -l "$mount_point" 2>/dev/null || true
        fi
    done

    # Clear the mounts array
    CHROOT_MOUNTS=()

    # Additional cleanup for any remaining mounts
    umount -l "${rootfs}/dev/pts" 2>/dev/null || true
    umount -l "${rootfs}/dev" 2>/dev/null || true
    umount -l "${rootfs}/sys" 2>/dev/null || true
    umount -l "${rootfs}/proc" 2>/dev/null || true

    info "Chroot environment cleaned up"
}

# Run a command inside the chroot
# Usage: run_in_chroot <rootfs_path> <command> [args...]
run_in_chroot() {
    local rootfs="$1"
    shift
    local cmd="$*"

    debug_log "Chroot command: $cmd"
    chroot "$rootfs" /bin/sh -c "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; $cmd"
}

# Run a script inside the chroot
# Usage: run_script_in_chroot <rootfs_path> <script_path> [args...]
run_script_in_chroot() {
    local rootfs="$1"
    local script="$2"
    shift 2

    if [ ! -f "$script" ]; then
        error "Script not found: $script"
    fi

    # Copy script to chroot
    local script_name
    script_name=$(basename "$script")
    cp "$script" "${rootfs}/tmp/${script_name}"
    chmod +x "${rootfs}/tmp/${script_name}"

    # Execute script
    debug_log "Running script in chroot: $script_name"
    chroot "$rootfs" /bin/sh -c "/tmp/${script_name} $*"

    # Cleanup
    rm -f "${rootfs}/tmp/${script_name}"
}

# Install APK packages in chroot
# Usage: chroot_apk_add <rootfs_path> <package1> [package2] ...
chroot_apk_add() {
    local rootfs="$1"
    shift
    local packages="$*"

    log "Installing packages: $packages"
    run_in_chroot "$rootfs" "apk add --no-cache $packages"
}

# Remove APK packages from chroot
# Usage: chroot_apk_del <rootfs_path> <package1> [package2] ...
chroot_apk_del() {
    local rootfs="$1"
    shift
    local packages="$*"

    log "Removing packages: $packages"
    run_in_chroot "$rootfs" "apk del $packages" || true
}

# Update APK package cache in chroot
# Usage: chroot_apk_update <rootfs_path>
chroot_apk_update() {
    local rootfs="$1"

    log "Updating package cache..."
    run_in_chroot "$rootfs" "apk update"
}

# Enable a service in chroot (OpenRC)
# Usage: chroot_enable_service <rootfs_path> <service_name> [runlevel]
chroot_enable_service() {
    local rootfs="$1"
    local service="$2"
    local runlevel="${3:-default}"

    log "Enabling service: $service (runlevel: $runlevel)"
    run_in_chroot "$rootfs" "rc-update add $service $runlevel"
}

# Disable a service in chroot (OpenRC)
# Usage: chroot_disable_service <rootfs_path> <service_name> [runlevel]
chroot_disable_service() {
    local rootfs="$1"
    local service="$2"
    local runlevel="${3:-default}"

    log "Disabling service: $service"
    run_in_chroot "$rootfs" "rc-update del $service $runlevel" || true
}

# Create a user in chroot
# Usage: chroot_create_user <rootfs_path> <username> <password> <uid> <gid> [shell]
chroot_create_user() {
    local rootfs="$1"
    local username="$2"
    local password="$3"
    local uid="$4"
    local gid="$5"
    local shell="${6:-/bin/bash}"

    log "Creating user: $username (uid=$uid, gid=$gid)"

    # Create group if it doesn't exist
    run_in_chroot "$rootfs" "addgroup -g $gid $username 2>/dev/null || true"

    # Create user
    run_in_chroot "$rootfs" "adduser -D -u $uid -G $username -s $shell $username"

    # Set password
    run_in_chroot "$rootfs" "echo '${username}:${password}' | chpasswd"

    # Add to wheel group for sudo
    run_in_chroot "$rootfs" "addgroup $username wheel"

    info "User $username created"
}

# Setup sudo access for wheel group
# Usage: chroot_setup_sudo <rootfs_path>
chroot_setup_sudo() {
    local rootfs="$1"

    log "Configuring sudo for wheel group..."

    # Ensure sudoers.d directory exists
    mkdir -p "${rootfs}/etc/sudoers.d"

    # Allow wheel group to use sudo
    echo "%wheel ALL=(ALL) ALL" > "${rootfs}/etc/sudoers.d/wheel"
    chmod 440 "${rootfs}/etc/sudoers.d/wheel"

    info "Sudo configured"
}

# Copy files from host to chroot
# Usage: chroot_copy <rootfs_path> <source> <dest_in_chroot>
chroot_copy() {
    local rootfs="$1"
    local source="$2"
    local dest="$3"

    debug_log "Copying: $source -> ${rootfs}${dest}"
    cp -r "$source" "${rootfs}${dest}"
}

# Copy directory tree from host to chroot (preserves structure)
# Usage: chroot_copy_tree <rootfs_path> <source_dir> <dest_base>
chroot_copy_tree() {
    local rootfs="$1"
    local source_dir="$2"
    local dest_base="${3:-/}"

    debug_log "Copying tree: $source_dir -> ${rootfs}${dest_base}"
    cp -a "${source_dir}/." "${rootfs}${dest_base}/"
}

# Write a file inside chroot
# Usage: chroot_write_file <rootfs_path> <file_path> <content>
chroot_write_file() {
    local rootfs="$1"
    local file_path="$2"
    local content="$3"

    debug_log "Writing file: ${rootfs}${file_path}"
    mkdir -p "$(dirname "${rootfs}${file_path}")"
    echo "$content" > "${rootfs}${file_path}"
}

# Configure Alpine repositories
# Usage: chroot_setup_repos <rootfs_path> <alpine_version>
chroot_setup_repos() {
    local rootfs="$1"
    local version="$2"
    local mirror="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

    log "Configuring APK repositories for Alpine $version..."

    cat > "${rootfs}/etc/apk/repositories" <<EOF
${mirror}/v${version}/main
${mirror}/v${version}/community
EOF

    info "Repositories configured"
}

# Trap handler for cleanup on script exit
# Usage: setup_chroot_cleanup_trap <rootfs_path>
setup_chroot_cleanup_trap() {
    local rootfs="$1"

    trap "teardown_alpine_chroot '$rootfs'" EXIT ERR INT TERM
}

# Export functions for use in other scripts
export -f setup_alpine_chroot
export -f teardown_alpine_chroot
export -f run_in_chroot
export -f run_script_in_chroot
export -f chroot_apk_add
export -f chroot_apk_del
export -f chroot_apk_update
export -f chroot_enable_service
export -f chroot_disable_service
export -f chroot_create_user
export -f chroot_setup_sudo
export -f chroot_copy
export -f chroot_copy_tree
export -f chroot_write_file
export -f chroot_setup_repos
export -f setup_chroot_cleanup_trap
