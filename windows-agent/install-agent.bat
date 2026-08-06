@echo off
REM Registers the KeyBridge agent as a LOGON SCHEDULED TASK and starts it.
REM Run as Administrator, from the folder containing KeyBridgeAgent.exe.
REM
REM Why not a Windows service that injects: services run in session 0, where
REM SendInput cannot reach the interactive desktop - every injected keystroke
REM is rejected. A logon task runs inside the logged-in user's session, with
REM highest privileges so keystrokes also reach elevated windows.
REM
REM This install cannot reach the lock screen, the sign-in screen or the UAC
REM prompt: those render on a separate desktop (Winlogon) that only a process
REM running ON that desktop can inject into. For that, use the tray menu's
REM "Turn on lock screen support..." (or install-lockscreen.bat), which adds a
REM supervising service that spawns a helper per desktop.

setlocal
set TASK_NAME=KeyBridgeAgent
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

REM Clean up a service left over from the old (broken) service-based install.
sc query KeyBridgeAgent >nul 2>&1
if %errorlevel% equ 0 (
    echo Removing old KeyBridgeAgent Windows service...
    sc stop KeyBridgeAgent >nul 2>&1
    sc delete KeyBridgeAgent >nul 2>&1
)

REM Lock screen support, if it is on, owns the port. Exactly one of the two may
REM run, and asking for the logon task means asking for the in-session agent.
sc query KeyBridgeSecureAgent >nul 2>&1
if %errorlevel% equ 0 (
    echo Turning off lock screen support first ^(it would fight for the port^)...
    sc stop KeyBridgeSecureAgent >nul 2>&1
    sc delete KeyBridgeSecureAgent >nul 2>&1
    timeout /t 2 /nobreak >nul 2>&1
)

echo Registering logon task "%TASK_NAME%"...
schtasks /Create /TN "%TASK_NAME%" /TR "\"%BIN_PATH%\"" /SC ONLOGON /RL HIGHEST /F
if %errorlevel% neq 0 (
    echo Failed to create the task.
    pause
    exit /b 1
)

REM schtasks defaults would stop the agent after 72 hours and refuse to run
REM on battery - both wrong for an input bridge that must simply stay up.
REM Only PowerShell's task cmdlets can clear them.
echo Removing the 72-hour run limit and battery restrictions...
powershell -NoProfile -Command "Set-ScheduledTask -TaskName '%TASK_NAME%' -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)" >nul
if %errorlevel% neq 0 (
    echo Warning: could not adjust task settings; the agent will be stopped
    echo after 72 hours of uptime until the next logon.
)

echo Starting agent...
schtasks /Run /TN "%TASK_NAME%"

echo.
echo Done. The agent is running now and starts automatically at every logon.
pause
endlocal
