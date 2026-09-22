#Requires -Version 5.1
<#
.SYNOPSIS
    Feeds the Raspberry Pi CAN stream into cangaroo's CANblaster driver.

.DESCRIPTION
    Reads the Pi's read-only TCP stream (candump -L text) and re-emits the
    frames as CANblaster UDP datagrams on this PC, so cangaroo can pick
    Measurement > Driver > CANblaster and show live frames. Nothing is ever
    sent back to the Pi's physical CAN buses.

    CANblaster wire protocol, as implemented by cangaroo in
    src/driver/CANBlastDriver:
      * the server multicasts {"protocol":"CANblaster", "version":1} to
        239.255.43.21:20000 so cangaroo can discover it,
      * cangaroo sends a "Heartbeat" datagram to <server>:20002 every second,
      * the server sends every frame as a 16-byte SocketCAN struct can_frame
        to each heartbeating client on UDP port 20001.

    The parsing and forwarding loop is compiled C# so that busy buses keep up;
    Windows PowerShell 5.1 is the only requirement.

.EXAMPLE
    .\cangaroo.ps1 lart2026-desktop.local

.EXAMPLE
    .\cangaroo.ps1 192.168.1.50 -Bus can1
#>
param(
    [ValidateNotNullOrEmpty()]
    [string]$Server = $(if ($env:RPI_CAN_SERVER) { $env:RPI_CAN_SERVER } else { 'lart2026-desktop.local' }),

    [ValidateRange(1, 65535)]
    [int]$Port = $(if ($env:RPI_CAN_PORT) { $env:RPI_CAN_PORT } else { 5000 }),

    # cangaroo shows one interface per server, so both Pi buses arrive on the
    # same channel unless a single bus is selected here.
    [ValidateSet('both', 'can0', 'can1')]
    [string]$Bus = 'both',

    # Extra unicast announce target. Use 127.0.0.1 when cangaroo runs on this
    # PC and multicast discovery is blocked by the network or a firewall.
    [string]$Announce,

    # Generate test frames instead of connecting to the Pi.
    [switch]$Simulate
)

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class CanBlasterBridge
{
    private const int DiscoveryPort = 20000;
    private const int FramePort = 20001;
    private const int HeartbeatPort = 20002;
    private const int ClientTimeoutSeconds = 5;

    private static readonly byte[] Beacon =
        Encoding.ASCII.GetBytes("{\"protocol\":\"CANblaster\", \"version\":1}");
    private static readonly IPEndPoint Group =
        new IPEndPoint(IPAddress.Parse("239.255.43.21"), DiscoveryPort);

    private readonly string _server;
    private readonly int _port;
    private readonly string _bus;          // null forwards both buses
    private readonly IPEndPoint _announce; // optional unicast discovery target
    private readonly bool _simulate;

    private readonly Socket _tx = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
    private readonly Socket _discovery = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
    private readonly Socket _heartbeats = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
    private readonly Dictionary<string, DateTime> _clients = new Dictionary<string, DateTime>();
    private readonly byte[] _frame = new byte[16];

    private volatile IPEndPoint[] _targets = new IPEndPoint[0];
    private volatile bool _stop;
    private long _frames;
    private long _skippedFd;
    // Both buses share one cangaroo channel, so the status line is the only
    // place where they stay apart.
    private readonly Dictionary<string, long> _perBus = new Dictionary<string, long>();

    public CanBlasterBridge(string server, int port, string bus, string announce, bool simulate)
    {
        _server = server;
        _port = port;
        _bus = (bus == "both") ? null : bus;
        _simulate = simulate;
        if (!String.IsNullOrEmpty(announce))
        {
            _announce = new IPEndPoint(IPAddress.Parse(announce), DiscoveryPort);
        }

        _discovery.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 2);
        _discovery.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastLoopback, true);
        _heartbeats.Bind(new IPEndPoint(IPAddress.Any, HeartbeatPort));
        try
        {
            // Keep a closed cangaroo from breaking this socket with ICMP replies.
            _heartbeats.IOControl(unchecked((int)0x9800000C), new byte[4], null);
        }
        catch (Exception) { }
    }

    public void Run()
    {
        Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e)
        {
            _stop = true;
            e.Cancel = true;
        };

        Thread keeper = new Thread(Housekeeping);
        keeper.IsBackground = true;
        keeper.Start();

        while (!_stop)
        {
            if (_simulate) { Simulate(); continue; }

            try
            {
                Console.WriteLine("[INFO] Connecting to {0}:{1}...", _server, _port);
                using (TcpClient client = new TcpClient())
                {
                    client.Connect(_server, _port);
                    client.ReceiveTimeout = 1000;
                    Console.WriteLine("[INFO] Connected to the Pi. Waiting for CAN frames...");

                    using (StreamReader reader = new StreamReader(client.GetStream(), Encoding.ASCII))
                    {
                        while (!_stop)
                        {
                            string line;
                            try { line = reader.ReadLine(); }
                            catch (IOException) { continue; } // idle bus: receive timeout
                            if (line == null)
                            {
                                Console.WriteLine("[WARNING] Pi closed the connection.");
                                break;
                            }
                            Forward(line);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("[WARNING] " + ex.Message);
            }

            if (_stop) { break; }
            Console.WriteLine("[INFO] Reconnecting in 2 seconds...");
            Thread.Sleep(2000);
        }

        _tx.Close();
        _discovery.Close();
        _heartbeats.Close();
        Console.WriteLine("[INFO] Bridge stopped.");
    }

    // Turns one candump -L line into a struct can_frame and sends it to every
    // cangaroo instance that is currently heartbeating.
    private void Forward(string line)
    {
        string[] fields = line.Split(' ');
        if (fields.Length < 3) { return; }
        if (_bus != null && fields[1] != _bus) { return; }

        string body = fields[2];
        int hash = body.IndexOf('#');
        if (hash < 1) { return; }
        if (hash + 1 < body.Length && body[hash + 1] == '#')
        {
            _skippedFd++; // the CANblaster driver in cangaroo is classic-CAN only
            return;
        }

        uint id;
        if (!UInt32.TryParse(body.Substring(0, hash), NumberStyles.HexNumber,
                             CultureInfo.InvariantCulture, out id)) { return; }
        if (hash > 3) { id |= 0x80000000; } // CAN_EFF_FLAG

        Array.Clear(_frame, 0, _frame.Length);
        int length = 0;
        string payload = body.Substring(hash + 1);
        if (payload.Length > 0 && (payload[0] == 'R' || payload[0] == 'r'))
        {
            id |= 0x40000000; // CAN_RTR_FLAG
            if (payload.Length > 1) { Int32.TryParse(payload.Substring(1), out length); }
            if (length > 8) { length = 8; }
        }
        else
        {
            length = Math.Min(payload.Length / 2, 8);
            for (int i = 0; i < length; i++)
            {
                int high = Nibble(payload[i * 2]);
                int low = Nibble(payload[i * 2 + 1]);
                if (high < 0 || low < 0) { return; }
                _frame[8 + i] = (byte)((high << 4) | low);
            }
        }

        _frame[0] = (byte)id;
        _frame[1] = (byte)(id >> 8);
        _frame[2] = (byte)(id >> 16);
        _frame[3] = (byte)(id >> 24);
        _frame[4] = (byte)length;

        IPEndPoint[] targets = _targets;
        for (int i = 0; i < targets.Length; i++)
        {
            try { _tx.SendTo(_frame, 0, _frame.Length, SocketFlags.None, targets[i]); }
            catch (SocketException) { }
        }
        _frames++;

        lock (_perBus)
        {
            long seen;
            _perBus.TryGetValue(fields[1], out seen);
            _perBus[fields[1]] = seen + 1;
        }
    }

    private static int Nibble(char c)
    {
        if (c >= '0' && c <= '9') { return c - '0'; }
        if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
        if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
        return -1;
    }

    private void Simulate()
    {
        long counter = 0;
        Console.WriteLine("[INFO] Simulating frames; not connecting to the Pi.");
        while (!_stop)
        {
            Forward(String.Format("(0.000000) can0 {0:X3}#{1:X16}", 0x100 + (counter % 8), counter));
            counter++;
            Thread.Sleep(100);
        }
    }

    // Announces this bridge, tracks heartbeating cangaroo instances and prints
    // status, on its own thread so that frame forwarding is never delayed.
    private void Housekeeping()
    {
        DateTime lastBeacon = DateTime.MinValue;
        DateTime lastStatus = DateTime.UtcNow;
        byte[] scratch = new byte[1024];

        while (!_stop)
        {
            DateTime now = DateTime.UtcNow;

            if ((now - lastBeacon).TotalSeconds >= 1)
            {
                lastBeacon = now;
                try { _discovery.SendTo(Beacon, Group); } catch (SocketException) { }
                if (_announce != null)
                {
                    try { _discovery.SendTo(Beacon, _announce); } catch (SocketException) { }
                }
            }

            while (_heartbeats.Available > 0)
            {
                EndPoint sender = new IPEndPoint(IPAddress.Any, 0);
                try { _heartbeats.ReceiveFrom(scratch, ref sender); }
                catch (SocketException) { break; }

                string address = ((IPEndPoint)sender).Address.ToString();
                if (!_clients.ContainsKey(address))
                {
                    Console.WriteLine("[INFO] cangaroo connected from {0}.", address);
                }
                _clients[address] = DateTime.UtcNow;
            }

            List<string> expired = new List<string>();
            foreach (KeyValuePair<string, DateTime> client in _clients)
            {
                if ((now - client.Value).TotalSeconds > ClientTimeoutSeconds) { expired.Add(client.Key); }
            }
            foreach (string address in expired)
            {
                Console.WriteLine("[INFO] cangaroo at {0} stopped measuring.", address);
                _clients.Remove(address);
            }

            if (_targets.Length != _clients.Count)
            {
                List<IPEndPoint> targets = new List<IPEndPoint>();
                foreach (string address in _clients.Keys)
                {
                    targets.Add(new IPEndPoint(IPAddress.Parse(address), FramePort));
                }
                _targets = targets.ToArray();
            }

            if ((now - lastStatus).TotalSeconds >= 5)
            {
                lastStatus = now;
                StringBuilder buses = new StringBuilder();
                lock (_perBus)
                {
                    foreach (KeyValuePair<string, long> bus in _perBus)
                    {
                        buses.Append("  ").Append(bus.Key).Append(": ").Append(bus.Value);
                    }
                }
                Console.WriteLine("[INFO] clients: {0}  frames: {1}{2}{3}", _clients.Count, _frames, buses,
                    _skippedFd > 0 ? "  skipped CAN FD: " + _skippedFd : "");
            }

            Thread.Sleep(100);
        }
    }
}
'@

if (-not ('CanBlasterBridge' -as [type])) {
    Add-Type -TypeDefinition $source -Language CSharp
}

Write-Host '[INFO] CANblaster bridge for cangaroo. Press Ctrl+C to stop.'
Write-Host '[INFO] In cangaroo: Measurement > Driver > CANblaster, then Setup...,'
Write-Host '[INFO] Reload Interfaces, select this PC, OK, and press F5.'
if ($Bus -ne 'both') { Write-Host ('[INFO] Forwarding only {0}.' -f $Bus) }

$bridge = New-Object CanBlasterBridge $Server, $Port, $Bus, $Announce, ([bool]$Simulate)
$bridge.Run()
