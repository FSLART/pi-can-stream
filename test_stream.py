"""Exercise the TCP server with a simulated CAN capture executable."""

import os
from contextlib import suppress
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent


class StreamTest(unittest.TestCase):
    def test_pc_keeps_can0_and_can1_on_separate_virtual_interfaces(self):
        # Catches routing both source buses into the same local CAN interface.
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            log = tools / "frames"
            scripts = {
                "sudo": '#!/bin/sh\nexec "$@"\n',
                "modprobe": "#!/bin/sh\nexit 0\n",
                "ip": "#!/bin/sh\nexit 0\n",
                "cansend": '#!/bin/sh\nprintf "%s %s\\n" "$1" "$2" >> "$FRAME_LOG"\n',
                "nc": (
                    "#!/bin/sh\n"
                    "printf '(1.000000) can0 123#1122\\n"
                    "(1.000001) can1 456#3344\\r\\n"
                    "(1.000002) can9 789#5566\\ninvalid line\\n'\n"
                    "sleep 10\n"
                ),
            }
            for name, script in scripts.items():
                path = tools / name
                path.write_text(script)
                path.chmod(0o755)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       FRAME_LOG=str(log))
            process = subprocess.Popen(
                ["bash", str(ROOT / "connect.sh"), "example.local"], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 3
                while not log.exists() or len(log.read_text().splitlines()) < 2:
                    if process.poll() is not None:
                        self.fail("PC connection did not start: " + process.stdout.read())
                    self.assertLess(time.monotonic(), deadline, "PC did not forward frames")
                    time.sleep(0.02)
                self.assertEqual(log.read_text().splitlines(),
                                 ["can_remote0 123#1122", "can_remote1 456#3344"])
            finally:
                with suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=3)
                process.stdout.close()

    def test_two_clients_receive_both_buses_and_can_reconnect(self):
        # Catches a single-client listener and accidental loss of the bus names.
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            (tools / "ip").write_text(
                '#!/bin/sh\nprintf \'[{"flags":["UP"]}]\\n\'\n'
            )
            (tools / "candump").write_text(
                "#!/usr/bin/env python3\n"
                "import sys, time\n"
                "assert sys.argv[1:] == ['-L', 'can0', 'can1']\n"
                "while True:\n"
                "    print('(1.000000) can0 123#1122', flush=True)\n"
                "    print('(1.000001) can1 456#3344', flush=True)\n"
                "    time.sleep(0.05)\n"
            )
            for tool in tools.iterdir():
                tool.chmod(0o755)
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       PORT=str(port), LISTEN_HOST="127.0.0.1")
            process = subprocess.Popen(
                ["bash", str(ROOT / "rpi_stream.sh")], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, start_new_session=True,
            )
            clients = []
            try:
                deadline = time.monotonic() + 5
                while True:
                    if process.poll() is not None:
                        self.fail("Pi stream did not start: " + process.stdout.read())
                    try:
                        first = socket.create_connection(("127.0.0.1", port), 0.2)
                        break
                    except OSError:
                        if time.monotonic() >= deadline:
                            self.fail("Pi stream did not listen within 5 seconds")
                        time.sleep(0.02)
                clients.append(first)
                clients.append(socket.create_connection(("127.0.0.1", port), 2))
                self.assert_frames(clients[0])
                self.assert_frames(clients[1])
                clients[0].close()
                clients.append(socket.create_connection(("127.0.0.1", port), 2))
                self.assert_frames(clients[2])
                self.assert_frames(clients[1])
            finally:
                for client in clients:
                    client.close()
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                process.stdout.close()

    def assert_frames(self, client):
        data = b""
        deadline = time.monotonic() + 3
        while b"can0 123#1122\n" not in data or b"can1 456#3344\n" not in data:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, f"Missing CAN frames: {data!r}")
            ready, _, _ = select.select([client], [], [], remaining)
            self.assertTrue(ready, f"Missing CAN frames: {data!r}")
            chunk = client.recv(4096)
            self.assertTrue(chunk, "Stream disconnected unexpectedly")
            data += chunk


if __name__ == "__main__":
    unittest.main()
