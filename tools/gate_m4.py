"""M4 gate: read the dev3 logs of every instance and print PASS / FAIL per gate, so the final run is mechanical.

Usage: python tools/gate_m4.py [--gates 7,8,9] <log glob> [<log glob> ...]
       e.g. python tools/gate_m4.py ~/dvcoop-data/dV/logs/dv_log_*.txt "$TEMP/dvcoop_inst*/dV/logs/dv_log_*.txt"

Each log file is one instance (identified by its peer id). Every gate is a function in GATES taking the list of
instances and returning (passed: bool, evidence: [str]); add a gate by writing one and registering it.
Gates 7-9 (Ships track, tim-06) read the COOP: NPC / SHIPS / puppet lines; gates 1-6 and 10 (Own track) are tim-58's.
Save files are checked separately by tools/savecheck.sh (before/after hashes), which every gate run should include.
Exit 1 if any selected gate fails.
"""
import sys, re, glob, os


class Instance:
    def __init__(self, path):
        self.path = path
        self.lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        self.peer = None
        for line in self.lines:
            m = re.search(r"COOP: ENet connected to server, I am (\d+)", line) or re.search(r"Steam ready, I am (\d+)", line)
            if m:
                self.peer = m.group(1)
                break

    def grep(self, pattern):
        rx = re.compile(pattern)
        return [m for m in (rx.search(line) for line in self.lines) if m]

    def count(self, pattern):
        return len(self.grep(pattern))

    def total(self, key):
        # sum of a counter from the Npc 5 s summary, e.g. "ships 5 s: {replayed:170, fxOnly:3}"
        return sum(int(m.group(1)) for m in self.grep(r"COOP: NPC ships 5 s: \{[^}]*\b%s:(\d+)" % re.escape(key)))

    def name(self):
        return "%s (%s)" % (self.peer, os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(self.path)))) or self.path)


# ---------------------------------------------------------------- Ships track (gates 7-9)

def gate7(insts):
    """Puppet inertness: puppets replay their owner's systems, never vanish or drop a pod of their own, and their
    weapon hits are effects only (ships: fxOnly; rocks: rockFxOnly once ext/asteroid.gd reports it)."""
    ev = []
    replayed = {i.name(): i.total("replayed") for i in insts}
    ev.append("puppet system-fires replayed: %s" % replayed)
    ok = sum(replayed.values()) > 0
    for i in insts:
        own_death = i.count(r"COOP: NPC s\.die sent") > 0
        pods = i.count(r"Exploded \[.*\] with lifepod")
        if pods and not own_death:
            ok = False
            ev.append("FAIL %s: %d lifepod(s) without its own ship dying" % (i.name(), pods))
        if i.count(r"COOP: blocked vanish\(\) on puppet"):
            ev.append("note %s: %d vanish() calls on puppets blocked" % (i.name(), i.count(r"COOP: blocked vanish\(\) on puppet")))
    ev.append("hits made effects-only: ships %s, rocks %s" % (
        {i.name(): i.total("fxOnly") for i in insts}, {i.name(): i.total("rockFxOnly") for i in insts}))
    if not ok and sum(replayed.values()) == 0:
        ev.append("FAIL: no puppet replayed anything (was --coop-dev-fireall on?)")
    return ok, ev


def gate8(insts):
    """Ship death: the dying owner sends s.die; every other machine with its puppet plays the explosion; the lifepod
    exists once, on the owner; blast particles are physical on exactly one machine (the rocks' simulator)."""
    ev = []
    dead = [i for i in insts if i.count(r"COOP: NPC s\.die sent")]
    if not dead:
        return False, ["FAIL: nobody's ship died (was --coop-dev-explode[-member] on?)"]
    ok = True
    for d in dead:
        ev.append("%s exploded" % d.name())
        seen = [i for i in insts if i is not d and i.count(r"COOP: NPC s\.die from %s: puppet .* exploding" % d.peer)]
        shown = [i for i in seen if i.count(r"COOP: puppet '.*' exploded")]
        ev.append("  puppet explosion played on %s, finished on %s" % ([i.name() for i in seen], [i.name() for i in shown]))
        others = [i for i in insts if i is not d and i.count(r"COOP: NPC s\.die from %s" % d.peer)]
        if not seen or len(shown) < len(seen):
            ok = False
            ev.append("  FAIL: s.die received by %s but not every one exploded the puppet" % [i.name() for i in others])
    pods = {i.name(): i.count(r"Exploded \[.*\] with lifepod") for i in insts}
    ev.append("lifepods: %s" % pods)
    if any(n and i not in dead for i, n in ((i, pods[i.name()]) for i in insts)):
        ok = False
        ev.append("FAIL: a lifepod on a machine whose ship didn't die")
    blasts = {i.name(): ("physical" if i.count(r"blast of .* particles physical") else "ghosted") for i in insts
              if i.count(r"COOP: SHIPS blast of")}
    ev.append("blast particles: %s" % blasts)
    if list(blasts.values()).count("physical") != 1:
        ok = False
        ev.append("FAIL: the blast must be physical on exactly one machine")
    return ok, ev


def gate9(insts):
    """NPC mirror: an authority NPC appears on members as a mirror, a member's hits reach it with hostility, and the
    sub-check: a member joining with a story NPC keeps it (freed the rest) and the others mirror it."""
    ev = []
    ok = True
    mirrors = {i.name(): i.count(r"COOP: NPC mirror \S+: ") for i in insts}
    ev.append("mirrors built: %s" % mirrors)
    if sum(mirrors.values()) == 0:
        ok = False
        ev.append("FAIL: no NPC mirror anywhere")
    best = 0.0
    for i in insts:
        hs = [float(m.group(2)) for m in i.grep(r"COOP: NPC d\.ship from \d+: .* on (\S+); its hostility to player = (-?[\d.]+)")]
        if hs:
            ev.append("%s applied forwarded hits, hostility to player %.3f -> %.3f" % (i.name(), hs[0], hs[-1]))
            best = max(best, hs[-1])
    if best < 0.5:
        ok = False
        ev.append("FAIL: no NPC turned hostile through d.ship (max hostility %.3f)" % best)
    joins = [(i, m) for i in insts for m in i.grep(r"COOP: NPC joined (\d+)'s cell: freed (\d+) NPCs of mine \[(.*)\], kept (\d+) as mine \[(.*)\]")]
    sub = [(i, m) for i, m in joins if int(m.group(4)) > 0]
    if sub:
        for i, m in sub:
            kept_ok = [o.name() for o in insts if o is not i and o.count(r"COOP: NPC mirror %s:n\d+: " % i.peer)]
            ev.append("sub-check: %s freed %s [%s], kept %s [%s]; mirrored by %s" % (
                i.name(), m.group(2), m.group(3), m.group(4), m.group(5), kept_ok))
            if not kept_ok:
                ok = False
                ev.append("FAIL: the kept NPC was not mirrored by anyone")
    else:
        ev.append("sub-check not staged (no member joined with a kept NPC; use --coop-dev-story-npc)")
    for i in insts:
        watch = [m.group(1) for m in i.grep(r"COOP: NPC save watch: (.*)")]
        joined = i.grep(r"COOP: (?:NPC joined|CELL JOINED|CELL FORMED)")
        if watch and joined:
            ev.append("%s save tables (last): %s" % (i.name(), watch[-1]))
    return ok, ev


def gate9b(insts):
    """NPC death: an NPC the authority runs dies there (one lifepod, on the runner) and its mirrors play the explosion
    as a picture (no lifepod, no vanish write on members)."""
    ev = []
    killed = [(i, m) for i in insts for m in i.grep(r"COOP: NPC dev: blowing up NPC (\S+) (\S+)")]
    if not killed:
        return False, ["FAIL: no NPC was blown up (use --coop-dev-pirate with --coop-dev-kill-npc)"]
    ok = True
    for i, m in killed:
        nid = m.group(1)
        pods = {o.name(): o.count(r"Exploded \[.*\] with lifepod") - (1 if o.count(r"COOP: NPC s\.die sent") else 0) for o in insts}
        boom = [o.name() for o in insts if o is not i and o.count(r"COOP: NPC mirror %s exploding" % re.escape(nid))]
        ev.append("%s blew up %s; mirrors exploding on %s; NPC lifepods per machine %s" % (i.name(), nid, boom, pods))
        if not boom:
            ok = False
            ev.append("FAIL: no member played the NPC's explosion")
        if pods.get(i.name(), 0) != 1 or any(n for k, n in pods.items() if k != i.name()):
            ok = False
            ev.append("FAIL: the NPC's lifepod must exist exactly once, on its runner")
    return ok, ev


def gate9c(insts):
    """Pre-join oddities: a member's own oddity (a moonlet from a POI) is freed when it joins a cell, and comes back
    from its POI once the member is solo near it again (check savecheck.sh too: no save file changes)."""
    ev = []
    staged = False
    ok = True
    for i in insts:
        lines = i.lines
        poi = [n for n, l in enumerate(lines) if "COOP: NPC dev: test POI" in l]
        if not poi:
            continue
        staged = True
        ev_name = re.search(r"\(event (\S+)\)", lines[poi[0]]).group(1)
        spawns = [n for n, l in enumerate(lines) if re.search(r"(Location-based oddity|Re-spawning) %s" % re.escape(ev_name), l)]
        freed = [(n, re.search(r"freed (\d+) oddities of mine (\[.*?\]), kept (\d+) (\[.*\])", l)) for n, l in enumerate(lines)
                 if "joined: freed" in l and "oddities" in l]
        back = [n for n, l in enumerate(lines) if "COOP: NPC dev: returned to" in l]
        first = [n for n in spawns if n > poi[0]]
        ev.append("%s: POI for %s; oddity spawned %d time(s)" % (i.name(), ev_name, len(spawns)))
        if not first or not freed:
            ok = False
            ev.append("FAIL: the oddity never spawned before joining, or the member never joined")
            continue
        fn, fm = freed[0]
        ev.append("  joined: freed %s %s, kept %s %s" % (fm.group(1), fm.group(2), fm.group(3), fm.group(4)))
        if fn < first[0] or int(fm.group(1)) < 1:
            ok = False
            ev.append("FAIL: nothing freed after the oddity spawned")
        if not back:
            ok = False
            ev.append("FAIL: the member never returned to the POI (--coop-dev-return)")
            continue
        again = [n for n in spawns if n > back[0]]
        ev.append("  returned to the POI; oddity back from its POI: %s" % bool(again))
        if not again:
            ok = False
            ev.append("FAIL: the oddity did not come back after leaving the cell")
    if not staged:
        return False, ["FAIL: not staged (use --coop-dev-poi=<event> and --coop-dev-return=<s> on the joining member)"]
    return ok, ev


GATES = {
    7: gate7,
    8: gate8,
    9: gate9,
    "9b": gate9b,
    "9c": gate9c,
}


def main(argv):
    want = list(GATES)
    if argv and argv[0] == "--gates":
        want = [int(g) if g.isdigit() else g for g in argv[1].split(",")]
        argv = argv[2:]
    files = sorted({f for g in argv for f in glob.glob(os.path.expanduser(g))})
    if not files:
        print(__doc__)
        return 1
    insts = [Instance(f) for f in files]
    print("instances: %s" % ", ".join(i.name() for i in insts))
    errors = [(i.name(), i.count(r"SCRIPT ERROR")) for i in insts if i.count(r"SCRIPT ERROR")]
    failed = False
    for g in want:
        if g not in GATES:
            print("gate %s: not implemented here" % g)
            continue
        ok, ev = GATES[g](insts)
        failed = failed or not ok
        print("gate %s: %s  %s" % (g, "PASS" if ok else "FAIL", GATES[g].__doc__.strip().split(":")[0]))
        for e in ev:
            print("    " + e)
    if errors:
        print("SCRIPT ERROR lines in dv logs: %s (check engine_log.txt too)" % errors)
        failed = True
    print("RESULT: %s" % ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
