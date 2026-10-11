#!/usr/bin/env bash
# Two-instance dev loop on one PC over ENet: host uses the real %APPDATA%\dV, guest uses a copy.
# Usage: tools/dev2.sh [guest-save-file]      e.g. tools/dev2.sh savegame-b.dv
set -e
G="/c/Program Files (x86)/Steam/steamapps/common/dV Rings of Saturn"
C="$HOME/AppData/Local/Temp/dvcoop_instC"
SLOT="${1:-savegame.dv}"

cd "$(dirname "$0")/.." && python -I tools/build.py

# seed the guest data dir from the real one (saves + settings, not logs)
mkdir -p "$C/dV"
for f in "$APPDATA/dV"/*; do b=$(basename "$f"); [ "$b" = "logs" ] && continue; cp -r "$f" "$C/dV/"; done
rm -f "$APPDATA/dV/logs"/dv_log_*.txt "$C/dV/logs"/dv_log_*.txt "$APPDATA/dV/logs/engine_log.txt" "$C/dV/logs/engine_log.txt"

cd "$G"
( ./Delta-V.exe --enable-mods --coop-enet-host=7777 --coop-autodive >/dev/null 2>&1 & )
sleep 6
( APPDATA="$(cygpath -w "$C")" ./Delta-V.exe --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-slot="$SLOT" >/dev/null 2>&1 & )
echo "launched. logs:"
echo "  host : $APPDATA/dV/logs/dv_log_*.txt"
echo "  guest: $C/dV/logs/dv_log_*.txt"
echo "  grep -hE 'COOP' <log> | tail"
