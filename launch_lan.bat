@echo off
rem Two-PC LAN co-op: launch_lan.bat <other PC's IP address>   (see launch_lan.ps1)
if "%~1"=="" (
  echo Usage: launch_lan.bat ^<other PC's IP address^>
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_lan.ps1" -PeerIp %1
