#!/usr/bin/env python3
"""Serve live candump output to independent, read-only TCP clients."""

import argparse
import asyncio
from contextlib import suppress
import json
import signal
import socket
import subprocess
import sys


def check_interfaces(interfaces):
    for interface in interfaces:
        result = subprocess.run(
            ["ip", "-j", "link", "show", "dev", interface],
            capture_output=True, text=True,
        )
        if result.returncode:
            raise RuntimeError(f"{interface} is unavailable: {result.stderr.strip()}")
        links = json.loads(result.stdout)
        if not links or "UP" not in links[0].get("flags", []):
            raise RuntimeError(
                f"{interface} is down. Configure its CAN bitrate and bring it up first."
            )


async def serve(host, port, interfaces):
    clients = set()
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(signum, stopped.set)

    async def handle_client(reader, writer):
        task = asyncio.current_task()
        clients.add(task)
        peer = writer.get_extra_info("peername")
        capture = None
        workers = []
        print(f"[INFO] PC connected: {peer}", flush=True)
        try:
            # Each subscriber has its own SocketCAN capture. Slow or disconnected
            # clients cannot stall another subscriber, and no frames are replayed.
            capture = await asyncio.create_subprocess_exec(
                "candump", "-L", *interfaces, stdout=asyncio.subprocess.PIPE,
            )

            async def forward_frames():
                while True:
                    line = await capture.stdout.readline()
                    if not line:
                        status = await capture.wait()
                        print(f"[WARNING] CAN capture ended for {peer}: exit {status}", flush=True)
                        return
                    writer.write(line)
                    await asyncio.wait_for(writer.drain(), timeout=5)

            async def watch_disconnect():
                # Input from PCs is discarded; it never reaches a CAN bus.
                while await reader.read(4096):
                    pass

            workers = [asyncio.create_task(forward_frames()),
                       asyncio.create_task(watch_disconnect())]
            done, _ = await asyncio.wait(workers, return_when=asyncio.FIRST_COMPLETED)
            for worker in done:
                worker.result()
        except (OSError, asyncio.TimeoutError) as error:
            print(f"[WARNING] Stream to {peer} closed: {error}", flush=True)
        finally:
            for worker in workers:
                worker.cancel()
            await asyncio.gather(*workers, return_exceptions=True)
            if capture is not None and capture.returncode is None:
                with suppress(ProcessLookupError):
                    capture.terminate()
                try:
                    await asyncio.wait_for(capture.wait(), timeout=2)
                except asyncio.TimeoutError:
                    with suppress(ProcessLookupError):
                        capture.kill()
                    await capture.wait()
            writer.close()
            with suppress(OSError):
                await writer.wait_closed()
            clients.discard(task)
            print(f"[INFO] PC disconnected: {peer}", flush=True)

    server = await asyncio.start_server(handle_client, host, port)
    print(f"[INFO] Streaming {' + '.join(interfaces)} on {host}:{port}", flush=True)
    print(f"[INFO] On a PC: nc {socket.gethostname().split('.')[0]}.local {port}", flush=True)
    print("[INFO] Waiting for PCs. Press Ctrl+C to stop.", flush=True)
    try:
        await stopped.wait()
    finally:
        server.close()
        await server.wait_closed()
        tasks = list(clients)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("interfaces", nargs="+", default=["can0", "can1"])
    args = parser.parse_args()
    try:
        if not 1 <= args.port <= 65535:
            raise ValueError("TCP port must be between 1 and 65535")
        check_interfaces(args.interfaces)
        asyncio.run(serve(args.host, args.port, args.interfaces))
    except (OSError, RuntimeError, ValueError) as error:
        print(f"[ERROR] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
