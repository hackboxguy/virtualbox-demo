#!/bin/sh
#
# generic-package-hook.sh - Generic CMake package builder for Alpine
#
# This script builds and installs a CMake-based package inside the chroot.
# It is designed to be called from 02-build-packages.sh with environment
# variables set.
#
# Environment variables (set by caller):
#   HOOK_NAME           - Package name (extracted from repo URL or path)
#   HOOK_GIT_REPO       - Git repository URL or file:// path for local sources
#   HOOK_GIT_TAG        - Git branch/tag/commit (ignored for local sources)
#   HOOK_INSTALL_DEST   - Installation destination path
#   HOOK_DEP_LIST       - Comma-separated package list (optional)
#   HOOK_LOCAL_SOURCE   - Path to local source in chroot (set for file:// sources)
#   HOOK_POST_INSTALL_CMDS - Semicolon-separated post-install commands (optional)
#
# Usage (called automatically by 02-build-packages.sh):
#   HOOK_NAME=myapp HOOK_GIT_REPO=https://... HOOK_INSTALL_DEST=/opt/myapp ./generic-package-hook.sh
#
set -e

echo "======================================"
echo "  ${HOOK_NAME:-Package} Build Hook"
echo "======================================"
echo ""

# Validate required variables
if [ -z "$HOOK_NAME" ]; then
    echo "ERROR: HOOK_NAME not set"
    exit 1
fi

if [ -z "$HOOK_INSTALL_DEST" ]; then
    echo "ERROR: HOOK_INSTALL_DEST not set"
    exit 1
fi

echo "Package:     $HOOK_NAME"
echo "Destination: $HOOK_INSTALL_DEST"
echo ""

# Step 1: Install dependencies (if specified)
echo "[1/5] Checking dependencies..."
if [ -n "$HOOK_DEP_LIST" ]; then
    DEPS_SPACE=$(echo "$HOOK_DEP_LIST" | tr ',' ' ')
    echo "Installing: $DEPS_SPACE"
    apk add --no-cache $DEPS_SPACE
else
    echo "No additional dependencies"
fi

# Step 2: Get source code
echo ""
echo "[2/5] Obtaining source code..."
cd /tmp

if [ -n "$HOOK_LOCAL_SOURCE" ]; then
    # Using local source (already copied into chroot)
    echo "Using local source: $HOOK_LOCAL_SOURCE"
    if [ ! -d "$HOOK_LOCAL_SOURCE" ]; then
        echo "ERROR: Local source not found: $HOOK_LOCAL_SOURCE"
        exit 1
    fi
    cd "$HOOK_LOCAL_SOURCE"
else
    # Clone from Git repository
    if [ -z "$HOOK_GIT_REPO" ]; then
        echo "ERROR: Neither HOOK_LOCAL_SOURCE nor HOOK_GIT_REPO is set"
        exit 1
    fi

    echo "Cloning: $HOOK_GIT_REPO"
    git clone --depth=1 "$HOOK_GIT_REPO" "$HOOK_NAME"
    cd "$HOOK_NAME"

    # Checkout specific tag/branch if specified
    if [ -n "$HOOK_GIT_TAG" ] && [ "$HOOK_GIT_TAG" != "local" ]; then
        echo "Checking out: $HOOK_GIT_TAG"
        git fetch --depth=1 origin "$HOOK_GIT_TAG" 2>/dev/null || true
        git checkout "$HOOK_GIT_TAG" 2>/dev/null || \
            git checkout -b "$HOOK_GIT_TAG" "origin/$HOOK_GIT_TAG" 2>/dev/null || true
    fi
fi

# Step 3: Configure with CMake
echo ""
echo "[3/5] Configuring CMake..."
mkdir -p build
cd build

cmake \
    -DCMAKE_INSTALL_PREFIX="$HOOK_INSTALL_DEST" \
    -DCMAKE_BUILD_TYPE=Release \
    .. 2>&1 | tail -20

# Step 4: Build
echo ""
echo "[4/5] Building..."
NPROC=$(nproc 2>/dev/null || echo 1)
make -j"$NPROC" 2>&1 | tail -30

# Step 5: Install
echo ""
echo "[5/5] Installing to $HOOK_INSTALL_DEST..."
make install 2>&1 | tail -20

# Set ownership (default user is uid/gid 1000)
if [ -d "$HOOK_INSTALL_DEST" ]; then
    chown -R 1000:1000 "$HOOK_INSTALL_DEST"
fi

# Run post-install commands
if [ -n "$HOOK_POST_INSTALL_CMDS" ]; then
    echo ""
    echo "Running post-install commands..."
    echo "Commands: $HOOK_POST_INSTALL_CMDS"

    # Execute semicolon-separated commands
    eval "$HOOK_POST_INSTALL_CMDS" || {
        echo "ERROR: Post-install commands failed!"
        exit 1
    }
    echo "Post-install commands completed"
fi

# Cleanup source
echo ""
echo "Cleaning up..."
cd /
if [ -n "$HOOK_LOCAL_SOURCE" ]; then
    rm -rf "$HOOK_LOCAL_SOURCE"
else
    rm -rf "/tmp/$HOOK_NAME"
fi

echo ""
echo "======================================"
echo "  $HOOK_NAME Build Complete"
echo "======================================"
echo "Installed to: $HOOK_INSTALL_DEST"
echo ""
