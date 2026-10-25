"""M4 gate 1: count the DevBot race lines in dev3 logs and check every trial had exactly one owner.

Usage: python tools/gate_race.py <log glob> [<log glob> ...]
       e.g. python tools/gate_race.py ~/dvcoop-data/dV/logs/dv_log_*.txt "$TEMP/dvcoop_inst*/dV/logs/dv_log_*.txt"

A trial passes when: exactly one member logged result=granted; every other member logged result=denied:*; the
authority's "after claims" owner is the granted member's peer id; its "after release" owner is the authority itself.
Prints one line per failed trial and a summary; exit 1 if any trial failed or none were found.
"""
import sys, re, glob, os

def peer_of(path):
    # the instance's own peer id, from its transport line
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.search(r"COOP: ENet connected to server, I am (\d+)", line) or re.search(r"Steam ready, I am (\d+)", line)
        if m:
            return int(m.group(1))
    return None

def main(globs):
    files = sorted({f for g in globs for f in glob.glob(os.path.expanduser(g))})
    trials = {}   # n -> {"granted": [peer], "denied": [(peer, why)], "missing": [peer], "claims": owner, "release": owner, "auth": peer}
    for f in files:
        me = peer_of(f)
        for line in open(f, encoding="utf-8", errors="replace"):
            m = re.search(r"COOP: BOT race trial=(\d+) id=(\S+) result=(\S+)", line)
            if m:
                t = trials.setdefault(int(m.group(1)), {"granted": [], "denied": [], "missing": []})
                r = m.group(3)
                if r == "granted":
                    t["granted"].append(me)
                elif r.startswith("denied"):
                    t["denied"].append((me, r.split(":", 1)[-1]))
                else:
                    t["missing"].append(me)
                continue
            m = re.search(r"COOP: BOT race trial=(\d+) id=(\S+) after (claims|release) owner=(-?\d+)", line)
            if m:
                t = trials.setdefault(int(m.group(1)), {"granted": [], "denied": [], "missing": []})
                t[m.group(3)] = int(m.group(4))
                t["auth"] = me
    bad = 0
    reasons = {}
    for n in sorted(trials):
        t = trials[n]
        for _, why in t["denied"]:
            reasons[why] = reasons.get(why, 0) + 1
        problems = []
        if len(t["granted"]) != 1:
            problems.append("%d granted" % len(t["granted"]))
        if t["missing"]:
            problems.append("missing on %s" % t["missing"])
        if "claims" in t and len(t["granted"]) == 1 and t["claims"] != t["granted"][0]:
            problems.append("authority says owner %s, granted %s" % (t["claims"], t["granted"][0]))
        if "release" in t and t["release"] != t.get("auth"):
            problems.append("owner after release %s, not the authority %s" % (t["release"], t.get("auth")))
        if "claims" not in t or "release" not in t:
            problems.append("authority check lines missing")
        if problems:
            bad += 1
            print("trial %d FAIL: %s" % (n, "; ".join(problems)))
    print("gate 1 race: %d trials, %d failed, deny reasons %s" % (len(trials), bad, reasons))
    return 1 if bad or not trials else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
