@echo off
REM Installs the KeyBridge agent as a Windows service. Run as Administrator.
REM Place this file next to KeyBridgeAgent.exe (the published output).

setlocal
set SERVICE_NAME=KeyBridgeAgent
set DISPLAY_NAME=KeyBridge Agent
set BIN_PATH=%~dp0KeyBridgeAgent.exe

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script must be run as Administrator.
    echo Right-click it and choose "Run as administrator".
    pause
    exit /b 1
)

if not exist "%BIN_PATH%" (
    echo Could not find "%BIN_PATH%".
    echo Build/publish the agent first, then run this from the output folder.
    pause
    exit /b 1
)

echo Installing service "%SERVICE_NAME%"...
sc create "%SERVICE_NAME%" binPath= "\"%BIN_PATH%\"" start= auto DisplayName= "%DISPLAY_NAME%"
if %errorlevel% neq 0 (
    echo Failed to create the service. It may already exist; run uninstall-service.bat first.
    pause
    exit /b 1
)

sc description "%SERVICE_NAME%" "Receives keystrokes from KeyBridge (iOS/macOS) over Tailscale and replays them on this PC."
sc failure "%SERVICE_NAME%" reset= 60 actions= restart/5000/restart/5000/restart/5000

echo Starting service...
sc start "%SERVICE_NAME%"

echo.
echo Done. The service is installed and set to start automatically.
pause
endlocal
