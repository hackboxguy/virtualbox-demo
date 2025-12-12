#!/bin/bash
#
# build.sh - Main orchestrator for VirtualBox Alpine image builder
#
# Usage:
#   sudo ./build.sh --mode=base --output=/tmp/alpine-build --version=1.0.0
#   sudo ./build.sh --mode=incremental --output=/tmp/alpine-build --version=1.0.1 --packages=packages.txt
#
set -e

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source configuration and library
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/scripts/lib.sh"

# Script version
BUILDER_VERSION="1.0.0"

# Command line arguments (with defaults from config.sh)
MODE=""
OUTPUT_DIR=""
VERSION=""
OS_PART_SIZE="${DEFAULT_OS_PART_SIZE}"
DATA_PART_SIZE="${DEFAULT_DATA_PART_SIZE}"
HOSTNAME="${DEFAULT_HOSTNAME}"
PACKAGES_FILE=""
DEV_MODE=false
DEBUG_MODE=false

show_usage() {
    cat <<EOF
VirtualBox Alpine Image Builder v${BUILDER_VERSION}

Usage:
  sudo $0 --mode=MODE --output=DIR --version=VERSION [OPTIONS]

Required Arguments:
  --mode=MODE           Build mode: 'base' or 'incremental'
  --output=DIR          Output directory for build artifacts
  --version=VERSION     Image version string (e.g., "1.0.0")

Optional Arguments:
  --ospart=SIZE         Root partition size (default: ${DEFAULT_OS_PART_SIZE})
  --datapart=SIZE       Data partition size (default: ${DEFAULT_DATA_PART_SIZE})
  --hostname=NAME       VM hostname (default: ${DEFAULT_HOSTNAME})
  --packages=FILE       Package list file (default: packages.txt in project root)
  --dev-mode            Create writable rootfs (no squashfs, for development)
  --debug               Keep mounted on error for debugging
  --help, -h            Show this help

Partition Size Format:
  Sizes can be specified with suffixes: M (megabytes), G (gigabytes)
  Examples: 500M, 1G, 2048M

Build Modes:
  base        Create base Alpine rootfs with system packages and webapps
              Output: rootfs directory ready for customization

  incremental Build application packages from packages.txt on top of base
              Output: Complete rootfs with custom applications

Examples:
  # Stage 1: Create base image
  sudo $0 --mode=base --output=/tmp/alpine-build --version=1.0.0

  # Stage 2: Add custom packages
  sudo $0 --mode=incremental --output=/tmp/alpine-build --version=1.0.1 \\
    --packages=my-packages.txt

  # Create final disk image
  sudo ./scripts/03-create-image.sh --rootfs=/tmp/alpine-build/rootfs \\
    --output=/tmp/alpine-build --ospart=500M --datapart=1G

  # Convert to VirtualBox
  ./scripts/04-convert-to-vbox.sh --input=/tmp/alpine-build/alpine-vbox.raw \\
    --vmname=my-alpine-vm

Package List File Format (packages.txt):
  # Simple hook (custom script)
  packages/my-hook.sh

  # Git-based package: HOOK|REPO|TAG|DEST|DEPS|POST_CMDS
  packages/generic-package-hook.sh|https://github.com/user/repo.git|v1.0|/opt/app|cmake,libfoo-dev

  # Local source package
  packages/generic-package-hook.sh|file:///path/to/source|local|/opt/app|deps|post_cmd

EOF
    exit 0
}

parse_arguments() {
    [ $# -eq 0 ] && show_usage

    for arg in "$@"; do
        case "$arg" in
            --mode=*)       MODE="${arg#*=}" ;;
            --output=*)     OUTPUT_DIR="${arg#*=}" ;;
            --version=*)    VERSION="${arg#*=}" ;;
            --ospart=*)     OS_PART_SIZE="${arg#*=}" ;;
            --datapart=*)   DATA_PART_SIZE="${arg#*=}" ;;
            --hostname=*)   HOSTNAME="${arg#*=}" ;;
            --packages=*)   PACKAGES_FILE="${arg#*=}" ;;
            --dev-mode)     DEV_MODE=true ;;
            --debug)        DEBUG_MODE=true ;;
            --help|-h)      show_usage ;;
            *)              error "Unknown argument: $arg\nUse --help for usage" ;;
        esac
    done

    # Validate required arguments
    local missing=()
    [ -z "$MODE" ] && missing+=("--mode")
    [ -z "$OUTPUT_DIR" ] && missing+=("--output")
    [ -z "$VERSION" ] && missing+=("--version")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing required arguments: ${missing[*]}\nUse --help for usage"
    fi

    # Validate mode
    case "$MODE" in
        base|incremental) ;;
        *)
            error "Invalid --mode value: '$MODE'. Must be 'base' or 'incremental'"
            ;;
    esac

    # Convert to absolute paths
    OUTPUT_DIR="$(to_absolute_path "$OUTPUT_DIR")"

    # Set default packages file if not specified
    if [ -z "$PACKAGES_FILE" ]; then
        PACKAGES_FILE="${SCRIPT_DIR}/packages.txt"
    else
        PACKAGES_FILE="$(to_absolute_path "$PACKAGES_FILE")"
    fi

    # Validate packages file for incremental mode
    if [ "$MODE" = "incremental" ]; then
        if [ -f "$PACKAGES_FILE" ]; then
            info "Using packages file: $PACKAGES_FILE"
        else
            warn "Packages file not found: $PACKAGES_FILE"
            warn "Incremental build will skip package installation"
        fi
    fi

    # Parse partition sizes to MB
    OS_PART_SIZE_MB=$(parse_size_mb "$OS_PART_SIZE")
    DATA_PART_SIZE_MB=$(parse_size_mb "$DATA_PART_SIZE")

    # Export for sub-scripts
    export MODE OUTPUT_DIR VERSION OS_PART_SIZE_MB DATA_PART_SIZE_MB
    export HOSTNAME PACKAGES_FILE DEV_MODE DEBUG_MODE
    export SCRIPT_DIR
}

validate_environment() {
    log "Validating build environment..."

    # Check if running as root
    check_root

    # Check prerequisites
    check_prerequisites

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Check available disk space (need at least 2GB)
    local avail_mb
    avail_mb=$(df -BM "$OUTPUT_DIR" | tail -1 | awk '{print $4}' | sed 's/M//')
    if [ "$avail_mb" -lt 2048 ]; then
        warn "Low disk space: ${avail_mb}MB available"
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi

    log "Environment validation complete"
}

show_configuration() {
    echo ""
    echo "=========================================="
    echo "  VirtualBox Alpine Image Builder"
    echo "=========================================="
    echo ""
    show_config \
        "Mode" "$MODE" \
        "Output directory" "$OUTPUT_DIR" \
        "Version" "$VERSION" \
        "Hostname" "$HOSTNAME" \
        "OS partition" "${OS_PART_SIZE} (${OS_PART_SIZE_MB}MB)" \
        "Data partition" "${DATA_PART_SIZE} (${DATA_PART_SIZE_MB}MB)" \
        "Dev mode" "$DEV_MODE" \
        "Debug mode" "$DEBUG_MODE"

    if [ "$MODE" = "incremental" ] && [ -f "$PACKAGES_FILE" ]; then
        echo "  Packages file:      $PACKAGES_FILE"
    fi
    echo ""
}

run_base_build() {
    log "Starting BASE build..."

    # Run the base rootfs creation script
    "${SCRIPT_DIR}/scripts/01-create-alpine-rootfs.sh" \
        --output="$OUTPUT_DIR" \
        --version="$VERSION" \
        --hostname="$HOSTNAME" \
        $([ "$DEV_MODE" = true ] && echo "--dev-mode") \
        $([ "$DEBUG_MODE" = true ] && echo "--debug")

    log "Base build complete!"
    info "Rootfs created at: ${OUTPUT_DIR}/rootfs"
    info "Next step: Run with --mode=incremental to add packages"
    info "           Or run scripts/03-create-image.sh to create disk image"
}

run_incremental_build() {
    log "Starting INCREMENTAL build..."

    # Verify base rootfs exists
    local rootfs_dir="${OUTPUT_DIR}/rootfs"
    if [ ! -d "$rootfs_dir" ]; then
        error "Base rootfs not found at: $rootfs_dir\nRun with --mode=base first"
    fi

    # Run package building script
    if [ -f "$PACKAGES_FILE" ]; then
        "${SCRIPT_DIR}/scripts/02-build-packages.sh" \
            --rootfs="$rootfs_dir" \
            --packages="$PACKAGES_FILE" \
            --version="$VERSION" \
            $([ "$DEBUG_MODE" = true ] && echo "--debug")
    else
        info "No packages file found, skipping package installation"
    fi

    # Update version file
    write_version_file "${rootfs_dir}/etc/image-version" "$VERSION" "incremental"

    log "Incremental build complete!"
    info "Rootfs updated at: ${OUTPUT_DIR}/rootfs"
    info "Next step: Run scripts/03-create-image.sh to create disk image"
}

main() {
    parse_arguments "$@"
    show_configuration
    validate_environment

    case "$MODE" in
        base)
            run_base_build
            ;;
        incremental)
            run_incremental_build
            ;;
    esac

    echo ""
    echo "=========================================="
    log "Build completed successfully!"
    echo "=========================================="
    echo ""
    echo "To create the disk image:"
    echo "  sudo ${SCRIPT_DIR}/scripts/03-create-image.sh \\"
    echo "    --rootfs=${OUTPUT_DIR}/rootfs \\"
    echo "    --output=${OUTPUT_DIR} \\"
    echo "    --ospart=${OS_PART_SIZE} \\"
    echo "    --datapart=${DATA_PART_SIZE}"
    echo ""
    echo "To convert to VirtualBox VM:"
    echo "  ${SCRIPT_DIR}/scripts/04-convert-to-vbox.sh \\"
    echo "    --input=${OUTPUT_DIR}/${IMAGE_NAME_PREFIX}.raw \\"
    echo "    --vmname=${HOSTNAME}"
    echo ""
}

main "$@"
