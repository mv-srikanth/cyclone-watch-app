#!/bin/sh
# Double-click (Mac) or run ./start-cyclone-watch.command (Linux) to open Cyclone Watch in your browser.
cd "$(dirname "$0")" && exec python3 cyclone_watch.py "$@"
