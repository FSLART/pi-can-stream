#Requires -Version 5.1
# Windows viewer for the Raspberry Pi's read-only CAN TCP stream.
param(
    [ValidateNotNullOrEmpty()]
    [string]$Server = $(if ($env:RPI_CAN_SERVER) { $env:RPI_CAN_SERVER } else { 'lart2026-desktop.local' }),

    [ValidateRange(1, 65535)]
    [int]$Port = $(if ($env:RPI_CAN_PORT) { $env:RPI_CAN_PORT } else { 5000 })
)

$ErrorActionPreference = 'Stop'
Write-Host '[INFO] Displaying both can0 and can1. Press Ctrl+C to stop.'
Write-Host '[INFO] If the hostname does not resolve, use the Raspberry Pi Wi-Fi IP.'

while ($true) {
    $client = $null
    $reader = $null
    try {
        Write-Host ('[INFO] Connecting to {0}:{1}...' -f $Server, $Port)
        $client = [System.Net.Sockets.TcpClient]::new()
        $connecting = $client.ConnectAsync($Server, $Port)
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $connecting.IsCompleted) {
            if ($timer.ElapsedMilliseconds -ge 5000) {
                throw 'Connection timed out after 5 seconds.'
            }
            Start-Sleep -Milliseconds 100
        }
        $connecting.GetAwaiter().GetResult()
        Write-Host '[INFO] Connected. Waiting for CAN frames...'

        $reader = [System.IO.StreamReader]::new(
            $client.GetStream(), [System.Text.Encoding]::ASCII
        )
        while ($true) {
            $reading = $reader.ReadLineAsync()
            # Polling allows Ctrl+C to stop the viewer even while CAN is idle.
            while (-not $reading.IsCompleted) {
                Start-Sleep -Milliseconds 100
            }
            $line = $reading.GetAwaiter().GetResult()
            if ($null -eq $line) {
                Write-Host '[WARNING] Pi closed the connection.'
                break
            }
            Write-Output $line
        }
    }
    catch {
        Write-Host ('[WARNING] {0}' -f $_.Exception.GetBaseException().Message)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
    }

    Write-Host '[INFO] Reconnecting in 2 seconds...'
    Start-Sleep -Seconds 2
}
