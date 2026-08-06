@echo off
REM Turns OFF lock screen support: removes the LocalSystem service and puts the
REM classic logon scheduled task back, i.e. the agent that runs only while you
REM are signed in.
REM
REM Same thing as "Turn off lock screen support..." in the tray menu.
REM Run as Administrator, from the folder containing KeyBridgeAgent.exe.

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
    pause
    exit /b 1
)

echo Removing lock screen support...
start /wait "" "%BIN_PATH%" --uninstall-service

echo.
echo Done. The agent reports the outcome in a dialog and in its log file.
pause
endlocal
