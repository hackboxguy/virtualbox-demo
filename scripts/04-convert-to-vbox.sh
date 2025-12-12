#!/bin/bash
#
# 04-convert-to-vbox.sh - Convert raw disk image to VirtualBox VM
#
# This script converts the raw disk image to VDI format and creates
# a VirtualBox VM with appropriate settings.
#
# Usage:
#   ./04-convert-to-vbox.sh --input=/path/to/image.raw --vmname=alpine-demo
#
set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source configuration and libraries
source "${PROJECT_ROOT}/config.sh"
source "${SCRIPT_DIR}/lib.sh"

# Command line arguments
INPUT_IMAGE=""
VM_NAME="${DEFAULT_VM_NAME}"
VM_MEMORY="${DEFAULT_VM_MEMORY}"
VM_CPUS="${DEFAULT_VM_CPUS}"
OUTPUT_DIR=""
FORCE=false
ENABLE_SERIAL=false
EXPORT_OVA=false

# Port forwarding
SSH_HOST_PORT="${DEFAULT_SSH_PORT%%:*}"
SSH_GUEST_PORT="${DEFAULT_SSH_PORT##*:}"
SYSMGMT_HOST_PORT="${DEFAULT_SYSMGMT_PORT%%:*}"
SYSMGMT_GUEST_PORT="${DEFAULT_SYSMGMT_PORT##*:}"
BUSINESS_HOST_PORT="${DEFAULT_BUSINESS_PORT%%:*}"
BUSINESS_GUEST_PORT="${DEFAULT_BUSINESS_PORT##*:}"

show_usage() {
    cat <<EOF
Convert raw disk image to VirtualBox VM

Usage:
  $0 --input=IMAGE.raw --vmname=NAME [OPTIONS]

Required Arguments:
  --input=FILE          Path to raw disk image (.raw)
  --vmname=NAME         Name for the VirtualBox VM

Optional Arguments:
  --output=DIR          Output directory for VDI (default: same as input)
  --memory=MB           VM memory in MB (default: ${DEFAULT_VM_MEMORY})
  --cpus=N              Number of CPUs (default: ${DEFAULT_VM_CPUS})
  --ssh-port=HOST:GUEST SSH port forwarding (default: ${DEFAULT_SSH_PORT})
  --serial              Enable serial console (Linux host only)
  --export-ova          Also export as portable OVA file
  --force               Overwrite existing VM
  --help, -h            Show this help

Port Forwarding (default):
  SSH:          ${DEFAULT_SSH_PORT}
  System Mgmt:  ${DEFAULT_SYSMGMT_PORT}
  Business App: ${DEFAULT_BUSINESS_PORT}

Examples:
  $0 --input=./alpine-vbox.raw --vmname=alpine-demo
  $0 --input=./alpine-vbox.raw --vmname=my-vm --memory=2048 --cpus=4

EOF
    exit 0
}

parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --input=*)      INPUT_IMAGE="${arg#*=}" ;;
            --vmname=*)     VM_NAME="${arg#*=}" ;;
            --output=*)     OUTPUT_DIR="${arg#*=}" ;;
            --memory=*)     VM_MEMORY="${arg#*=}" ;;
            --cpus=*)       VM_CPUS="${arg#*=}" ;;
            --ssh-port=*)
                SSH_HOST_PORT="${arg#*=}"
                SSH_HOST_PORT="${SSH_HOST_PORT%%:*}"
                SSH_GUEST_PORT="${arg#*:}"
                ;;
            --serial)       ENABLE_SERIAL=true ;;
            --export-ova)   EXPORT_OVA=true ;;
            --force)        FORCE=true ;;
            --help|-h)      show_usage ;;
            *)              error "Unknown argument: $arg" ;;
        esac
    done

    [ -z "$INPUT_IMAGE" ] && error "Missing required argument: --input"
    [ -z "$VM_NAME" ] && error "Missing required argument: --vmname"

    INPUT_IMAGE="$(to_absolute_path "$INPUT_IMAGE")"
    validate_file "$INPUT_IMAGE" "Input image"

    # Set output directory
    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$(dirname "$INPUT_IMAGE")"
    else
        OUTPUT_DIR="$(to_absolute_path "$OUTPUT_DIR")"
    fi
}

check_vbox() {
    log "Checking VirtualBox installation..."

    if ! command -v VBoxManage &>/dev/null; then
        error "VBoxManage not found. Install VirtualBox:\n  sudo pacman -S virtualbox"
    fi

    local vbox_version
    vbox_version=$(VBoxManage --version 2>&1 | grep -v "^WARNING" | head -1)
    info "VirtualBox version: $vbox_version"

    # Check if kernel module is loaded (warning only)
    if ! lsmod | grep -q vboxdrv; then
        warn "VirtualBox kernel module (vboxdrv) is not loaded"
        warn "You can still create the VM, but won't be able to start it"
        warn "To fix: sudo modprobe vboxdrv (or run sudo /sbin/vboxconfig)"
    fi
}

check_existing_vm() {
    log "Checking for existing VM: $VM_NAME"

    if VBoxManage showvminfo "$VM_NAME" 2>&1 | grep -v "^WARNING" | grep -q "Name:"; then
        if [ "$FORCE" = "true" ]; then
            warn "VM '$VM_NAME' exists, removing..."
            VBoxManage unregistervm "$VM_NAME" --delete &>/dev/null || true
        else
            error "VM '$VM_NAME' already exists. Use --force to overwrite."
        fi
    fi
}

convert_to_vdi() {
    log "Converting raw image to VDI..."

    local vdi_file="${OUTPUT_DIR}/${VM_NAME}.vdi"

    # Remove existing VDI
    rm -f "$vdi_file"

    # Check file permissions - raw image might be owned by root
    if [ ! -r "$INPUT_IMAGE" ]; then
        error "Cannot read input image: $INPUT_IMAGE\nTry: sudo chown \$USER:$USER $INPUT_IMAGE"
    fi

    # Convert raw to VDI (suppress VBoxManage warnings)
    if ! VBoxManage convertfromraw "$INPUT_IMAGE" "$vdi_file" --format VDI &>/dev/null; then
        error "Failed to convert image to VDI. Check permissions on:\n  $INPUT_IMAGE\n  $OUTPUT_DIR"
    fi

    if [ ! -f "$vdi_file" ]; then
        error "VDI file was not created: $vdi_file"
    fi

    local vdi_size
    vdi_size=$(du -h "$vdi_file" | cut -f1)
    info "VDI created: $vdi_file ($vdi_size)"

    echo "$vdi_file"
}

create_vm() {
    local vdi_file="$1"

    log "Creating VirtualBox VM: $VM_NAME"

    # Create VM (suppress warnings - they go to stdout)
    VBoxManage createvm \
        --name "$VM_NAME" \
        --ostype "Linux_64" \
        --register &>/dev/null

    info "VM created"
}

configure_vm() {
    local vdi_file="$1"

    log "Configuring VM..."

    # Basic settings (suppress warnings - they go to stdout, not stderr)
    VBoxManage modifyvm "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --cpus "$VM_CPUS" \
        --vram 16 \
        --acpi on \
        --ioapic on \
        --rtcuseutc on \
        --boot1 disk \
        --boot2 none \
        --boot3 none \
        --boot4 none &>/dev/null

    info "Memory: ${VM_MEMORY}MB, CPUs: ${VM_CPUS}"

    # Network: NAT with port forwarding
    # Use virtio for best performance - Alpine linux-virt kernel includes virtio_net
    VBoxManage modifyvm "$VM_NAME" \
        --nic1 nat \
        --nictype1 virtio &>/dev/null

    # Add port forwarding rules
    VBoxManage modifyvm "$VM_NAME" \
        --natpf1 "ssh,tcp,,${SSH_HOST_PORT},,${SSH_GUEST_PORT}" &>/dev/null
    VBoxManage modifyvm "$VM_NAME" \
        --natpf1 "sysmgmt,tcp,,${SYSMGMT_HOST_PORT},,${SYSMGMT_GUEST_PORT}" &>/dev/null
    VBoxManage modifyvm "$VM_NAME" \
        --natpf1 "business,tcp,,${BUSINESS_HOST_PORT},,${BUSINESS_GUEST_PORT}" &>/dev/null

    info "Network: NAT with port forwarding"
    info "  SSH:          localhost:${SSH_HOST_PORT} -> VM:${SSH_GUEST_PORT}"
    info "  System Mgmt:  localhost:${SYSMGMT_HOST_PORT} -> VM:${SYSMGMT_GUEST_PORT}"
    info "  Business App: localhost:${BUSINESS_HOST_PORT} -> VM:${BUSINESS_GUEST_PORT}"

    # Serial port (for console access) - only on Linux with --serial flag
    # Serial ports with Unix socket paths don't work on Windows/macOS
    if [ "$ENABLE_SERIAL" = "true" ]; then
        VBoxManage modifyvm "$VM_NAME" \
            --uart1 0x3F8 4 \
            --uartmode1 server "/tmp/${VM_NAME}-serial.sock" &>/dev/null
        info "Serial console: /tmp/${VM_NAME}-serial.sock"
    else
        # Disable serial port for cross-platform compatibility
        VBoxManage modifyvm "$VM_NAME" \
            --uart1 off &>/dev/null
        info "Serial console: disabled (use --serial to enable on Linux)"
    fi

    # Audio (disabled for server) - use --audio-driver instead of deprecated --audio
    VBoxManage modifyvm "$VM_NAME" \
        --audio-driver none &>/dev/null

    # USB (disabled for simplicity)
    VBoxManage modifyvm "$VM_NAME" \
        --usb off &>/dev/null

    # Create IDE controller (more compatible - doesn't need AHCI driver)
    VBoxManage storagectl "$VM_NAME" \
        --name "IDE" \
        --add ide \
        --controller PIIX4 &>/dev/null

    # Attach disk to IDE primary master
    VBoxManage storageattach "$VM_NAME" \
        --storagectl "IDE" \
        --port 0 \
        --device 0 \
        --type hdd \
        --medium "$vdi_file" &>/dev/null

    info "Disk attached: $vdi_file"

    # Shared folders
    VBoxManage sharedfolder add "$VM_NAME" \
        --name "shared" \
        --hostpath "${OUTPUT_DIR}/shared" \
        --automount \
        &>/dev/null || warn "Could not add shared folder (will be created on first run)"

    # Create shared folder directory on host
    mkdir -p "${OUTPUT_DIR}/shared"

    info "Shared folder: ${OUTPUT_DIR}/shared -> /mnt/shared"
}

export_ova() {
    log "Exporting VM as portable OVA..."

    local ova_file="${OUTPUT_DIR}/${VM_NAME}.ova"

    # Remove existing OVA
    rm -f "$ova_file"

    # Export to OVA format
    if ! VBoxManage export "$VM_NAME" \
        --output "$ova_file" \
        --ovf20 \
        --manifest &>/dev/null; then
        warn "Failed to export OVA file"
        return 1
    fi

    local ova_size
    ova_size=$(du -h "$ova_file" | cut -f1)
    info "OVA exported: $ova_file ($ova_size)"

    echo "$ova_file"
}

show_summary() {
    echo ""
    echo "=========================================="
    log "VirtualBox VM created successfully!"
    echo "=========================================="
    echo ""
    echo "VM Name:     $VM_NAME"
    echo "Memory:      ${VM_MEMORY}MB"
    echo "CPUs:        $VM_CPUS"
    echo ""
    echo "Access:"
    echo "  SSH:            ssh -p ${SSH_HOST_PORT} pi@localhost"
    echo "  System Mgmt:    http://localhost:${SYSMGMT_HOST_PORT}/"
    echo "  Business App:   http://localhost:${BUSINESS_HOST_PORT}/"
    if [ "$ENABLE_SERIAL" = "true" ]; then
        echo "  Serial Console: socat - UNIX-CONNECT:/tmp/${VM_NAME}-serial.sock"
    fi
    echo ""
    echo "Default credentials:"
    echo "  Username: ${DEFAULT_USERNAME}"
    echo "  Password: ${DEFAULT_PASSWORD}"
    echo ""
    echo "Start the VM:"
    echo "  VBoxManage startvm \"$VM_NAME\" --type headless"
    echo ""
    echo "Or with GUI:"
    echo "  VBoxManage startvm \"$VM_NAME\" --type gui"
    echo ""
    echo "Stop the VM:"
    echo "  VBoxManage controlvm \"$VM_NAME\" acpipowerbutton"
    echo ""
    if [ "$EXPORT_OVA" = "true" ]; then
        echo "Portable OVA file:"
        echo "  ${OUTPUT_DIR}/${VM_NAME}.ova"
        echo ""
        echo "Import on Windows/macOS:"
        echo "  File -> Import Appliance -> Select .ova file"
        echo ""
    else
        echo "Export as portable OVA (for Windows/macOS):"
        echo "  VBoxManage export \"$VM_NAME\" -o \"${VM_NAME}.ova\""
        echo ""
    fi
}

main() {
    parse_arguments "$@"

    log "Converting to VirtualBox VM..."
    info "Input: $INPUT_IMAGE"
    info "VM Name: $VM_NAME"

    # Check prerequisites
    check_vbox
    check_existing_vm

    # Convert and create VM
    local vdi_file
    vdi_file=$(convert_to_vdi)
    create_vm "$vdi_file"
    configure_vm "$vdi_file"

    # Export OVA if requested
    if [ "$EXPORT_OVA" = "true" ]; then
        export_ova
    fi

    # Show summary
    show_summary
}

main "$@"
