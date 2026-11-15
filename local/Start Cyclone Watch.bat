@echo off
rem Double-click to open Cyclone Watch in your browser (Windows).
cd /d "%~dp0"
where py >nul 2>nul && (py -3 cyclone_watch.py %*) || (python cyclone_watch.py %*)
pause
