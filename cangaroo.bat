@echo off
setlocal DisableDelayedExpansion

REM If hostname lookup fails, put the Pi Wi-Fi IP between the quotes below.
set "RPI_CAN_IP="

set "RPI_CAN_SERVER=%~1"
set "RPI_CAN_PORT=%~2"
if not defined RPI_CAN_SERVER if defined RPI_CAN_IP set "RPI_CAN_SERVER=%RPI_CAN_IP%"
if not defined RPI_CAN_SERVER (
    set /p "RPI_CAN_SERVER=Raspberry Pi IP or hostname [lart2026-desktop.local]: "
)
if not defined RPI_CAN_SERVER set "RPI_CAN_SERVER=lart2026-desktop.local"
if not defined RPI_CAN_PORT set "RPI_CAN_PORT=5000"

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell is required.
    exit /b 1
)
if not exist "%~dp0cangaroo.ps1" (
    echo [ERROR] Keep cangaroo.ps1 in the same folder as cangaroo.bat.
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0cangaroo.ps1"
exit /b %errorlevel%
