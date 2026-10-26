#!/usr/bin/env bash
# M5 joining-flow loop on one PC over ENet. Like dev3.sh, a relay R stays at the title and never dives; the players:
#   A: ~/dvcoop-data (or its own copy with RES_A), joins the relay and auto-dives at the dev target: the friend
#      already out in the ring
#   B: copy, starts at the TITLE SCREEN with --coop-dev-enet pointing the co-op panel at the relay, and nothing else:
#      the flow under test is driven by EXTRA_B (--coop-dev-ui, --coop-dev-dive-friend, ...)
#   C: copy (only with WITH_C=1), joins the relay and auto-dives OFF_C px off A (default 2,000,000: 200 km, past the
#      astrogator's 150 km minimum), for --coop-dev-plot-friend in EXTRA_C
# EXTRA_A / EXTRA_B / EXTRA_C add flags; RES_* / UI_* set a window size and UI scale per instance (tools/setres.py).
# At most 4 windows (R, A, B, C). Stop with tools/stop.sh.
set -e
cd "$(dirname "$0")/.."
. tools/dvenv.sh
dv_lock
R="$DV_INST/dvcoop_instR"
B="$DV_INST/dvcoop_instB"
C=""; [ -n "$WITH_C" ] && C="$DV_INST/dvcoop_instC"
A=""; [ -n "$RES_A" ] && A="$DV_INST/dvcoop_instA"
OFF_C="${OFF_C:-2000000}"
DIVE_X="${DIVE_X:-150000}"
DIVE_Y="${DIVE_Y:-0}"

"$DV_PY" -I tools/build.py

dv_seed "$R"
[ -n "$A" ] && dv_seed "$A"
dv_seed "$B"
[ -n "$C" ] && dv_seed "$C"
dv_clear_logs "$DV_DATA" ${A:+"$A"} "$R" "$B" ${C:+"$C"}
SR=tools/setres.py
[ -n "$RES_A" ] && "$DV_PY" -I $SR "$A/dV/settings.cfg" $RES_A ${UI_A:-0.9}
[ -n "$RES_B" ] && "$DV_PY" -I $SR "$B/dV/settings.cfg" $RES_B ${UI_B:-0.9}
[ -n "$RES_C" ] && [ -n "$C" ] && "$DV_PY" -I $SR "$C/dV/settings.cfg" $RES_C ${UI_C:-0.9}

dv_launch "$R" --enable-mods --coop-enet-host=7777
sleep 6
dv_launch "$A" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=$DIVE_X,$DIVE_Y --coop-dev-name=A $EXTRA_A
sleep 6
dv_launch "$B" --enable-mods --coop-dev-enet=127.0.0.1:7777 --coop-dev-name=B $EXTRA_B
if [ -n "$C" ]; then
  sleep 6
  dv_launch "$C" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-dive-offset=$DIVE_X,$((DIVE_Y + OFF_C)) --coop-slot=savegame.dv --coop-dev-name=C $EXTRA_C
fi
echo "launched R (relay), A (in the ring), B (title)${C:+, C (+$OFF_C)}. logs:"
echo "  A: ${A:-$DV_DATA}/dV/logs/dv_log_*.txt"
echo "  B: $B/dV/logs/dv_log_*.txt"
[ -n "$C" ] && echo "  C: $C/dV/logs/dv_log_*.txt"
exit 0
