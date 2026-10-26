"""The whole M4 gate, one command: every phase is one dev3 run (4 windows, under 10 minutes), scored by gate_m4.py on
the logs stop.sh keeps, with savecheck before/after. Prints one PASS/FAIL table at the end.

Usage: DV_WHO=<you> python tools/m4_final.py [phase ...]      (default: every phase, in table order)

A phase is staged by the EXTRA_A/B/C flags and dev3 env in PHASES and ends when its `until` log pattern shows up on
the named instance (or at its time limit). The real-arm phases (2r, 3/4, 10r) come from tools/gate_arm.py.
Announce every launch to the lead first (game window rules); this script prints the line to send.
"""
import os, re, sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_arm as ga

# name: (gates, dev3 env, extra flags per instance, (instance, log pattern that ends the phase), time limit s)
PHASES = {
    "pause": ("11,11b,12",
              {"OFF_B": "1200", "WARP_C_DIST": "300"},
              {"A": "--coop-dev-view --coop-dev-menu-quit=70,member --coop-dev-menu-quit=100,auth",
               "B": "--coop-dev-view --coop-dev-pause=10 --coop-dev-menu-quit=100,auth",
               "C": "--coop-dev-view"},
              ("ABC", r"COOP: NPC dev: menu quit to title as auth"), 6 * 60),
    # Own track (tim-58) and Ships track (tim-06) phases go here: gates 1, 5, 6 and 7, 8, 9, 9b, 9c
}


def run_phase(name):
    gates, env, extra, (insts, until), limit = PHASES[name]
    saved = dict(ga.BASE)
    ga.BASE.update(env)
    try:
        ga.launch(name, extra)
        hit = ga.wait_for(lambda: any(ga.grep(i, until) for i in insts), limit, 5)
        ga.log("phase %s %s" % (name, "reached its end marker" if hit else "cut at the time limit"))
        time.sleep(10)
        return ga.stop(name, gates)
    finally:
        ga.BASE.clear()
        ga.BASE.update(saved)


def main(argv):
    if not ga.WHO:
        raise SystemExit("set DV_WHO (the game lock holder name)")
    order = argv or list(PHASES) + ["arm"]
    res = {}
    for name in order:
        if name == "arm":
            res["arm (2r, 3, 4, 10r)"] = ga.main([]) == 0
        else:
            res[name] = run_phase(name)
    print()
    print("M4 final gate")
    for name, ok in res.items():
        print("  %-22s %s" % (name, "PASS" if ok else "FAIL"))
    ok = all(res.values())
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
