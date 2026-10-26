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
# taskkill returns before the processes are gone; the next dev run's dv_lock refuses while any is still open
for _ in $(seq 1 40); do [ "$(dv_running)" -eq 0 ] && break; sleep 0.5; done
# keep the run's logs: the next dev2/dev3 clears them, so a gate read after the lock is released would find nothing
holder="$(cut -d' ' -f1 "$DV_LOCK/owner" 2>/dev/null)"
RUN="$DV_INST/dvcoop-runs/${holder:-unknown}-$(date +%Y%m%d-%H%M%S)"
for d in "$DV_DATA" "$DV_INST"/dvcoop_inst*; do
  # only logs written during this run (an instance dir this run didn't use still holds an old one)
  logs="$(find "$d/dV/logs" -maxdepth 1 -name 'dv_log_*.txt' -newer "$DV_LOCK/owner" 2>/dev/null)"
  [ -n "$logs" ] || continue
  name="$(basename "$d")"; [ "$d" = "$DV_DATA" ] && name=A
  mkdir -p "$RUN/$name/dV/logs" && echo "$logs" | while read -r f; do cp "$f" "$RUN/$name/dV/logs/"; done
done
ls -dt "$DV_INST"/dvcoop-runs/*/ 2>/dev/null | tail -n +31 | xargs -r rm -rf   # keep the newest 30
rm -rf "$DV_LOCK"
echo "stopped; lock released"
[ -d "$RUN" ] && echo "logs kept in $RUN (gate_m4.py \"$RUN\"/*/dV/logs/dv_log_*.txt)"
