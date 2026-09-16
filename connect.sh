#!/bin/bash
set -euo pipefail

# Run on a Linux PC. The Pi listens; this PC initiates the connection.
# If hostname lookup fails, put the Pi Wi-Fi IP between the quotes below.
RPI_IP=""
RPI_HOST="${1:-${RPI_IP:-lart2026-desktop.local}}"
PORT="${2:-${PORT:-5000}}"

for tool in nc cansend ip modprobe sudo; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] Missing $tool. Install can-utils, netcat-openbsd and iproute2." >&2
        exit 1
    fi
done

sudo modprobe vcan
for interface in can_remote0 can_remote1; do
    if ! ip link show dev "$interface" >/dev/null 2>&1; then
        sudo ip link add dev "$interface" type vcan
    fi
    sudo ip link set dev "$interface" up
done

echo "[INFO] can0 -> can_remote0; can1 -> can_remote1"
echo "[INFO] View frames in another terminal: candump can_remote0 can_remote1"

while true; do
    echo "[INFO] Connecting to $RPI_HOST:$PORT..."
    if nc -d -v "$RPI_HOST" "$PORT" | while read -r timestamp source frame remainder; do
        case "$source" in
            can0) interface="can_remote0" ;;
            can1) interface="can_remote1" ;;
            *) continue ;;
        esac
        frame="${frame%$'\r'}"
        if [[ "$frame" == *"#"* ]]; then
            if ! cansend "$interface" "$frame"; then
                echo "[WARNING] Could not forward $source frame: $frame" >&2
            fi
        fi
    done; then
        echo "[WARNING] Pi closed the connection."
    else
        echo "[WARNING] Connection failed or was interrupted." >&2
    fi
    echo "[INFO] Reconnecting in 2 seconds..."
    sleep 2
done
