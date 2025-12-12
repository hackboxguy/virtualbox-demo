#!/bin/bash
# config.sh - Default configuration for VirtualBox Alpine image builder
# This file can be sourced to get default values

# Alpine Linux configuration
ALPINE_VERSION="${ALPINE_VERSION:-3.21}"
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

# Alpine minirootfs URL
ALPINE_MINIROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"

# Default partition sizes (in MB or with suffix M/G)
DEFAULT_BOOT_SIZE="64M"
DEFAULT_OS_PART_SIZE="500M"
DEFAULT_DATA_PART_SIZE="1024M"

# Default hostname
DEFAULT_HOSTNAME="alpine-vm"

# Default user configuration
DEFAULT_USERNAME="pi"
DEFAULT_PASSWORD="brb0x"
DEFAULT_USER_UID=1000
DEFAULT_USER_GID=1000

# Default VM configuration (for VirtualBox)
DEFAULT_VM_MEMORY=1024
DEFAULT_VM_CPUS=2
DEFAULT_VM_NAME="alpine-demo"

# Port forwarding defaults (host:guest)
DEFAULT_SSH_PORT="2222:22"
DEFAULT_SYSMGMT_PORT="8000:8000"
DEFAULT_BUSINESS_PORT="8001:8001"

# Base packages to install in Alpine (runtime)
ALPINE_BASE_PACKAGES=(
    # Core system
    "alpine-base"
    "linux-virt"
    "linux-firmware-none"

    # Shell and utilities
    "bash"
    "sudo"
    "shadow"
    "coreutils"
    "util-linux"
    "procps"

    # Networking
    "openssh"
    "dhcpcd"
    "iproute2"

    # Python and web packages
    "python3"
    "py3-pip"
    "py3-flask"
    "py3-pyserial"
    "py3-requests"

    # VirtualBox guest additions
    "virtualbox-guest-additions"
    "virtualbox-guest-additions-openrc"

    # Filesystem tools
    "squashfs-tools"
    "e2fsprogs"
    "dosfstools"

    # Boot
    "syslinux"
)

# Build dependencies (installed for package building, removed after)
ALPINE_BUILD_PACKAGES=(
    "build-base"
    "cmake"
    "make"
    "gcc"
    "g++"
    "git"
    "wget"
    "linux-headers"
)

# Image naming
IMAGE_NAME_PREFIX="alpine-vbox"

# Directory structure inside data partition
DATA_PARTITION_DIRS=(
    "overlay/upper"
    "overlay/work"
    "var"
    "home/${DEFAULT_USERNAME}"
    "shared"
)

# Services to enable by default
ENABLED_SERVICES=(
    "devfs"
    "hostname"
    "sshd"
    "dhcpcd"
    "local"
    "virtualbox-guest-additions"
    "system-mgmt"
    "business-app"
)

# Syslinux configuration template
SYSLINUX_CFG_TEMPLATE='DEFAULT linux
PROMPT 0
TIMEOUT 10

LABEL linux
    LINUX /vmlinuz-virt
    INITRD /initramfs-custom
    APPEND root=/dev/sda2 rootfstype=squashfs ro quiet
'

# Dev-mode syslinux configuration (writable rootfs)
SYSLINUX_CFG_DEVMODE='DEFAULT linux
PROMPT 0
TIMEOUT 10

LABEL linux
    LINUX /vmlinuz-virt
    INITRD /initramfs-custom
    APPEND root=/dev/sda2 rootfstype=ext4 rw init=/sbin/init-devmode quiet
'
