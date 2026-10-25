#!/usr/bin/env bash
# Three-player dev loop on one PC over ENet. A fourth instance R is the ENet server and relay only: it stays
# at the title screen and never dives, so any player can quit without taking the others' links down (the
# Steam transport is a mesh and has no such single point).
#   A: ~/dvcoop-data, dives at the dev target
#   B: copy, dives 5,000 px off (in range of A)
#   C: copy, dives OFFSET_C px off (default 60,000: out of range), then warps to 20,000 px from the
#      lowest-id peer WARP_C seconds after its dive starts (WARP_C=0 turns the warp off)
# Works on Windows (Git Bash) and Linux; paths come from tools/dvenv.sh. Stop with tools/stop.sh.
# Usage: tools/dev3.sh [offset_c_x] [slot_b] [slot_c]
set -e
cd "$(dirname "$0")/.."
. tools/dvenv.sh
dv_lock
R="$DV_INST/dvcoop_instR"
B="$DV_INST/dvcoop_instB"
C="$DV_INST/dvcoop_instC"
OFF_C="${1:-60000}"
SLOT_B="${2:-savegame-b.dv}"
SLOT_C="${3:-savegame.dv}"
WARP_C="${WARP_C:-25}"
WARP=(); [ "$WARP_C" != 0 ] && WARP=(--coop-warp-to-peer="$WARP_C")

"$DV_PY" -I tools/build.py

dv_seed "$R"
dv_seed "$B"
dv_seed "$C"
dv_clear_logs "$DV_DATA" "$R" "$B" "$C"

dv_launch "$R" --enable-mods --coop-enet-host=7777
sleep 6
dv_launch "" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive
sleep 6
dv_launch "$B" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=0,5000 --coop-slot="$SLOT_B"
sleep 6
dv_launch "$C" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=0,$OFF_C --coop-slot="$SLOT_C" "${WARP[@]}"
echo "launched R (relay), A, B (+5000), C (+$OFF_C, warp ${WARP_C}s). logs:"
echo "  R: $R/dV/logs/dv_log_*.txt"
echo "  A: $DV_DATA/dV/logs/dv_log_*.txt"
echo "  B: $B/dV/logs/dv_log_*.txt"
echo "  C: $C/dV/logs/dv_log_*.txt"
