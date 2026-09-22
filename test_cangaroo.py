"""End-to-end test for the Windows CANblaster bridge used by cangaroo.

It runs cangaroo.ps1 against a fake Pi stream and impersonates cangaroo's
CANblaster driver: it waits for the discovery beacon, heartbeats, and decodes
the SocketCAN frames that come back. Requires Windows PowerShell; the test is
skipped elsewhere.
"""

import os
import shutil
import socket
import struct
import subprocess
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "cangaroo.ps1")
POWERSHELL = shutil.which("powershell") or shutil.which("powershell.exe")

DISCOVERY_PORT = 20000
FRAME_PORT = 20001
HEARTBEAT_PORT = 20002

LINES = [
    b"(1760000000.100000) can0 123#11223344\n",
    b"(1760000000.200000) can1 1FEDCBA9#AABBCCDDEEFF0011\n",
    b"(1760000000.300000) can0 456#R3\n",
    b"(1760000000.400000) can1 789##5112233\n",  # CAN FD: not forwarded
    b"(1760000000.500000) can0 7FF#\n",
]


class FakePi(object):
    """Minimal stand-in for rpi_stream.sh: repeats a fixed candump -L script."""

    def __init__(self):
        self._server = socket.socket()
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(1)
        self.port = self._server.getsockname()[1]
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._serve)
        self._thread.daemon = True
        self._thread.start()

    def _serve(self):
        self._server.settimeout(0.5)
        while not self._stop.is_set():
            try:
                conn, _ = self._server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                while not self._stop.is_set():
                    try:
                        for line in LINES:
                            conn.sendall(line)
                    except OSError:
                        break
                    time.sleep(0.2)

    def close(self):
        self._stop.set()
        self._server.close()
        self._thread.join(timeout=2)


@unittest.skipUnless(POWERSHELL, "Windows PowerShell is required")
class CANBlasterBridgeTest(unittest.TestCase):
    def setUp(self):
        self.pi = FakePi()
        self.addCleanup(self.pi.close)

        # cangaroo binds the frame port; the beacon arrives on the discovery
        # port because the bridge is told to announce to this PC as well.
        self.discovery = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.discovery.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.discovery.bind(("0.0.0.0", DISCOVERY_PORT))
        self.discovery.settimeout(15)
        self.addCleanup(self.discovery.close)

        self.frames = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.frames.bind(("0.0.0.0", FRAME_PORT))
        self.frames.settimeout(5)
        self.addCleanup(self.frames.close)

        self.heartbeat = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.addCleanup(self.heartbeat.close)

        self.bridge = subprocess.Popen(
            [
                POWERSHELL,
                "-NoLogo",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                BRIDGE,
                "-Server",
                "127.0.0.1",
                "-Port",
                str(self.pi.port),
                "-Announce",
                "127.0.0.1",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(self._stop_bridge)

    def _stop_bridge(self):
        self.bridge.terminate()
        try:
            self.bridge.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.bridge.kill()

    def _collect(self, wanted):
        """Heartbeats like cangaroo does and returns decoded frames."""
        collected = []
        deadline = time.time() + 20
        while time.time() < deadline and len(collected) < wanted:
            self.heartbeat.sendto(b"Heartbeat", ("127.0.0.1", HEARTBEAT_PORT))
            window = time.time() + 1
            while time.time() < window and len(collected) < wanted:
                try:
                    packet, _ = self.frames.recvfrom(64)
                except socket.timeout:
                    break
                self.assertEqual(len(packet), 16)
                can_id, length = struct.unpack("<IB", packet[:5])
                collected.append((can_id, length, packet[8 : 8 + length]))
        return collected

    def test_announces_itself_as_a_canblaster_server(self):
        data, _ = self.discovery.recvfrom(1024)
        self.assertIn(b'"protocol":"CANblaster"', data.replace(b" ", b""))
        self.assertIn(b'"version":1', data.replace(b" ", b""))

    def test_forwards_frames_as_socketcan_structs(self):
        self.discovery.recvfrom(1024)  # wait until the bridge is announcing
        frames = self._collect(8)
        self.assertTrue(frames, "no frames reached the CANblaster client")

        by_id = dict((frame[0], frame) for frame in frames)

        self.assertIn(0x123, by_id)
        self.assertEqual(by_id[0x123][1], 4)
        self.assertEqual(by_id[0x123][2], b"\x11\x22\x33\x44")

        # Extended frames carry CAN_EFF_FLAG.
        self.assertIn(0x9FEDCBA9, by_id)
        self.assertEqual(by_id[0x9FEDCBA9][1], 8)

        # Remote frames carry CAN_RTR_FLAG and a length but no payload.
        self.assertIn(0x40000456, by_id)
        self.assertEqual(by_id[0x40000456][1], 3)

        self.assertIn(0x7FF, by_id)
        self.assertEqual(by_id[0x7FF][1], 0)

        # The CAN FD line is dropped: the cangaroo driver is classic-CAN only.
        self.assertNotIn(0x789, by_id)


if __name__ == "__main__":
    unittest.main()
