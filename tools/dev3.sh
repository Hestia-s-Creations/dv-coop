#!/usr/bin/env bash
# Three-instance dev loop on one PC over ENet (server relays between clients).
#   A: real user data, ENet server, dives at the dev target
#   B: copy, client, dives 5,000 px off (in range)
#   C: copy, client, dives OFFSET_C px off (default 60,000: out of range, flies in by hand)
# Works on Windows (Git Bash) and Linux; paths come from tools/dvenv.sh.
# Usage: tools/dev3.sh [offset_c_x] [slot_b] [slot_c]
set -e
cd "$(dirname "$0")/.."
. tools/dvenv.sh
dv_lock
B="$DV_INST/dvcoop_instB"
C="$DV_INST/dvcoop_instC"
OFF_C="${1:-60000}"
SLOT_B="${2:-savegame-b.dv}"
SLOT_C="${3:-savegame.dv}"

"$DV_PY" -I tools/build.py

dv_seed "$B"
dv_seed "$C"
dv_clear_logs "$DV_DATA" "$B" "$C"

dv_launch "" --enable-mods --coop-enet-host=7777 --coop-autodive
sleep 6
dv_launch "$B" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=0,5000 --coop-slot="$SLOT_B"
sleep 6
dv_launch "$C" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=0,$OFF_C --coop-slot="$SLOT_C"
echo "launched A (server), B (+5000), C (+$OFF_C). logs:"
echo "  A: $DV_DATA/dV/logs/dv_log_*.txt"
echo "  B: $B/dV/logs/dv_log_*.txt"
echo "  C: $C/dV/logs/dv_log_*.txt"
