#!/bin/bash
set -euo pipefail

# Optional bitrates come from /etc/default/rpi-can-stream via systemd.
CAN0_BITRATE="${CAN0_BITRATE:-}"
CAN1_BITRATE="${CAN1_BITRATE:-}"
for bitrate in "$CAN0_BITRATE" "$CAN1_BITRATE"; do
    if [[ -n "$bitrate" && ! "$bitrate" =~ ^[1-9][0-9]*$ ]]; then
        echo "[ERROR] CAN bitrates must be positive integers or left empty." >&2
        exit 1
    fi
done

for interface in can0 can1; do
    link="$(ip -o link show dev "$interface")"
    flags="${link#*<}"
    flags="${flags%%>*}"
    if [[ ",$flags," == *,UP,* ]]; then
        echo "[INFO] $interface is already up."
        continue
    fi

    bitrate_variable="${interface^^}_BITRATE"
    bitrate="${!bitrate_variable}"
    if [[ -n "$bitrate" ]]; then
        ip link set dev "$interface" type can bitrate "$bitrate"
    fi
    if ! ip link set dev "$interface" up; then
        echo "[ERROR] Cannot bring up $interface. Set its bitrate in /etc/default/rpi-can-stream." >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash "$SCRIPT_DIR/rpi_stream.sh"
