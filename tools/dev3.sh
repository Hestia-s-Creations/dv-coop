#!/usr/bin/env bash
# Three-instance dev loop on one PC over ENet (server relays between clients).
#   A: real %APPDATA%\dV, ENet server, dives at the dev target
#   B: copy, client, dives 5,000 px off (in range)
#   C: copy, client, dives OFFSET_C px off (default 60,000: out of range, flies in by hand)
# Usage: tools/dev3.sh [offset_c_x] [slot_b] [slot_c]
set -e
G="/c/Program Files (x86)/Steam/steamapps/common/dV Rings of Saturn"
B="$HOME/AppData/Local/Temp/dvcoop_instB"
C="$HOME/AppData/Local/Temp/dvcoop_instC"
OFF_C="${1:-60000}"
SLOT_B="${2:-savegame-b.dv}"
SLOT_C="${3:-savegame.dv}"

cd "$(dirname "$0")/.." && python -I tools/build.py

for D in "$B" "$C"; do
  mkdir -p "$D/dV"
  for f in "$APPDATA/dV"/*; do b=$(basename "$f"); [ "$b" = "logs" ] && continue; cp -r "$f" "$D/dV/"; done
  rm -f "$D/dV/logs"/dv_log_*.txt "$D/dV/logs/engine_log.txt"
done
rm -f "$APPDATA/dV/logs"/dv_log_*.txt "$APPDATA/dV/logs/engine_log.txt"

cd "$G"
( ./Delta-V.exe --enable-mods --coop-enet-host=7777 --coop-autodive >/dev/null 2>&1 & )
sleep 6
( APPDATA="$(cygpath -w "$B")" ./Delta-V.exe --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=0,5000 --coop-slot="$SLOT_B" >/dev/null 2>&1 & )
sleep 6
( APPDATA="$(cygpath -w "$C")" ./Delta-V.exe --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=0,$OFF_C --coop-slot="$SLOT_C" >/dev/null 2>&1 & )
echo "launched A (server), B (+5000), C (+$OFF_C). logs:"
echo "  A: $APPDATA/dV/logs/dv_log_*.txt"
echo "  B: $B/dV/logs/dv_log_*.txt"
echo "  C: $C/dV/logs/dv_log_*.txt"
