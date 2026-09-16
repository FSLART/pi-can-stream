#!/bin/bash
set -euo pipefail

# Run on the Raspberry Pi after configuring can0 and can1.
PORT="${PORT:-5000}"
LISTEN_HOST="${LISTEN_HOST:-0.0.0.0}"

for tool in python3 candump ip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "[ERROR] Missing $tool. Install python3, can-utils and iproute2." >&2
        exit 1
    fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -u "$SCRIPT_DIR/stream_server.py" --host "$LISTEN_HOST" --port "$PORT" can0 can1
