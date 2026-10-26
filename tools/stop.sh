#!/usr/bin/env bash
# Stop every dev instance of the game and release the game lock taken by dev2.sh / dev3.sh.
# Only the lock's holder may do this (DV_WHO must match); --force stops someone else's run.
cd "$(dirname "$0")/.."
. tools/dvenv.sh
if [ -d "$DV_LOCK" ] && [ "$1" != --force ]; then
  holder="$(cut -d' ' -f1 "$DV_LOCK/owner" 2>/dev/null)"
  if [ "$holder" != "${DV_WHO:-$(pwd)}" ]; then
    echo "not stopping: the game is held by $holder (you are ${DV_WHO:-$(pwd)}). Use --force only if that run is dead." >&2
    exit 2
  fi
fi
if [ "$DV_OS" = windows ]; then
  taskkill //IM Delta-V.exe //F >/dev/null 2>&1 || true
else
  pkill -f "$DV_EXE" 2>/dev/null || true
fi
rm -rf "$DV_LOCK"
echo "stopped; lock released"
