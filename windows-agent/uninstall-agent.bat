@echo off
REM Stops the KeyBridge agent and removes its logon scheduled task.
REM Run as Administrator. Also cleans up the old service-based install.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script must be run as Administrator.
    echo Right-click it and choose "Run as administrator".
    pause
    exit /b 1
)

schtasks /End /TN "KeyBridgeAgent" >nul 2>&1
taskkill /IM KeyBridgeAgent.exe /F >nul 2>&1
schtasks /Delete /TN "KeyBridgeAgent" /F >nul 2>&1

REM Old service-based install, if present.
sc stop KeyBridgeAgent >nul 2>&1
sc delete KeyBridgeAgent >nul 2>&1

echo Agent stopped and removed.
pause
