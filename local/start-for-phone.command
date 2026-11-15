#!/bin/sh
# Double-click (Mac) or run (Linux) to open Cyclone Watch here AND on phones on the same Wi-Fi.
cd "$(dirname "$0")" && exec python3 cyclone_watch.py --phone "$@"
