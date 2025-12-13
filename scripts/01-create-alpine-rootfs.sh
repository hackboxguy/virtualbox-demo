#!/bin/bash
#
# 01-create-alpine-rootfs.sh - Create base Alpine Linux rootfs
#
# This script downloads Alpine Linux minirootfs, extracts it, and installs
# all necessary base packages for the VirtualBox demo image.
#
# Usage:
#   sudo ./01-create-alpine-rootfs.sh --output=/tmp/alpine-build --version=1.0.0
#
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source configuration and libraries
source "${PROJECT_ROOT}/config.sh"
source "${SCRIPT_DIR}/lib.sh"
source "${SCRIPT_DIR}/chroot-helper.sh"

# Command line arguments
OUTPUT_DIR=""
VERSION=""
HOSTNAME="${DEFAULT_HOSTNAME}"
DEV_MODE=false
DEBUG_MODE=false

show_usage() {
    cat <<EOF
Create Alpine Linux rootfs for VirtualBox demo image

Usage:
  sudo $0 --output=DIR --version=VERSION [OPTIONS]

Required Arguments:
  --output=DIR          Output directory for rootfs
  --version=VERSION     Image version string

Optional Arguments:
  --hostname=NAME       VM hostname (default: ${DEFAULT_HOSTNAME})
  --dev-mode            Prepare for writable rootfs (development)
  --debug               Enable debug mode
  --help, -h            Show this help

EOF
    exit 0
}

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --output=*)     OUTPUT_DIR="${arg#*=}" ;;
            --version=*)    VERSION="${arg#*=}" ;;
            --hostname=*)   HOSTNAME="${arg#*=}" ;;
            --dev-mode)     DEV_MODE=true ;;
            --debug)        DEBUG_MODE=true ;;
            --help|-h)      show_usage ;;
            *)              error "Unknown argument: $arg" ;;
        esac
    done

    [ -z "$OUTPUT_DIR" ] && error "Missing required argument: --output"
    [ -z "$VERSION" ] && error "Missing required argument: --version"

    OUTPUT_DIR="$(to_absolute_path "$OUTPUT_DIR")"
    ROOTFS_DIR="${OUTPUT_DIR}/rootfs"
    DOWNLOAD_DIR="${OUTPUT_DIR}/downloads"
}

download_alpine() {
    log "Downloading Alpine Linux minirootfs..."

    mkdir -p "$DOWNLOAD_DIR"

    local tarball_name="alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
    local tarball_path="${DOWNLOAD_DIR}/${tarball_name}"

    download_file "$ALPINE_MINIROOTFS_URL" "$tarball_path"

    echo "$tarball_path"
}

extract_rootfs() {
    local tarball="$1"

    log "Extracting rootfs..."

    # Clean and create rootfs directory
    if [ -d "$ROOTFS_DIR" ]; then
        warn "Removing existing rootfs directory..."
        rm -rf "$ROOTFS_DIR"
    fi

    mkdir -p "$ROOTFS_DIR"

    # Extract tarball
    tar -xzf "$tarball" -C "$ROOTFS_DIR"

    # Verify extraction
    if [ ! -f "${ROOTFS_DIR}/etc/alpine-release" ]; then
        error "Failed to extract Alpine rootfs"
    fi

    info "Rootfs extracted: $(cat ${ROOTFS_DIR}/etc/alpine-release)"
}

configure_system() {
    log "Configuring system..."

    # Setup hostname
    echo "$HOSTNAME" > "${ROOTFS_DIR}/etc/hostname"

    # Setup hosts file
    cat > "${ROOTFS_DIR}/etc/hosts" <<EOF
127.0.0.1       localhost localhost.localdomain
127.0.1.1       ${HOSTNAME}
::1             localhost localhost.localdomain ipv6-localhost ipv6-loopback
EOF

    # Setup network interfaces (DHCP on eth0)
    mkdir -p "${ROOTFS_DIR}/etc/network"
    cat > "${ROOTFS_DIR}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # Setup fstab for overlay boot
    cat > "${ROOTFS_DIR}/etc/fstab" <<EOF
# /etc/fstab - Filesystem table
# Note: Most mounts are handled by initramfs overlay setup
#
# <device>  <mount>     <type>  <options>           <dump>  <pass>
none        /proc       proc    defaults            0       0
none        /sys        sysfs   defaults            0       0
none        /dev/shm    tmpfs   defaults            0       0
none        /dev/pts    devpts  gid=5,mode=620      0       0
# Data partition mounted by initramfs
/dev/sda3   /data       ext4    defaults,noatime    0       2
# Shared folder (mounted by guest additions)
shared      /mnt/shared vboxsf  defaults,nofail     0       0
EOF

    # Ensure /dev/pts directory exists
    mkdir -p "${ROOTFS_DIR}/dev/pts"

    # Setup timezone
    run_in_chroot "$ROOTFS_DIR" "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"

    # Setup shell for root
    run_in_chroot "$ROOTFS_DIR" "sed -i 's|/bin/ash|/bin/bash|' /etc/passwd" || true

    # Setup modules to load at boot (virtio for VirtualBox networking)
    cat > "${ROOTFS_DIR}/etc/modules" <<EOF
# Kernel modules to load at boot
virtio
virtio_pci
virtio_net
virtio_blk
EOF
    info "Configured kernel modules for boot"

    # Setup serial console (ttyS0) for VirtualBox
    # Always create a proper inittab with serial console support
    cat > "${ROOTFS_DIR}/etc/inittab" <<EOF
# /etc/inittab - BusyBox init configuration for VirtualBox Alpine

# System initialization
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Virtual terminals
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3

# Serial console (VirtualBox COM1)
# Use 'askfirst' instead of 'respawn' to avoid blocking boot when serial is not connected
ttyS0::askfirst:/sbin/getty -L 115200 ttyS0 vt100

# Shutdown handlers
::shutdown:/sbin/openrc shutdown
::ctrlaltdel:/sbin/reboot
::restart:/sbin/init
EOF
    info "Created inittab with serial console"

    info "System configuration complete"
}

install_base_packages() {
    log "Installing base packages..."

    # Configure APK repositories
    chroot_setup_repos "$ROOTFS_DIR" "$ALPINE_VERSION"

    # Update package cache
    chroot_apk_update "$ROOTFS_DIR"

    # Install base packages
    local packages="${ALPINE_BASE_PACKAGES[*]}"
    chroot_apk_add "$ROOTFS_DIR" "$packages"

    info "Base packages installed"
}

install_pip_packages() {
    if [ ${#PIP_PACKAGES[@]} -eq 0 ]; then
        debug_log "No pip packages to install"
        return 0
    fi

    log "Installing pip packages..."

    local packages="${PIP_PACKAGES[*]}"
    run_in_chroot "$ROOTFS_DIR" "pip3 install --no-cache-dir --break-system-packages $packages"

    info "Pip packages installed: $packages"
}

configure_user() {
    log "Creating user: ${DEFAULT_USERNAME}..."

    # Create user with specified UID/GID
    chroot_create_user "$ROOTFS_DIR" \
        "$DEFAULT_USERNAME" \
        "$DEFAULT_PASSWORD" \
        "$DEFAULT_USER_UID" \
        "$DEFAULT_USER_GID" \
        "/bin/bash"

    # Setup sudo
    chroot_setup_sudo "$ROOTFS_DIR"

    # Create user home directory structure
    mkdir -p "${ROOTFS_DIR}/home/${DEFAULT_USERNAME}"
    chown "${DEFAULT_USER_UID}:${DEFAULT_USER_GID}" "${ROOTFS_DIR}/home/${DEFAULT_USERNAME}"

    info "User ${DEFAULT_USERNAME} created with password: ${DEFAULT_PASSWORD}"
}

configure_ssh() {
    log "Configuring SSH..."

    # SSH configuration
    cat > "${ROOTFS_DIR}/etc/ssh/sshd_config" <<EOF
# SSH Server Configuration
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

# Authentication
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no

# Security
X11Forwarding no
# UsePAM not supported in Alpine (no PAM)
AllowTcpForwarding yes
GatewayPorts no

# Performance
UseDNS no

# Allow the default user
AllowUsers ${DEFAULT_USERNAME}
EOF

    chmod 644 "${ROOTFS_DIR}/etc/ssh/sshd_config"

    info "SSH configured"
}

install_webapps() {
    log "Installing web applications..."

    # Copy system management webapp
    local sysmgmt_src="${PROJECT_ROOT}/rootfs/opt/system-mgmt"
    local sysmgmt_dst="${ROOTFS_DIR}/opt/system-mgmt"

    if [ -d "$sysmgmt_src" ]; then
        mkdir -p "$sysmgmt_dst"
        cp -r "${sysmgmt_src}/." "$sysmgmt_dst/"
        chmod +x "${sysmgmt_dst}/app.py" 2>/dev/null || true
        info "System management webapp installed"
    else
        warn "System management webapp source not found: $sysmgmt_src"
    fi

    # Copy business app placeholder
    local bizapp_src="${PROJECT_ROOT}/rootfs/opt/business-app"
    local bizapp_dst="${ROOTFS_DIR}/opt/business-app"

    if [ -d "$bizapp_src" ]; then
        mkdir -p "$bizapp_dst"
        cp -r "${bizapp_src}/." "$bizapp_dst/"
        chmod +x "${bizapp_dst}/app.py" 2>/dev/null || true
        info "Business app placeholder installed"
    else
        warn "Business app source not found: $bizapp_src"
    fi

    # Copy app-manager service
    local appmgr_src="${PROJECT_ROOT}/rootfs/opt/app-manager"
    local appmgr_dst="${ROOTFS_DIR}/opt/app-manager"

    if [ -d "$appmgr_src" ]; then
        mkdir -p "$appmgr_dst"
        cp -r "${appmgr_src}/." "$appmgr_dst/"
        chmod +x "${appmgr_dst}/app-manager.py" 2>/dev/null || true
        info "App manager service installed"
    else
        warn "App manager source not found: $appmgr_src"
    fi
}

install_services() {
    log "Installing OpenRC services..."

    # Copy service scripts
    local initd_src="${PROJECT_ROOT}/rootfs/etc/init.d"
    local initd_dst="${ROOTFS_DIR}/etc/init.d"

    if [ -d "$initd_src" ]; then
        for service in "${initd_src}"/*; do
            if [ -f "$service" ]; then
                local svc_name
                svc_name=$(basename "$service")
                cp "$service" "${initd_dst}/${svc_name}"
                chmod +x "${initd_dst}/${svc_name}"
                debug_log "Installed service script: $svc_name"
            fi
        done
    fi

    # Copy service configs
    local confd_src="${PROJECT_ROOT}/rootfs/etc/conf.d"
    local confd_dst="${ROOTFS_DIR}/etc/conf.d"

    if [ -d "$confd_src" ]; then
        mkdir -p "$confd_dst"
        cp -r "${confd_src}/." "$confd_dst/"
    fi

    # Enable services
    for service in "${ENABLED_SERVICES[@]}"; do
        if [ -f "${ROOTFS_DIR}/etc/init.d/${service}" ]; then
            # hostname and devfs should be in boot runlevel, others in default
            if [ "$service" = "hostname" ] || [ "$service" = "devfs" ]; then
                chroot_enable_service "$ROOTFS_DIR" "$service" "boot"
            else
                chroot_enable_service "$ROOTFS_DIR" "$service" "default"
            fi
        else
            debug_log "Service not found, skipping: $service"
        fi
    done

    info "Services installed and enabled"
}

install_first_boot_scripts() {
    log "Installing first-boot scripts..."

    # Create local.d directory for first-boot scripts
    mkdir -p "${ROOTFS_DIR}/etc/local.d"

    # Copy first-boot scripts from rootfs overlay
    local locald_src="${PROJECT_ROOT}/rootfs/etc/local.d"
    if [ -d "$locald_src" ]; then
        cp -r "${locald_src}/." "${ROOTFS_DIR}/etc/local.d/"
        chmod +x "${ROOTFS_DIR}/etc/local.d/"*.start 2>/dev/null || true
    fi

    # Create first-boot script for SSH key generation
    cat > "${ROOTFS_DIR}/etc/local.d/first-boot.start" <<EOF
#!/bin/sh
# First boot initialization script

# Set hostname from /etc/hostname (fallback if hostname service didn't run)
if [ -f /etc/hostname ]; then
    hostname -F /etc/hostname 2>/dev/null || true
fi

# Mount /dev/pts for PTY support (needed for SSH)
if [ ! -d /dev/pts ] || ! mountpoint -q /dev/pts 2>/dev/null; then
    mkdir -p /dev/pts
    mount -t devpts devpts /dev/pts -o gid=5,mode=620 2>/dev/null || true
    echo "Mounted /dev/pts"
fi

# Mount /dev/shm if not mounted
if [ ! -d /dev/shm ] || ! mountpoint -q /dev/shm 2>/dev/null; then
    mkdir -p /dev/shm
    mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
fi

# Generate SSH host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
fi

# Initialize data partition directories if needed
if [ -d /data ]; then
    mkdir -p /data/overlay/upper /data/overlay/work
    mkdir -p /data/var /data/home

    # Create user home if it doesn't exist
    if [ ! -d /data/home/${DEFAULT_USERNAME} ]; then
        mkdir -p /data/home/${DEFAULT_USERNAME}
        chown ${DEFAULT_USER_UID}:${DEFAULT_USER_GID} /data/home/${DEFAULT_USERNAME}
    fi
fi

# Load virtio network module (for VirtualBox virtio NIC)
modprobe -a virtio virtio_pci virtio_net 2>/dev/null || true

# Load VirtualBox guest modules
modprobe -a vboxguest vboxsf 2>/dev/null || true

# Mount shared folder if configured
if [ -d /mnt/shared ]; then
    mount -t vboxsf shared /mnt/shared 2>/dev/null || true
fi

# Remove this script after first successful run
# (disabled to allow re-initialization after factory reset)
# rm -f /etc/local.d/first-boot.start

echo "First boot initialization complete"
EOF

    chmod +x "${ROOTFS_DIR}/etc/local.d/first-boot.start"

    info "First-boot scripts installed"
}

install_initramfs_files() {
    log "Installing initramfs files..."

    # Copy custom initramfs init script
    local initramfs_src="${PROJECT_ROOT}/initramfs"
    local initramfs_dst="${ROOTFS_DIR}/usr/share/mkinitfs"

    mkdir -p "$initramfs_dst"

    if [ -f "${initramfs_src}/init" ]; then
        cp "${initramfs_src}/init" "${initramfs_dst}/init-overlay"
        chmod +x "${initramfs_dst}/init-overlay"
        info "Custom initramfs init installed"
    else
        warn "Custom initramfs init not found"
    fi
}

create_dev_mode_init() {
    if [ "$DEV_MODE" != "true" ]; then
        return 0
    fi

    log "Creating dev-mode init script..."

    # Create a simple init script for dev mode (no overlay)
    cat > "${ROOTFS_DIR}/sbin/init-devmode" <<'EOF'
#!/bin/sh
# Dev-mode init - direct boot without overlay

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Mount data partition
mkdir -p /data
mount /dev/sda3 /data

# Create symlinks for persistent directories
if [ -d /data/var ]; then
    rm -rf /var
    ln -sf /data/var /var
fi

if [ -d /data/home ]; then
    rm -rf /home
    ln -sf /data/home /home
fi

# Continue to real init
exec /sbin/init
EOF

    chmod +x "${ROOTFS_DIR}/sbin/init-devmode"

    info "Dev-mode init script created"
}

write_version_info() {
    log "Writing version information..."

    write_version_file "${ROOTFS_DIR}/etc/image-version" "$VERSION" "base"

    # Also write Alpine version
    cat >> "${ROOTFS_DIR}/etc/image-version" <<EOF
ALPINE_VERSION=${ALPINE_VERSION}
EOF

    info "Version information written"
}

cleanup_rootfs() {
    log "Cleaning up rootfs..."

    # Clear APK cache
    rm -rf "${ROOTFS_DIR}/var/cache/apk/"*

    # Clear temporary files
    rm -rf "${ROOTFS_DIR}/tmp/"*

    # Calculate rootfs size
    local rootfs_size
    rootfs_size=$(du -sh "$ROOTFS_DIR" | cut -f1)
    info "Rootfs size: $rootfs_size"
}

main() {
    parse_arguments "$@"

    log "Creating Alpine Linux rootfs..."
    info "Output directory: $OUTPUT_DIR"
    info "Version: $VERSION"
    info "Hostname: $HOSTNAME"
    info "Alpine version: $ALPINE_VERSION"

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Download Alpine minirootfs
    local tarball
    tarball=$(download_alpine)

    # Extract rootfs
    extract_rootfs "$tarball"

    # Setup chroot environment
    setup_alpine_chroot "$ROOTFS_DIR"
    trap "teardown_alpine_chroot '$ROOTFS_DIR'" EXIT

    # Install packages first (provides ln, sed, and other tools)
    install_base_packages
    install_pip_packages

    # Now configure (requires tools from base packages)
    configure_system
    configure_user
    configure_ssh
    install_webapps
    install_services
    install_first_boot_scripts
    install_initramfs_files
    create_dev_mode_init
    write_version_info

    # Teardown chroot
    teardown_alpine_chroot "$ROOTFS_DIR"
    trap - EXIT

    # Final cleanup
    cleanup_rootfs

    log "Alpine rootfs created successfully!"
    info "Location: $ROOTFS_DIR"
}

main "$@"
