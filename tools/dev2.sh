#!/usr/bin/env bash
# Two-instance dev loop on one PC over ENet: host uses the real user data, guest uses a copy.
# Works on Windows (Git Bash) and Linux; paths come from tools/dvenv.sh.
# Usage: tools/dev2.sh [guest-save-file]      e.g. tools/dev2.sh savegame-b.dv
set -e
cd "$(dirname "$0")/.."
. tools/dvenv.sh
C="$DV_INST/dvcoop_instC"
SLOT="${1:-savegame.dv}"

"$DV_PY" -I tools/build.py

dv_seed "$C"
dv_clear_logs "$DV_DATA" "$C"

dv_launch "" --enable-mods --coop-enet-host=7777 --coop-autodive
sleep 6
dv_launch "$C" --enable-mods --coop-enet-join=127.0.0.1:7777 --coop-autodive --coop-slot="$SLOT"
echo "launched. logs:"
echo "  host : $DV_DATA/dV/logs/dv_log_*.txt"
echo "  guest: $C/dV/logs/dv_log_*.txt"
echo "  grep -hE 'COOP' <log> | tail"
