# CAN over Wi-Fi

The Raspberry Pi listens on TCP port 5000. Any PC on the same reachable
network can connect; the Pi does not need a PC address. Several PCs can
watch at once. The stream preserves the source bus name and contains only
live frames, with no history or replay. PC input is never sent onto the
Pi's physical CAN buses.

## Raspberry Pi

Copy this directory to the Pi, including `rpi_stream.sh` and
`stream_server.py`. Install the dependencies:

```bash
sudo apt install can-utils python3 iproute2 avahi-daemon
```

Both CAN interfaces must exist and be configured with the correct bitrate
for their physical buses. If needed, bring each interface up using its
actual bitrate (replace the placeholders):

```bash
sudo ip link set can0 up type can bitrate <can0-bitrate>
sudo ip link set can1 up type can bitrate <can1-bitrate>
```

Run the server:

```bash
./rpi_stream.sh
```

It checks that both buses are up and waits for PCs. It uses
`candump -L can0 can1` to capture both buses in the can-utils log format:
https://github.com/linux-can/can-utils/blob/master/candump.c

Find the Pi's hostname with `hostname`. If it is `lart2026-desktop`, PCs can
normally use `lart2026-desktop.local`. The `.local` hostname requires mDNS
support on the Pi and PC; otherwise use the Pi's IP or another resolvable
hostname. `rpi_stream.sh` starts the server when launched. To start it at
boot, use the installer below. Wi-Fi must already be configured on the Pi.

If the hostname does not work, run `hostname -I` on the Pi and use its
Wi-Fi IP instead. Replace `PI_WIFI_IP` below with that address:

```text
nc PI_WIFI_IP 5000
connect.bat PI_WIFI_IP 5000
./connect.sh PI_WIFI_IP 5000
```

To save the IP as your default, set `RPI_CAN_IP` near the top of
`connect.bat`, or `RPI_IP` near the top of `connect.sh`. An address passed
on the command line takes precedence over the saved IP.

## Start automatically when the Pi boots

On the Pi, from this directory:

```bash
sudo bash ./install_autostart.sh
```

The installer copies the server into `/opt/remote-can-receiver`, installs
`rpi-can-stream.service`, and enables and starts it. Run it again to update
the installed scripts; it preserves your existing configuration.

If your CAN interfaces are not already configured at boot, edit:

```bash
sudo nano /etc/default/rpi-can-stream
```

Set `CAN0_BITRATE` and `CAN1_BITRATE` to the actual bitrates of their buses.
You can also change `PORT` here. Apply changes and check startup:

```bash
sudo systemctl restart rpi-can-stream
sudo systemctl status rpi-can-stream --no-pager
sudo journalctl -u rpi-can-stream -f
```

At startup, the service configures and brings up down CAN interfaces.
Interfaces already up keep their existing settings. It retries every
five seconds if startup fails, including when CAN devices are not ready
yet. Stop any manually launched Pi stream before enabling this service
so that TCP port 5000 is available.

To stop it and disable autostart:

```bash
sudo systemctl disable --now rpi-can-stream
```

## Any PC: display the stream

With netcat installed, connect to the **Pi**, not a PC address:

```bash
nc lart2026-desktop.local 5000
```

This displays frames from both buses, for example:

```text
(1760000000.123456) can0 123#11223344
(1760000000.123457) can1 456#AABBCCDD
```

The Pi does not send to PCs until they connect. The Wi-Fi network must
allow devices to communicate, and any Pi firewall must allow incoming TCP
on the selected port.

## Windows PC: connect with a batch script

Keep `connect.bat` and `connect.ps1` in the same folder. No netcat or
administrator privileges are required; the launcher uses Windows
PowerShell 5.1 or later.

From Command Prompt, use the Pi's hostname or Wi-Fi IP:

```bat
connect.bat lart2026-desktop.local 5000
```

If `.local` cannot be resolved, find the Pi's Wi-Fi IP with `hostname -I`
on the Pi and pass that IP as the first argument. You can also double-click
`connect.bat`; it prompts for the Pi address and defaults to port 5000.

Both CAN buses appear in the terminal with their original bus names and
timestamps. The viewer reconnects automatically when the connection drops.
Press Ctrl+C to stop. This Windows viewer displays the stream; it does not
create the Linux SocketCAN interfaces used by `connect.sh`.

To run the PowerShell viewer directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\connect.ps1 -Server lart2026-desktop.local -Port 5000
```

## Linux PC: receive through local SocketCAN interfaces

Install the dependencies and start the client:

```bash
sudo apt install can-utils netcat-openbsd iproute2
./connect.sh lart2026-desktop.local
```

In another terminal:

```bash
candump can_remote0 can_remote1
```

Pi `can0` is mapped to `can_remote0`, and Pi `can1` to `can_remote1`.
The client reconnects if the connection drops. These are separate virtual
CAN buses on this PC; original Pi timestamps remain in the raw TCP stream,
but locally forwarded frames get local reception timestamps.

The original `receiver.sh` uses the previous arrangement, where the PC
listens and the Pi initiates the connection. Use `connect.sh` with the new
Pi server.

## Change the port

On the Pi:

```bash
PORT=5001 ./rpi_stream.sh
```

On a PC:

```bash
./connect.sh lart2026-desktop.local 5001
# Or display the raw stream:
nc lart2026-desktop.local 5001
```

## Verify locally

```bash
python3 -m unittest -v test_stream.py
python3 -m unittest -v test_autostart.py
```

The tests simulate the CAN capture and CAN injection tools and use real
TCP connections to verify multiple subscribers and reconnecting clients.
They do not require CAN hardware or sudo.
