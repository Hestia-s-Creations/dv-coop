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
    # C warps in, briefly takes the cell over and resigns back (--coop-dev-auth-flip, the warp-in hitch of
    # tim-58-20261026-091313); once all three sit in one cell again the authority is hard-killed
    "flip": ("flip",
             {"OFF_B": "1200", "WARP_C_DIST": "900"},
             {"C": "--coop-dev-auth-flip=6"},
             ("C", r"COOP: CELL dev: authority flip"), 5 * 60, 30),
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
    # C warps into the A+B cell, so it is never the authority; A and B both carry a laser (B on its seeded copy of
    # savegame.dv: its default savegame-b.dv has none, and run 064428 drew A as authority: no shooter, no hits), so
    # whichever of them is the authority, the other shoots, and C's mass driver always fires as a member
    "shoot": ("5,6",
              {"OFF_B": "1200", "WARP_C_DIST": "900"},
              {"A": "--coop-bot=laser,4", "B": "--coop-slot=savegame.dv --coop-bot=laser,4",
               "C": "--coop-slot=savegame-b.dv --coop-bot=massdriver,4"},
              ("C", r"COOP: BOT massdriver done, \d+ trials"), 7 * 60),
    # gate 5's relay path, staged: the shooters hold forwarded hits 1.5 s and claim their target 1 s into each trial, so
    # the hits reach the old owner after its grant and must be relayed to the shooter (gate 5: relayed >= 1, lost = 0).
    # Even trials let go 0.2 s after the grant and their o.rel waits 0.7 s (under Own.OWNER_SILENT 1.2 s, past which the
    # authority takes the rock back as lost: run 061759), so relayed hits come back to an authority
    # that still names the shooter and must be held there (gate 5: held >= 1, at most 2 relays per hit)
    "relay": ("5",
              {"OFF_B": "1200", "WARP_C_DIST": "900"},
              {"A": "--coop-bot=laser,6,claim --coop-dev-dmg-delay=1.5 --coop-dev-rel-delay=0.7",
               "B": "--coop-slot=savegame.dv --coop-bot=laser,6,claim --coop-dev-dmg-delay=1.5 --coop-dev-rel-delay=0.7",
               "C": "--coop-bot=laser,6,claim --coop-dev-dmg-delay=1.5 --coop-dev-rel-delay=0.7"},
              ("ABC", r"COOP: BOT laser done, \d+ trials"), 6 * 60, 20),
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
        if hit and name == "flip":
            _kill_authority()
        time.sleep(after)
        return ga.stop(name, gates)
    finally:
        ga.BASE.clear()
        ga.BASE.update(saved)


def _kill_authority():
    """flip: once A, B and C report one cell again (C back as a member after its flip), hard-kill its authority."""
    if not ga.wait_for(lambda: ga.one_cell() and ga.status("C")[0] == "MEMBER", 60, 2):
        ga.log("flip: the three never reported one cell again after the flip; no kill")
        return
    time.sleep(8)   # past RESIGN_GRACE, so only a lasting resignation could still drop the new authority's c.state
    auth = ga.authority()
    who = [i for i in "AB" if ga.peer(i) == auth]
    if not who:
        ga.log("flip: authority %s is not A or B; no kill" % auth)
        return
    ga.kill(who[0])


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
