#!/usr/bin/env bash
# Stop every dev instance of the game and release the game lock taken by dev2.sh / dev3.sh.
cd "$(dirname "$0")/.."
. tools/dvenv.sh
if [ "$DV_OS" = windows ]; then
  taskkill //IM Delta-V.exe //F >/dev/null 2>&1 || true
else
  pkill -f "$DV_EXE" 2>/dev/null || true
fi
rm -rf "$DV_LOCK"
echo "stopped; lock released"
