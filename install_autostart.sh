#!/bin/bash
set -euo pipefail

if (( EUID != 0 )); then
    echo "[ERROR] Run this installer on the Pi: sudo bash ./install_autostart.sh" >&2
    exit 1
fi

for tool in systemctl install python3 candump ip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] Missing $tool. Install dependencies: sudo apt install can-utils python3 iproute2" >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
for file in rpi_stream.sh stream_server.py start_service.sh rpi-can-stream.service rpi-can-stream.conf; do
    if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
        echo "[ERROR] Missing $file. Copy the whole remote-can-receiver directory to the Pi." >&2
        exit 1
    fi
done

install -d -m 0755 /opt/remote-can-receiver /etc/default
for file in rpi_stream.sh start_service.sh; do
    install -m 0755 "$SCRIPT_DIR/$file" "/opt/remote-can-receiver/$file"
done
install -m 0644 "$SCRIPT_DIR/stream_server.py" /opt/remote-can-receiver/stream_server.py
install -m 0644 "$SCRIPT_DIR/rpi-can-stream.service" /etc/systemd/system/rpi-can-stream.service
if [[ ! -e /etc/default/rpi-can-stream ]]; then
    install -m 0644 "$SCRIPT_DIR/rpi-can-stream.conf" /etc/default/rpi-can-stream
fi

systemctl daemon-reload
systemctl enable rpi-can-stream.service
systemctl restart rpi-can-stream.service

echo "[INFO] Autostart installed and enabled."
echo "[INFO] If needed, set CAN0_BITRATE and CAN1_BITRATE in /etc/default/rpi-can-stream."
echo "[INFO] Apply config changes: sudo systemctl restart rpi-can-stream"
echo "[INFO] Check status: sudo systemctl status rpi-can-stream --no-pager"
echo "[INFO] View logs: sudo journalctl -u rpi-can-stream -f"
