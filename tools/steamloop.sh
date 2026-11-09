#!/usr/bin/env bash
# Steam transport loopback gate, one PC, one account: host a real Steam lobby, send packets to our own Steam id over
# Steam P2P and read them back through the normal receive path. Needs Steam running and logged in.
# Usage: tools/steamloop.sh            (one game window for ~35 s, then tools/stop.sh and tools/gate_steam.py)
set -e
cd "$(dirname "$0")/.."
. tools/dvenv.sh
dv_lock
WAIT="${WAIT:-35}"

"$DV_PY" -I tools/build.py          # dev zip: the loopback test is dev-only code
dv_clear_logs "$DV_DATA"

dv_launch "" --enable-mods --coop-host --coop-dev-steam-loop
echo "launched; waiting $WAIT s for the lobby and the loopback result"
sleep "$WAIT"
tools/stop.sh
RUN="$(ls -dt "$DV_INST"/dvcoop-runs/*/ | head -1)"
echo "run: $RUN"
"$DV_PY" -I tools/gate_steam.py "$RUN"/A/dV/logs/dv_log_*.txt
