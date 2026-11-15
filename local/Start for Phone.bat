@echo off
rem Double-click to open Cyclone Watch on this computer AND on phones on the same Wi-Fi (Windows).
cd /d "%~dp0"
where py >nul 2>nul && (py -3 cyclone_watch.py --phone %*) || (python cyclone_watch.py --phone %*)
pause
