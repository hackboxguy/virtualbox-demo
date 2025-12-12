#!/bin/bash
#
# 02-build-packages.sh - Build and install packages from packages.txt
#
# This script processes the packages.txt file and builds/installs each
# package into the Alpine rootfs.
#
# Package list format (pipe-separated):
#   # Simple hook (custom script)
#   packages/my-hook.sh
#
#   # Git-based package: HOOK|REPO|TAG|DEST|DEPS|POST_CMDS
#   packages/generic-package-hook.sh|https://github.com/user/repo.git|v1.0|/opt/app|cmake,libfoo-dev|post_cmd
#
#   # Local source: HOOK|file:///path/to/source|local|DEST|DEPS|POST_CMDS
#   packages/generic-package-hook.sh|file:///path/to/source|local|/opt/app|deps
#
# Usage:
#   sudo ./02-build-packages.sh --rootfs=/path/to/rootfs --packages=packages.txt
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
ROOTFS_DIR=""
PACKAGES_FILE=""
VERSION=""
DEBUG_MODE=false
KEEP_BUILD_DEPS=false

# Package processing state
declare -a SETUP_HOOKS=()

show_usage() {
    cat <<EOF
Build and install packages from packages.txt

Usage:
  sudo $0 --rootfs=DIR --packages=FILE [OPTIONS]

Required Arguments:
  --rootfs=DIR          Path to Alpine rootfs directory
  --packages=FILE       Path to packages.txt file

Optional Arguments:
  --version=VERSION     Version string to write
  --debug               Enable debug mode
  --keep-build-deps     Keep build dependencies after install
  --help, -h            Show this help

Package List Format:
  # Simple hook (runs a custom script)
  packages/my-hook.sh

  # Parameterized hook (5 or 6 fields, pipe-separated)
  # HOOK_SCRIPT|GIT_REPO|GIT_TAG|INSTALL_DEST|DEP_LIST|POST_INSTALL_CMDS
  packages/generic-package-hook.sh|https://github.com/user/repo.git|v1.0|/opt/app|cmake,libfoo|systemctl enable app

  # Local source (use file:// URL)
  packages/generic-package-hook.sh|file:///path/to/source|local|/opt/app|cmake

EOF
    exit 0
}

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --rootfs=*)         ROOTFS_DIR="${arg#*=}" ;;
            --packages=*)       PACKAGES_FILE="${arg#*=}" ;;
            --version=*)        VERSION="${arg#*=}" ;;
            --debug)            DEBUG_MODE=true ;;
            --keep-build-deps)  KEEP_BUILD_DEPS=true ;;
            --help|-h)          show_usage ;;
            *)                  error "Unknown argument: $arg" ;;
        esac
    done

    [ -z "$ROOTFS_DIR" ] && error "Missing required argument: --rootfs"
    [ -z "$PACKAGES_FILE" ] && error "Missing required argument: --packages"

    ROOTFS_DIR="$(to_absolute_path "$ROOTFS_DIR")"
    PACKAGES_FILE="$(to_absolute_path "$PACKAGES_FILE")"

    validate_dir "$ROOTFS_DIR" "Rootfs directory"
    validate_file "$PACKAGES_FILE" "Packages file"
}

# Load hooks from packages file
load_packages_file() {
    log "Loading packages from: $PACKAGES_FILE"

    local line_num=0

    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))

        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Parse line: HOOK_SCRIPT[|GIT_REPO|GIT_TAG|INSTALL_DEST|DEP_LIST|POST_INSTALL_CMDS]
        IFS='|' read -r hook_script git_repo git_tag install_dest dep_list post_install_cmds <<< "$line"

        # Determine field count
        local field_count=1
        if [ -n "$git_repo" ]; then
            field_count=5
            [ -n "$post_install_cmds" ] && field_count=6
        fi

        # Normalize hook script path (relative to packages file directory)
        if [[ "$hook_script" != /* ]]; then
            local packages_dir
            packages_dir="$(dirname "$PACKAGES_FILE")"
            hook_script="${packages_dir}/${hook_script}"
        fi

        # Validate hook script exists
        if [ ! -f "$hook_script" ]; then
            error "Hook script not found at line $line_num: $hook_script"
        fi

        # For local sources, normalize the path
        if [ -n "$git_repo" ] && [[ "$git_repo" == file://* ]]; then
            local local_source="${git_repo#file://}"
            if [[ "$local_source" != /* ]]; then
                local packages_dir
                packages_dir="$(dirname "$PACKAGES_FILE")"
                local_source="${packages_dir}/${local_source}"
            fi
            if [ ! -d "$local_source" ]; then
                error "Local source not found at line $line_num: $local_source"
            fi
            git_repo="file://${local_source}"
        fi

        # Store the parsed hook
        if [ "$field_count" = "1" ]; then
            SETUP_HOOKS+=("$hook_script")
        elif [ "$field_count" = "6" ]; then
            SETUP_HOOKS+=("$hook_script|$git_repo|$git_tag|$install_dest|$dep_list|$post_install_cmds")
        else
            SETUP_HOOKS+=("$hook_script|$git_repo|$git_tag|$install_dest|$dep_list")
        fi

    done < "$PACKAGES_FILE"

    info "Loaded ${#SETUP_HOOKS[@]} package(s)"
}

# Copy local sources into chroot
copy_local_sources() {
    [ ${#SETUP_HOOKS[@]} -eq 0 ] && return 0

    log "Checking for local sources..."
    local sources_copied=0

    for hook_line in "${SETUP_HOOKS[@]}"; do
        IFS='|' read -r hook_script git_repo git_tag install_dest dep_list post_install_cmds <<< "$hook_line"

        # Skip if not parameterized or not a local source
        [ -z "$git_repo" ] && continue
        [[ "$git_repo" != file://* ]] && continue

        local local_source="${git_repo#file://}"
        local source_name
        source_name=$(basename "$local_source")

        # Create build-sources directory in chroot
        mkdir -p "${ROOTFS_DIR}/tmp/build-sources"

        log "Copying local source: $source_name"
        cp -r "$local_source" "${ROOTFS_DIR}/tmp/build-sources/${source_name}"

        sources_copied=$((sources_copied + 1))
    done

    if [ $sources_copied -gt 0 ]; then
        info "Copied $sources_copied local source(s)"
    fi
}

# Install build dependencies
install_build_deps() {
    log "Installing build dependencies..."

    local all_deps=""

    # Collect all dependencies from hooks
    for hook_line in "${SETUP_HOOKS[@]}"; do
        IFS='|' read -r hook_script git_repo git_tag install_dest dep_list post_install_cmds <<< "$hook_line"

        if [ -n "$dep_list" ]; then
            # Convert comma-separated to space-separated
            local deps
            deps=$(echo "$dep_list" | tr ',' ' ')
            all_deps="$all_deps $deps"
        fi
    done

    # Add standard build dependencies
    all_deps="$all_deps ${ALPINE_BUILD_PACKAGES[*]}"

    # Remove duplicates
    all_deps=$(echo "$all_deps" | tr ' ' '\n' | sort -u | tr '\n' ' ')

    if [ -n "$all_deps" ]; then
        chroot_apk_add "$ROOTFS_DIR" "$all_deps"
    fi
}

# Run setup hooks
run_setup_hooks() {
    [ ${#SETUP_HOOKS[@]} -eq 0 ] && info "No packages to build" && return 0

    log "Running ${#SETUP_HOOKS[@]} package hook(s)..."

    for i in "${!SETUP_HOOKS[@]}"; do
        local hook_line="${SETUP_HOOKS[$i]}"

        # Parse hook line
        IFS='|' read -r hook_script git_repo git_tag install_dest dep_list post_install_cmds <<< "$hook_line"

        local hook_name
        if [ -z "$git_repo" ]; then
            hook_name=$(basename "$hook_script" .sh)
            log "[$((i+1))/${#SETUP_HOOKS[@]}] Running: $hook_name (simple hook)"
        else
            local is_local=0
            [[ "$git_repo" == file://* ]] && is_local=1

            if [ $is_local -eq 1 ]; then
                local local_path="${git_repo#file://}"
                hook_name=$(basename "$local_path")
                log "[$((i+1))/${#SETUP_HOOKS[@]}] Building: $hook_name [LOCAL]"
            else
                hook_name=$(basename "$git_repo" .git)
                log "[$((i+1))/${#SETUP_HOOKS[@]}] Building: $hook_name (${git_tag})"
            fi

            # Export environment variables for the hook
            export HOOK_GIT_REPO="$git_repo"
            export HOOK_GIT_TAG="$git_tag"
            export HOOK_INSTALL_DEST="$install_dest"
            export HOOK_NAME="$hook_name"
            export HOOK_DEP_LIST="$dep_list"

            if [ $is_local -eq 1 ]; then
                export HOOK_LOCAL_SOURCE="/tmp/build-sources/${hook_name}"
            fi

            if [ -n "$post_install_cmds" ]; then
                export HOOK_POST_INSTALL_CMDS="$post_install_cmds"
            fi
        fi

        # Copy hook script to chroot
        local hook_basename
        hook_basename=$(basename "$hook_script")
        cp "$hook_script" "${ROOTFS_DIR}/tmp/${hook_basename}"
        chmod +x "${ROOTFS_DIR}/tmp/${hook_basename}"

        # Run hook in chroot
        run_in_chroot "$ROOTFS_DIR" "cd /tmp && ./${hook_basename}" || \
            error "Package hook failed: $hook_name"

        # Cleanup hook script
        rm -f "${ROOTFS_DIR}/tmp/${hook_basename}"

        # Unset environment variables
        unset HOOK_GIT_REPO HOOK_GIT_TAG HOOK_INSTALL_DEST HOOK_NAME
        unset HOOK_DEP_LIST HOOK_LOCAL_SOURCE HOOK_POST_INSTALL_CMDS

        info "[$((i+1))/${#SETUP_HOOKS[@]}] Completed: $hook_name"
    done

    log "All package hooks completed"
}

# Remove build dependencies
purge_build_deps() {
    if [ "$KEEP_BUILD_DEPS" = "true" ]; then
        warn "Keeping build dependencies (--keep-build-deps)"
        return 0
    fi

    log "Purging build dependencies..."

    local build_deps="${ALPINE_BUILD_PACKAGES[*]}"
    chroot_apk_del "$ROOTFS_DIR" "$build_deps"

    # Clean APK cache
    run_in_chroot "$ROOTFS_DIR" "apk cache clean 2>/dev/null || true"
    rm -rf "${ROOTFS_DIR}/var/cache/apk/"*

    info "Build dependencies purged"
}

# Cleanup build artifacts
cleanup_build() {
    log "Cleaning up build artifacts..."

    # Remove build sources
    rm -rf "${ROOTFS_DIR}/tmp/build-sources"

    # Remove any leftover build directories
    rm -rf "${ROOTFS_DIR}/tmp/"*-build
    rm -rf "${ROOTFS_DIR}/root/"*.tar.*

    info "Build cleanup complete"
}

main() {
    parse_arguments "$@"

    # Check root
    check_root

    log "Building packages..."
    info "Rootfs: $ROOTFS_DIR"
    info "Packages: $PACKAGES_FILE"

    # Load packages file
    load_packages_file

    if [ ${#SETUP_HOOKS[@]} -eq 0 ]; then
        info "No packages to build"
        exit 0
    fi

    # Setup chroot environment
    setup_alpine_chroot "$ROOTFS_DIR"
    trap "teardown_alpine_chroot '$ROOTFS_DIR'" EXIT

    # Copy local sources if any
    copy_local_sources

    # Install build dependencies
    install_build_deps

    # Run package hooks
    run_setup_hooks

    # Purge build dependencies
    purge_build_deps

    # Cleanup
    cleanup_build

    # Teardown chroot
    teardown_alpine_chroot "$ROOTFS_DIR"
    trap - EXIT

    # Write version if specified
    if [ -n "$VERSION" ]; then
        write_version_file "${ROOTFS_DIR}/etc/image-version" "$VERSION" "incremental"
    fi

    log "Package building complete!"
}

main "$@"
