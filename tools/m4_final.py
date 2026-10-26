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

# name: (gates, dev3 env, extra flags per instance, (instances, log pattern that ends the phase), time limit s
#        [, seconds to keep running after the end marker, default 10])
PHASES = {
    "pause": ("11,11b,12",
              {"OFF_B": "1200", "WARP_C_DIST": "300"},
              {"A": "--coop-dev-view --coop-dev-menu-quit=70,member --coop-dev-menu-quit=100,auth",
               "B": "--coop-dev-view --coop-dev-pause=10 --coop-dev-menu-quit=100,auth",
               "C": "--coop-dev-view"},
              ("ABC", r"COOP: NPC dev: menu quit to title as auth"), 6 * 60),
    # Ships track (tim-06), staged as the passing runs m4ships3..7
    "ships": ("7,8,9",
              {"DIVE_X": "0", "OFF_B": "1500", "WARP_C": "50", "WARP_C_DIST": "3000"},
              {"A": "--coop-dev-fireall=15 --coop-dev-pirate=30 --coop-dev-shoot=10",
               "B": "--coop-dev-fireall=15 --coop-dev-pirate=30 --coop-dev-shoot=10 --coop-dev-explode=110",
               "C": "--coop-dev-story-npc --coop-dev-shoot=10"},
              ("B", r"COOP: NPC s\.die sent"), 6 * 60),
    "death-member": ("7,8",   # the authority simulates a member's blast
              {"DIVE_X": "0", "OFF_B": "1500"},
              {"A": "--coop-dev-fireall=15,270 --coop-dev-explode-member=290",
               "B": "--coop-dev-fireall=15,270 --coop-dev-explode-member=290",
               "C": ""},
              ("AB", r"COOP: NPC s\.die sent"), 8 * 60),
    "npc-pod": ("9b",
              {"DIVE_X": "0", "OFF_B": "1500"},
              {"A": "--coop-dev-pirate=15 --coop-dev-kill-npc=20",
               "B": "--coop-dev-pirate=15 --coop-dev-kill-npc=20",
               "C": ""},
              ("AB", r"COOP: NPC dev: blowing up NPC"), 4 * 60),
    "oddity": ("9c",          # DIVE_X 150000: stock undriftPoi
              {"DIVE_X": "150000", "OFF_B": "1500", "WARP_C": "90", "WARP_C_DIST": "3000"},
              {"A": "", "B": "", "C": "--coop-dev-poi=Addlet --coop-dev-return=20"},
              ("C", r"COOP: NPC dev: returned to"), 6 * 60, 30),
    # Own track (tim-58), from m4-race1 / m4-gate5 / m4-gate6; the mass driver moved to C on savegame-b.dv (EMD-14)
    # since bots no longer fit anything
    "race": ("1",
             {"OFF_B": "1200", "WARP_C_DIST": "900"},
             {"A": "--coop-bot=race,100", "B": "--coop-bot=race,100", "C": "--coop-bot=race,100"},
             ("AB", r"COOP: BOT race done, \d+ trials sent"), 9 * 60),
    "shoot": ("5,6",
              {"OFF_B": "1200", "WARP_C_DIST": "900"},
              {"A": "--coop-bot=laser,4", "B": "--coop-bot=laser,4",
               "C": "--coop-slot=savegame-b.dv --coop-bot=massdriver,4"},
              ("C", r"COOP: BOT massdriver done, \d+ trials"), 7 * 60),
    # B and C both load the arm save (slot d TRTL: haul drones, salvage arm as the excavator) and run the haul bot:
    # only one of A, B, C is the cell authority (lowest peer id), so at least one of B and C is a member and runs it
    # (the authority's bot logs "haul idle"). The phase ends when one of them is done.
    "haul": ("haul,memberfrac",
             {"OFF_B": "1200", "WARP_C_DIST": "900"},
             {"B": "--coop-slot=savegame-arm.dv --coop-bot=haul,3",
              "C": "--coop-slot=savegame-arm.dv --coop-bot=haul,3"},
             ("BC", r"COOP: BOT haul done, \d+ trials"), 7 * 60),
}


def run_phase(name):
    gates, env, extra, (insts, until), limit = PHASES[name][:5]
    after = PHASES[name][5] if len(PHASES[name]) > 5 else 10
    saved = dict(ga.BASE)
    ga.BASE.update(env)
    try:
        ga.launch(name, extra)
        hit = ga.wait_for(lambda: any(ga.grep(i, until) for i in insts), limit, 5)
        ga.log("phase %s %s" % (name, "reached its end marker" if hit else "cut at the time limit"))
        time.sleep(after)
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
