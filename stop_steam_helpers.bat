@echo off
rem Stops every running co-op Steam helper (coop_steam.py) on this PC.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name like 'python%%'\" | Where-Object { $_.CommandLine -like '*coop_steam*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force; 'stopped helper ' + $_.ProcessId }"
pause
