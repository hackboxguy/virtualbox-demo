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
USB_MODE=""           # off, 1, 2, or 3 (USB controller version)
HOST_SERIAL=""        # Host serial port to pass through (e.g., /dev/ttyS0, COM1)

# Port forwarding (with defaults in case config.sh doesn't define them)
: "${DEFAULT_WEBTERMINAL_PORT:=8003:8003}"
SSH_HOST_PORT="${DEFAULT_SSH_PORT%%:*}"
SSH_GUEST_PORT="${DEFAULT_SSH_PORT##*:}"
SYSMGMT_HOST_PORT="${DEFAULT_SYSMGMT_PORT%%:*}"
SYSMGMT_GUEST_PORT="${DEFAULT_SYSMGMT_PORT##*:}"
BUSINESS_HOST_PORT="${DEFAULT_BUSINESS_PORT%%:*}"
BUSINESS_GUEST_PORT="${DEFAULT_BUSINESS_PORT##*:}"
WEBTERMINAL_HOST_PORT="${DEFAULT_WEBTERMINAL_PORT%%:*}"
WEBTERMINAL_GUEST_PORT="${DEFAULT_WEBTERMINAL_PORT##*:}"

# App ports (populated from manifest)
declare -a APP_PORTS=()
APP_MANIFEST=""

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
  --appdir=DIR          Directory containing APP partition content (for port forwarding)
  --serial              Enable serial console output (Linux host only)
  --usb[=VERSION]       Enable USB passthrough with device filters
                        VERSION: 1 (OHCI, default), 2 (EHCI), 3 (xHCI)
                        Note: USB 2.0/3.0 requires VirtualBox Extension Pack
  --hostserial=PORT     Pass through host serial port to VM COM1
                        Linux: /dev/ttyS0, /dev/ttyS1, etc.
                        Windows: COM1, COM2, etc.
  --export-ova          Also export as portable OVA file
  --force               Overwrite existing VM
  --help, -h            Show this help

Port Forwarding (default):
  SSH:          ${DEFAULT_SSH_PORT}
  System Mgmt:  ${DEFAULT_SYSMGMT_PORT}
  Web Terminal: ${DEFAULT_WEBTERMINAL_PORT}

USB Devices (auto-attached with --usb):
  Serial Adapters:
    FTDI (FT232, FT2232)  - VID 0403
    Silicon Labs CP210x   - VID 10C4
    WCH CH340/CH341       - VID 1A86
    Prolific PL2303       - VID 067B
    Arduino boards        - VID 2341
  Android ADB:
    Android/AOSP devices  - VID 18d1 (Google, Harman IVI, etc.)
  CAN Bus Adapters:
    CANable (gs_usb)      - VID 1d50
    PCAN-USB (peak_usb)   - VID 0c72

Examples:
  $0 --input=./alpine-vbox.raw --vmname=alpine-demo
  $0 --input=./alpine-vbox.raw --vmname=my-vm --usb --export-ova
  $0 --input=./alpine-vbox.raw --vmname=my-vm --usb=1 --hostserial=/dev/ttyS0

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
            --appdir=*)     APP_MANIFEST="${arg#*=}/manifest.json" ;;
            --serial)       ENABLE_SERIAL=true ;;
            --usb)          USB_MODE="1" ;;  # Default to USB 1.1 (no Extension Pack needed)
            --usb=*)        USB_MODE="${arg#*=}" ;;
            --hostserial=*) HOST_SERIAL="${arg#*=}" ;;
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

load_app_ports() {
    # Load application ports from manifest for port forwarding
    if [ -z "$APP_MANIFEST" ] || [ ! -f "$APP_MANIFEST" ]; then
        return 0
    fi

    log "Loading application ports from manifest..."

    # Check if jq is available
    if ! command -v jq &>/dev/null; then
        warn "jq not found - cannot parse app manifest for port forwarding"
        warn "Install jq to enable automatic app port forwarding"
        return 0
    fi

    # Parse apps array and extract ports
    local apps_json
    apps_json=$(jq -r '.apps // []' "$APP_MANIFEST" 2>/dev/null)

    if [ "$apps_json" = "[]" ] || [ -z "$apps_json" ]; then
        info "No applications found in manifest"
        return 0
    fi

    # Extract name and port for each app with port > 0
    local app_count=0
    while IFS='|' read -r name port; do
        if [ -n "$name" ] && [ -n "$port" ] && [ "$port" != "0" ] && [ "$port" != "null" ]; then
            APP_PORTS+=("${name}|${port}")
            app_count=$((app_count + 1))
        fi
    done < <(jq -r '.apps[] | select(.port != null and .port > 0) | "\(.name)|\(.port)"' "$APP_MANIFEST" 2>/dev/null)

    if [ $app_count -gt 0 ]; then
        info "Found $app_count application(s) with ports"
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
    if ! VBoxManage createvm \
        --name "$VM_NAME" \
        --ostype "Linux_64" \
        --register &>/dev/null; then
        error "Failed to create VM '$VM_NAME'"
    fi

    info "VM created"
}

configure_vm() {
    local vdi_file="$1"

    log "Configuring VM..."

    # Basic settings (suppress warnings - they go to stdout, not stderr)
    # Use default PIIX3 chipset with IDE storage for maximum compatibility
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
        --boot4 none &>/dev/null || true

    info "Memory: ${VM_MEMORY}MB, CPUs: ${VM_CPUS}"

    # Network: NAT with port forwarding
    # Use virtio for best performance - Alpine linux-lts kernel includes virtio_net
    VBoxManage modifyvm "$VM_NAME" \
        --nic1 nat \
        --nictype1 virtio &>/dev/null || true

    # Add port forwarding rules (|| true prevents silent exit on duplicate rules)
    # SSH and System Management are always exposed
    # App ports are forwarded for WebSocket access (token-authenticated)
    VBoxManage modifyvm "$VM_NAME" \
        --natpf1 "ssh,tcp,,${SSH_HOST_PORT},,${SSH_GUEST_PORT}" &>/dev/null || true
    VBoxManage modifyvm "$VM_NAME" \
        --natpf1 "sysmgmt,tcp,,${SYSMGMT_HOST_PORT},,${SYSMGMT_GUEST_PORT}" &>/dev/null || true
    VBoxManage modifyvm "$VM_NAME" \
        --natpf1 "webterminal,tcp,,${WEBTERMINAL_HOST_PORT},,${WEBTERMINAL_GUEST_PORT}" &>/dev/null || true

    # Add app port forwarding rules (for WebSocket-enabled apps)
    for app_entry in "${APP_PORTS[@]}"; do
        local app_name="${app_entry%%|*}"
        local app_port="${app_entry##*|}"
        VBoxManage modifyvm "$VM_NAME" \
            --natpf1 "app-${app_name},tcp,,${app_port},,${app_port}" &>/dev/null || true
    done

    info "Network: NAT with port forwarding"
    info "  SSH:          localhost:${SSH_HOST_PORT} -> VM:${SSH_GUEST_PORT}"
    info "  System Mgmt:  localhost:${SYSMGMT_HOST_PORT} -> VM:${SYSMGMT_GUEST_PORT}"
    info "  Web Terminal: localhost:${WEBTERMINAL_HOST_PORT} -> VM:${WEBTERMINAL_GUEST_PORT}"
    info "  (HTTP access: via proxy at /app/<name>/, WebSocket: direct to app port)"
    for app_entry in "${APP_PORTS[@]}"; do
        local app_name="${app_entry%%|*}"
        local app_port="${app_entry##*|}"
        info "  App ${app_name}: localhost:${app_port} (WebSocket)"
    done

    # Serial port configuration
    # --serial: Unix socket for console access (Linux only)
    # --hostserial: Pass through host serial port (configured later)
    # If neither is specified, disable UART
    if [ "$ENABLE_SERIAL" = "true" ]; then
        VBoxManage modifyvm "$VM_NAME" \
            --uart1 0x3F8 4 \
            --uartmode1 server "/tmp/${VM_NAME}-serial.sock" &>/dev/null || true
        info "Serial console: /tmp/${VM_NAME}-serial.sock"
    elif [ -z "$HOST_SERIAL" ]; then
        # Only disable if --hostserial is not being used
        VBoxManage modifyvm "$VM_NAME" \
            --uart1 off &>/dev/null || true
        info "Serial console: disabled (use --serial to enable on Linux)"
    else
        info "Serial: will be configured for host passthrough"
    fi

    # Audio (disabled for server)
    # VBox 7.x uses --audio-driver, VBox 6.x uses --audio
    VBoxManage modifyvm "$VM_NAME" --audio none 2>/dev/null || \
    VBoxManage modifyvm "$VM_NAME" --audio-driver none 2>/dev/null || true

    # Create SATA controller (AHCI) - works on VirtualBox 6.x and 7.x
    # Note: linux-lts kernel has AHCI support built-in
    log "Creating SATA controller..."
    VBoxManage storagectl "$VM_NAME" \
        --name "SATA" \
        --add sata \
        --controller IntelAhci \
        --portcount 1 || error "Failed to create SATA controller"

    # Attach disk to SATA port 0
    log "Attaching disk..."
    VBoxManage storageattach "$VM_NAME" \
        --storagectl "SATA" \
        --port 0 \
        --device 0 \
        --type hdd \
        --medium "$vdi_file" || error "Failed to attach disk"

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

configure_usb() {
    # Configure USB controller and device filters
    # Called after configure_vm() if --usb is specified

    if [ -z "$USB_MODE" ]; then
        # USB disabled
        VBoxManage modifyvm "$VM_NAME" \
            --usb off &>/dev/null || true
        info "USB: disabled (use --usb to enable)"
        return 0
    fi

    log "Configuring USB passthrough..."

    # Check if Extension Pack is installed (needed for USB 2.0/3.0)
    local extpack_installed=false
    if VBoxManage list extpacks 2>/dev/null | grep -q "Oracle VM VirtualBox Extension Pack"; then
        extpack_installed=true
    fi

    # Warn if USB 2.0/3.0 requested without Extension Pack
    if [ "$USB_MODE" = "2" ] || [ "$USB_MODE" = "3" ]; then
        if [ "$extpack_installed" = "false" ]; then
            warn "USB $USB_MODE.0 requires VirtualBox Extension Pack (not installed)"
            warn "Falling back to USB 1.1 (OHCI)"
            warn "To use USB 2.0/3.0: Install Extension Pack from virtualbox.org"
            USB_MODE="1"
        fi
    fi

    case "$USB_MODE" in
        1|off)
            # USB 1.1 (OHCI) - built-in, no extension pack needed
            VBoxManage modifyvm "$VM_NAME" \
                --usb on \
                --usbohci on &>/dev/null || true
            info "USB 1.1 (OHCI): enabled"
            ;;
        2)
            # USB 2.0 (EHCI) - requires Extension Pack
            VBoxManage modifyvm "$VM_NAME" \
                --usb on \
                --usbehci on &>/dev/null || true
            info "USB 2.0 (EHCI): enabled (requires VirtualBox Extension Pack)"
            ;;
        3)
            # USB 3.0 (xHCI) - requires Extension Pack
            VBoxManage modifyvm "$VM_NAME" \
                --usb on \
                --usbxhci on &>/dev/null || true
            info "USB 3.0 (xHCI): enabled (requires VirtualBox Extension Pack)"
            ;;
        *)
            warn "Unknown USB mode: $USB_MODE, using USB 2.0"
            VBoxManage modifyvm "$VM_NAME" \
                --usb on \
                --usbehci on &>/dev/null || true
            ;;
    esac

    # Add USB device filters for common serial adapters
    # These filters will auto-attach matching devices when plugged in

    # FTDI (FT232, FT2232, FT4232) - VID 0403
    VBoxManage usbfilter add 0 --target "$VM_NAME" \
        --name "FTDI Serial" \
        --vendorid 0403 \
        --active yes &>/dev/null || true
    info "  Filter: FTDI (VID 0403)"

    # Silicon Labs CP210x - VID 10C4
    VBoxManage usbfilter add 1 --target "$VM_NAME" \
        --name "CP210x Serial" \
        --vendorid 10C4 \
        --active yes &>/dev/null || true
    info "  Filter: Silicon Labs CP210x (VID 10C4)"

    # WCH CH340/CH341 - VID 1A86
    VBoxManage usbfilter add 2 --target "$VM_NAME" \
        --name "CH340/CH341 Serial" \
        --vendorid 1A86 \
        --active yes &>/dev/null || true
    info "  Filter: WCH CH340/CH341 (VID 1A86)"

    # Prolific PL2303 - VID 067B
    VBoxManage usbfilter add 3 --target "$VM_NAME" \
        --name "PL2303 Serial" \
        --vendorid 067B \
        --active yes &>/dev/null || true
    info "  Filter: Prolific PL2303 (VID 067B)"

    # Arduino boards (MKR, Uno, Leonardo, etc.) - VID 2341
    VBoxManage usbfilter add 4 --target "$VM_NAME" \
        --name "Arduino" \
        --vendorid 2341 \
        --active yes &>/dev/null || true
    info "  Filter: Arduino (VID 2341)"

    # Android ADB devices - VID 18d1 (Google/AOSP, includes Harman IVI)
    VBoxManage usbfilter add 5 --target "$VM_NAME" \
        --name "Android ADB" \
        --vendorid 18d1 \
        --active yes &>/dev/null || true
    info "  Filter: Android ADB (VID 18d1)"

    # CANable USB-CAN adapter (gs_usb driver) - VID 1d50
    VBoxManage usbfilter add 6 --target "$VM_NAME" \
        --name "CANable" \
        --vendorid 1d50 \
        --active yes &>/dev/null || true
    info "  Filter: CANable (VID 1d50)"

    # PCAN-USB adapter (peak_usb driver) - VID 0c72
    VBoxManage usbfilter add 7 --target "$VM_NAME" \
        --name "PCAN-USB" \
        --vendorid 0c72 \
        --active yes &>/dev/null || true
    info "  Filter: PCAN-USB (VID 0c72)"

    info "USB device filters configured"
}

configure_host_serial() {
    # Configure host serial port passthrough
    # This maps host's physical COM port to VM's COM1

    if [ -z "$HOST_SERIAL" ]; then
        return 0
    fi

    log "Configuring host serial port passthrough..."

    # Check if host serial port exists
    if [ ! -e "$HOST_SERIAL" ]; then
        warn "Host serial port does not exist: $HOST_SERIAL"
        warn "Available serial ports on host:"
        ls /dev/ttyS* /dev/ttyUSB* 2>/dev/null | head -5 || echo "  (none found)"
        return 1
    fi

    # Check if it's a real serial port (not a virtual one)
    # Real ports have a non-zero I/O port in /proc/tty/driver/serial
    local port_name
    port_name=$(basename "$HOST_SERIAL")
    if [[ "$port_name" =~ ^ttyS([0-9]+)$ ]]; then
        local port_num="${BASH_REMATCH[1]}"
        local port_info
        port_info=$(grep "^${port_num}:" /proc/tty/driver/serial 2>/dev/null || true)
        if echo "$port_info" | grep -q "uart:unknown\|port:00000000"; then
            warn "Host serial port $HOST_SERIAL appears to be a virtual port (no hardware)"
            warn "Use a USB serial adapter instead, or verify your PC has a physical COM port"
            # Continue anyway - user might know what they're doing
        fi
    fi

    info "Host port: $HOST_SERIAL -> VM COM1 (/dev/ttyS0)"

    # VirtualBox UART1 is COM1 (0x3F8, IRQ 4)
    # For host device passthrough, use --uart-mode1 with just the device path
    # (no "hostdev" keyword - that's the old/wrong syntax)
    local vbox_output
    local vbox_rc
    vbox_output=$(VBoxManage modifyvm "$VM_NAME" \
        --uart1 0x3F8 4 \
        --uart-mode1 "$HOST_SERIAL" 2>&1) || vbox_rc=$?

    if [ -z "$vbox_rc" ] || [ "$vbox_rc" -eq 0 ]; then
        info "Host serial passthrough configured successfully"
    else
        warn "Failed to configure host serial passthrough"
        warn "VBoxManage error: $vbox_output"
        warn "Ensure the host serial port exists and you have permissions"
    fi
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
    echo "  SSH:            ssh -p ${SSH_HOST_PORT} ${DEFAULT_USERNAME}@localhost"
    echo "  System Mgmt:    http://localhost:${SYSMGMT_HOST_PORT}/"
    echo "  (Apps: HTTP via /app/<name>/, WebSocket via direct port)"
    for app_entry in "${APP_PORTS[@]}"; do
        local app_name="${app_entry%%|*}"
        local app_port="${app_entry##*|}"
        printf "  %-14s  ws://localhost:%s/ (WebSocket)\n" "App ${app_name}:" "${app_port}"
    done
    if [ "$ENABLE_SERIAL" = "true" ]; then
        echo "  Serial Console: socat - UNIX-CONNECT:/tmp/${VM_NAME}-serial.sock"
    fi
    echo ""
    # USB configuration summary
    if [ -n "$USB_MODE" ]; then
        echo "USB Passthrough:"
        case "$USB_MODE" in
            1) echo "  Controller: USB 1.1 (OHCI)" ;;
            2) echo "  Controller: USB 2.0 (EHCI) - requires Extension Pack" ;;
            3) echo "  Controller: USB 3.0 (xHCI) - requires Extension Pack" ;;
        esac
        echo "  Auto-attach filters:"
        echo "    Serial: FTDI (0403), CP210x (10C4), CH340 (1A86), PL2303 (067B), Arduino (2341)"
        echo "    ADB:    Android/AOSP devices (18d1)"
        echo "    CAN:    CANable (1d50), PCAN-USB (0c72)"
        echo ""
    fi
    # Host serial passthrough summary
    if [ -n "$HOST_SERIAL" ]; then
        echo "Host Serial Passthrough:"
        echo "  $HOST_SERIAL -> VM /dev/ttyS0"
        echo ""
    fi
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

    # Load app ports from manifest (if provided)
    load_app_ports

    # Convert and create VM
    local vdi_file
    vdi_file=$(convert_to_vdi)
    create_vm "$vdi_file"
    configure_vm "$vdi_file"

    # Configure USB and serial (after VM is created)
    configure_usb
    configure_host_serial

    # Export OVA if requested
    if [ "$EXPORT_OVA" = "true" ]; then
        export_ova
    fi

    # Show summary
    show_summary
}

main "$@"
