@echo off
setlocal DisableDelayedExpansion

set "RPI_CAN_SERVER=%~1"
set "RPI_CAN_PORT=%~2"
if not defined RPI_CAN_SERVER (
    set /p "RPI_CAN_SERVER=Raspberry Pi IP or hostname [raspberrypi.local]: "
)
if not defined RPI_CAN_SERVER set "RPI_CAN_SERVER=raspberrypi.local"
if not defined RPI_CAN_PORT set "RPI_CAN_PORT=5000"

where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell is required.
    exit /b 1
)
if not exist "%~dp0connect.ps1" (
    echo [ERROR] Keep connect.ps1 in the same folder as connect.bat.
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect.ps1"
exit /b %errorlevel%
