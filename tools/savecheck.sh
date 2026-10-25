#!/usr/bin/env bash
# Save-file evidence for "nothing is written to anyone else's save": SHA-1 of every savegame*.dv of every dev
# instance, taken before a run and compared after it.
#   tools/savecheck.sh before [label]   record hashes (default label "run")
#   tools/savecheck.sh after  [label]   hash again, print every changed file, exit 1 if any changed
# Covers the main dev data (~/dvcoop-data) and every $DV_INST/dvcoop_inst* data dir. Never touches the real
# %APPDATA%/dV. Take "before" right after dev3.sh launches (the instances only read saves at boot) and "after"
# once tools/stop.sh has run.
cd "$(dirname "$0")/.."
. tools/dvenv.sh
MODE="$1"
LABEL="${2:-run}"
REC="$DV_INST/dvcoop-savecheck-$LABEL.txt"

hashes() {
  for d in "$DV_DATA" "$DV_INST"/dvcoop_inst*; do
    for f in "$d"/dV/savegame*.dv; do
      [ -f "$f" ] && "$DV_PY" -I -c 'import hashlib,sys; print(hashlib.sha1(open(sys.argv[1],"rb").read()).hexdigest(), sys.argv[1])' "$f"
    done
  done
}

case "$MODE" in
  before)
    hashes > "$REC"
    echo "savecheck: recorded $(wc -l < "$REC") save files -> $REC"
    ;;
  after)
    [ -f "$REC" ] || { echo "savecheck: no record $REC; run 'before' first" >&2; exit 2; }
    NOW="$(hashes)"
    CHANGED="$(diff <(sort -k2 "$REC") <(echo "$NOW" | sort -k2) | grep '^>' | cut -c3-)"
    if [ -n "$CHANGED" ]; then
      echo "savecheck: FAIL, changed save files:"
      echo "$CHANGED" | sed 's/^/  /'
      exit 1
    fi
    echo "savecheck: PASS, $(wc -l < "$REC") save files byte-identical"
    ;;
  *)
    echo "usage: tools/savecheck.sh before|after [label]" >&2
    exit 2
    ;;
esac
