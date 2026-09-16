#!/bin/bash

PORT=5000
INTERFACE="can_remote"

echo "======================================"
echo " Remote CAN Receiver"
echo " Interface: $INTERFACE"
echo " TCP Port:  $PORT"
echo "======================================"

# Create virtual CAN interface if it doesn't exist
sudo modprobe vcan

if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "[INFO] Creating $INTERFACE..."
    sudo ip link add dev "$INTERFACE" type vcan
fi

sudo ip link set "$INTERFACE" up

echo "[INFO] $INTERFACE is UP"
echo "[INFO] Waiting for Raspberry Pi..."

while true; do

    nc -l -p "$PORT" | while read -r line; do

        # Expected candump -L format:
        # (timestamp) can1 123#11223344

        FRAME=$(echo "$line" | awk '{print $3}')

        if [[ "$FRAME" == *"#"* ]]; then
            cansend "$INTERFACE" "$FRAME"
        fi

    done

    echo "[WARNING] Connection lost."
    echo "[INFO] Waiting for Raspberry Pi again..."

    sleep 1
done
