#!/bin/sh
# setup-can.sh - Auto-configure CAN interface when adapter is plugged in
# Called by udev rule when CAN interface is created
#
# Usage: setup-can.sh <interface>
# Example: setup-can.sh can0

# Source config file if it exists
[ -f /etc/conf.d/can ] && . /etc/conf.d/can

INTERFACE="$1"
BITRATE="${CAN_BITRATE:-500000}"  # Default 500kbps, override via config or environment
LOG_TAG="setup-can"

# Validate interface name
if [ -z "$INTERFACE" ]; then
    logger -t "$LOG_TAG" "Error: No interface specified"
    exit 1
fi

# Check if interface exists
if [ ! -d "/sys/class/net/$INTERFACE" ]; then
    logger -t "$LOG_TAG" "Error: Interface $INTERFACE does not exist"
    exit 1
fi

# Check if it's actually a CAN interface
if [ ! -f "/sys/class/net/$INTERFACE/type" ]; then
    logger -t "$LOG_TAG" "Error: Cannot determine interface type for $INTERFACE"
    exit 1
fi

IFTYPE=$(cat "/sys/class/net/$INTERFACE/type")
if [ "$IFTYPE" != "280" ]; then
    logger -t "$LOG_TAG" "Error: $INTERFACE is not a CAN interface (type=$IFTYPE)"
    exit 1
fi

logger -t "$LOG_TAG" "Configuring $INTERFACE with bitrate $BITRATE"

# Configure bitrate
if ! ip link set "$INTERFACE" type can bitrate "$BITRATE" 2>&1; then
    logger -t "$LOG_TAG" "Error: Failed to set bitrate on $INTERFACE"
    exit 1
fi

# Bring interface up
if ! ip link set "$INTERFACE" up 2>&1; then
    logger -t "$LOG_TAG" "Error: Failed to bring up $INTERFACE"
    exit 1
fi

logger -t "$LOG_TAG" "$INTERFACE configured successfully (bitrate=$BITRATE)"
