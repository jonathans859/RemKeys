@echo off
REM Turns ON lock screen support: replaces the logon scheduled task with a
REM LocalSystem service that starts before sign-in and puts an injector helper
REM on every desktop, including the secure one (lock screen, sign-in screen,
REM UAC prompt).
REM
REM Same thing as "Turn on lock screen support..." in the tray menu; this is
REM the recovery path for when there is no tray to click.
REM
REM Run as Administrator, from the folder containing KeyBridgeAgent.exe.
REM
REM Note: while this is on, anyone who can reach this PC over Tailscale can
REM type at the lock screen. The listener therefore refuses connections from
REM loopback and from non-Tailscale addresses unless appsettings.json opts in.

setlocal
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

echo Installing lock screen support...
start /wait "" "%BIN_PATH%" --install-service

echo.
echo Done. The agent reports the outcome in a dialog and in its log file.
pause
endlocal
