"""Verify boot-time CAN setup without changing host interfaces."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent


class AutostartTest(unittest.TestCase):
    def run_startup(self, already_up):
        with tempfile.TemporaryDirectory() as directory:
            tools = Path(directory)
            log = tools / "commands"
            (tools / "ip").write_text(
                '#!/bin/bash\n'
                'printf "%s\\n" "$*" >> "$COMMAND_LOG"\n'
                'if [[ "$1" == "-o" ]]; then\n'
                '  printf "5: %s: <%s> mtu 16\\n" "$5" "$LINK_FLAGS"\n'
                'fi\n'
            )
            (tools / "python3").write_text(
                '#!/bin/bash\nprintf "stream %s\\n" "$*" >> "$COMMAND_LOG"\n'
            )
            (tools / "candump").write_text('#!/bin/bash\nexit 0\n')
            for name in ("ip", "python3", "candump"):
                (tools / name).chmod(0o755)
            env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                       COMMAND_LOG=str(log), LINK_FLAGS="NOARP,UP" if already_up else "NOARP",
                       CAN0_BITRATE="250000", CAN1_BITRATE="500000")
            result = subprocess.run(["bash", str(ROOT / "start_service.sh")],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return log.read_text().splitlines()

    def test_configures_each_down_bus_before_starting_stream(self):
        # Catches mixing the bitrates or starting capture before bringing CAN up.
        commands = self.run_startup(already_up=False)
        self.assertEqual(commands[:-1], [
            "-o link show dev can0",
            "link set dev can0 type can bitrate 250000",
            "link set dev can0 up",
            "-o link show dev can1",
            "link set dev can1 type can bitrate 500000",
            "link set dev can1 up",
        ])
        self.assertTrue(commands[-1].startswith("stream "), commands)

    def test_preserves_interfaces_that_are_already_up(self):
        # Catches an unintended interruption of an existing CAN configuration.
        commands = self.run_startup(already_up=True)
        self.assertEqual(commands[:-1], ["-o link show dev can0", "-o link show dev can1"])
        self.assertTrue(commands[-1].startswith("stream "), commands)


if __name__ == "__main__":
    unittest.main()
