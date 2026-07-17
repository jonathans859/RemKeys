@echo off
REM Removes the KeyBridge agent Windows service. Run as Administrator.

setlocal
set SERVICE_NAME=KeyBridgeAgent

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script must be run as Administrator.
    echo Right-click it and choose "Run as administrator".
    pause
    exit /b 1
)

echo Stopping service "%SERVICE_NAME%" (if running)...
sc stop "%SERVICE_NAME%" >nul 2>&1

echo Deleting service "%SERVICE_NAME%"...
sc delete "%SERVICE_NAME%"
if %errorlevel% neq 0 (
    echo Failed to delete the service. It may not be installed.
    pause
    exit /b 1
)

echo.
echo Done. The service has been removed.
pause
endlocal
