#!/usr/bin/env bash
# Save-file evidence for "nothing is written to anyone else's save": SHA-1 of every savegame*.dv of every dev
# instance, taken before a run and compared after it.
#   tools/savecheck.sh before [label]   record hashes (default label "run")
#   tools/savecheck.sh after  [label]   hash again, print every changed, added or missing file, exit 1 if any
# Covers the main dev data (~/dvcoop-data) and every $DV_INST/dvcoop_inst* data dir except dvcoop_instR (the ENet
# relay at the title screen, not a player). Never touches the real %APPDATA%/dV. Take "before" right after
# dev3.sh launches (dev3 reseeds the instance saves before launching) and "after" once tools/stop.sh has run.
cd "$(dirname "$0")/.."
. tools/dvenv.sh
MODE="$1"
LABEL="${2:-run}"
REC="$DV_INST/dvcoop-savecheck-$LABEL.txt"

dirs() {
  for d in "$DV_DATA" "$DV_INST"/dvcoop_inst*; do
    [ "$(basename "$d")" = dvcoop_instR ] && continue
    [ -d "$d/dV" ] && echo "$d/dV"
  done
}

case "$MODE" in
  before|after)
    # hashing and comparing in Python: no shell line-ending or sort surprises
    "$DV_PY" -I - "$MODE" "$REC" $(dirs) <<'PY'
import glob, hashlib, json, os, sys
mode, rec, dirs = sys.argv[1], sys.argv[2], sys.argv[3:]
now = {}
for d in dirs:
    for f in sorted(glob.glob(os.path.join(d, "savegame*.dv"))):
        now[os.path.normpath(f)] = hashlib.sha1(open(f, "rb").read()).hexdigest()
if mode == "before":
    json.dump(now, open(rec, "w"), indent=1, sort_keys=True)
    print("savecheck: recorded %d save files -> %s" % (len(now), rec))
    sys.exit(0)
if not os.path.exists(rec):
    print("savecheck: no record %s; run 'before' first" % rec)
    sys.exit(2)
was = json.load(open(rec))
bad = []
for f in sorted(set(was) | set(now)):
    if was.get(f) != now.get(f):
        bad.append("  %s  %s -> %s" % (f, was.get(f, "(missing)"), now.get(f, "(missing)")))
if bad:
    print("savecheck: FAIL, %d save file(s) differ:" % len(bad))
    print("\n".join(bad))
    sys.exit(1)
print("savecheck: PASS, %d save files byte-identical" % len(now))
PY
    ;;
  *)
    echo "usage: tools/savecheck.sh before|after [label]" >&2
    exit 2
    ;;
esac
