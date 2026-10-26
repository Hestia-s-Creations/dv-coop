"""M5 gate: read the dev5 logs of every instance and print PASS / FAIL per gate (docs/M5.md, Gate).

Usage: python tools/gate_m5.py [--gates 1,3,4] <log glob> [<log glob> ...]
       e.g. python tools/gate_m5.py ~/dvcoop-gate/m5run1/[ABCR].txt

Each log file is one instance. Gates read the COOP: SESSION / UI / TRAVEL / CELL lines. Save files are checked
separately by tools/savecheck.sh. SCRIPT ERROR lines fail the run; pass the engine logs (*.engine.txt) as well to
count those (gate 7). Exit 1 if any selected gate fails.
"""
import sys, re, glob, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_m4 import Instance, _secs   # noqa: E402

NEAR = 50000   # px: "within 5 km"


class Log(Instance):
    def name(self):
        return os.path.basename(self.path)

    def after(self, pattern, t, within=None):
        """lines matching pattern at or after second t (and within seconds of it)"""
        out = []
        for line in self.lines:
            s = _secs(line)
            if s is None or s < t or (within is not None and s - t > within):
                continue
            if re.search(pattern, line):
                out.append(line)
        return out


def gate1(logs):
    """Title flows: the panel opens at the title, a join with a save lands in the lobby and goes on to Enceladus"""
    ev, ok, staged = [], True, False
    for i in logs:
        joins = [l for l in i.lines if re.search(r"COOP: UI (join pressed for|joining with save)", l)]
        if not joins:
            continue
        staged = True
        t = _secs(joins[0])
        opened = i.count(r"COOP: UI co-op panel opened \(title\)")
        inlobby = i.after(r"COOP: SESSION in lobby", t, 30)
        hello = i.after(r"COOP: HELLO from", t, 30)
        station = i.after(r"COOP: SESSION|Loader|Enceladus", t, 60)
        ev.append("%s: panel opened %d, join at %s, in lobby %s, hellos after %d" % (
            i.name(), opened, joins[0][-60:], bool(inlobby), len(hello)))
        if not opened or not inlobby or not hello:
            ok = False
            ev.append("FAIL %s: the title join must open the panel, reach the lobby and hear the others" % i.name())
        for l in i.lines:
            if re.search(r"COOP: TRAVEL dev: press (yes|join0) \(disabled\)", l):
                ev.append("%s: Join was disabled when pressed (no save picked): %s" % (i.name(), l[-50:]))
    if not staged:
        return False, ["FAIL: not staged (use --coop-dev-ui=...:coop,...:slot=<file>,...:join on B)"]
    return ok, ev


def gate2(logs):
    """Panel layout: every panel state shown is inside the viewport, clear of the stock menu, with no clipped text"""
    ev, ok = [], True
    lays = [(i, l) for i in logs for l in i.lines if "COOP: UI layout " in l]
    if not lays:
        return False, ["FAIL: no layout reports (open the co-op panel: --coop-dev-ui=...:coop)"]
    seen = {}
    for i, l in lays:
        body = l.split("COOP: UI layout ")[1]
        good = "inside True" in body and "overlaps menu False" in body and "clipped 0 " in body
        ok = ok and good
        m = re.search(r"window \((\d+), (\d+)\), ui ([\d.]+)", body)
        key = (i.name(), body.split(":")[0], m.groups() if m else "?")
        seen.setdefault(key, [0, 0])
        seen[key][0 if good else 1] += 1
        if not good:
            ev.append("FAIL %s: %s" % (i.name(), body[:300]))
    for (n, where, win), (g, b) in sorted(seen.items()):
        ev.append("%s %s window %s: %d layout(s) ok, %d bad" % (n, where, "x".join(win[:2]) + " ui " + win[2] if win != "?" else "?", g, b))
    return ok, ev


def gate3(logs):
    """Invites while running: each join request is shown where the player is and its answer is honoured"""
    ev, ok = [], True
    shown = [(i, l) for i in logs for l in i.lines if re.search(r"COOP: TRAVEL join request from .* shown", l)]
    if not shown:
        return False, ["FAIL: not staged (use --coop-dev-invite=<scene>:<s>,<lobby> and --coop-dev-answer)"]
    for i, l in shown:
        t = _secs(l)
        where = re.search(r"shown \((\w+)\)", l).group(1)
        ans = i.after(r"COOP: SESSION join request for lobby .* answered (yes|no)", t, 30)
        if not ans:
            ok = False
            ev.append("FAIL %s: request shown at %s, never answered" % (i.name(), where))
            continue
        a = re.search(r"answered (yes|no)", ans[0]).group(1)
        ta = _secs(ans[0])
        left_dive = i.after(r"COOP: left dive", ta, 15)
        if a == "no":
            moved = i.after(r"COOP: SESSION (leaving|joining)", ta, 10)
            good = not moved and not left_dive
        else:
            back = i.after(r"COOP: SESSION in lobby", ta, 30)
            good = bool(back) and not (where == "dive" and left_dive)
        ok = ok and good
        ev.append("%s: shown at %s, answered %s: %s" % (i.name(), where, a, "ok" if good else "FAIL"))
    return ok, ev


def _arrivals(logs, what):
    out = []
    for i in logs:
        for l in i.lines:
            m = re.search(r"COOP: TRAVEL %s to friend (.*?): arrived (-?\d+) px" % what, l)
            if m:
                out.append((i, m.group(1), int(m.group(2)), l))
    return out


def gate4(logs):
    """Dive to a friend: the diver arrives within 5 km of the friend and a cell forms"""
    ev, ok = [], True
    arr = _arrivals(logs, "dive")
    if not arr:
        return False, ["FAIL: no dive to a friend (use --coop-dev-dive-friend on B)"]
    for i, who, d, l in arr:
        cell = i.after(r"COOP: CELL (JOINED|FORMED|PROMOTED)", _secs(l), 30)
        good = 0 <= d < NEAR and bool(cell)
        ok = ok and good
        ev.append("%s: arrived %d px from %s, cell: %s" % (i.name(), d, who, cell[0][-70:] if cell else "none"))
    return ok, ev


def gate5(logs):
    """Course to a friend: the traveller arrives within 5 km of the friend"""
    ev, ok = [], True
    arr = _arrivals(logs, "course")
    if not arr:
        plotted = [l for i in logs for l in i.lines if "COOP: TRAVEL plotting a course" in l or "COOP: TRAVEL course to" in l]
        return False, ["FAIL: no course arrived (use --coop-dev-plot-friend on C)"] + [l[-100:] for l in plotted[:6]]
    for i, who, d, l in arr:
        good = 0 <= d < NEAR
        ok = ok and good
        ev.append("%s: arrived %d px from %s" % (i.name(), d, who))
    return ok, ev


def gate6(logs):
    """Reconnect: a dropped link comes back to the same lobby, and the player rejoins a cell, without a restart"""
    ev, ok = [], True
    drops = [(i, l) for i in logs for l in i.lines if re.search(r"COOP: SESSION link to lobby .* lost", l)]
    if not drops:
        return False, ["FAIL: not staged (use --coop-dev-drop=<s>,<d> on B)"]
    for i, l in drops:
        t = _secs(l)
        back = i.after(r"COOP: SESSION reconnected to lobby", t, 90)
        cell = i.after(r"COOP: CELL (JOINED|FORMED|PROMOTED)", _secs(back[0]) if back else t, 60) if back else []
        dives = i.after(r"COOP: left dive", t, 90)
        good = bool(back) and bool(cell) and not dives
        ok = ok and good
        ev.append("%s: lost at %s; back: %s; cell again: %s; left dive: %s" % (
            i.name(), l.split("]")[0][-8:], back[0][-50:] if back else "NO", bool(cell), bool(dives)))
    return ok, ev


def gate8(logs):
    """Paused alone, then a friend arrives: the stock pause turns into the cell-style menu (game running, menu up), the
    cell forms, and the menu still closes"""
    ev, ok = [], True
    staged = [(i, l) for i in logs for l in i.lines if "COOP: TRAVEL dev: pausing as the stock pause does" in l]
    if not staged:
        return False, ["FAIL: not staged (use --coop-dev-solo-pause=<s>,<s2> on C and dive B to C)"]
    for i, l in staged:
        t = _secs(l)
        resumed = i.after(r"COOP: SHIPS pause menu open in a cell, game resumed", t, 300)
        tr = _secs(resumed[0]) if resumed else t
        cell = i.after(r"COOP: CELL (JOINED|FORMED|PROMOTED)", tr, 60) if resumed else []
        closing = i.after(r"COOP: TRAVEL dev: closing the pause menu", t, 400)
        closed = i.after(r"COOP: SHIPS pause menu closed in a cell", _secs(closing[0]), 5) if closing else []
        good = bool(resumed) and bool(cell) and bool(closed)
        ok = ok and good
        ev.append("%s: paused at %s; resumed on arrival: %s; cell: %s; menu closed: %s" % (
            i.name(), l.split("]")[0][-8:], resumed[0].split("]")[0][-8:] if resumed else "NO", bool(cell), bool(closed)))
    return ok, ev


GATES = {1: gate1, 2: gate2, 3: gate3, 4: gate4, 5: gate5, 6: gate6, 8: gate8}


def main(argv):
    want = list(GATES)
    if argv and argv[0] == "--gates":
        want = [int(g) for g in argv[1].split(",")]
        argv = argv[2:]
    files = sorted({f for g in argv for f in glob.glob(os.path.expanduser(g))})
    if not files:
        print(__doc__)
        return 1
    logs = [Log(f) for f in files if not f.endswith(".engine.txt")]
    engines = [Log(f) for f in files if f.endswith(".engine.txt")]
    print("instances: %s" % ", ".join(i.name() for i in logs))
    failed = False
    for g in want:
        ok, ev = GATES[g](logs)
        failed = failed or not ok
        print("gate %s: %s  %s" % (g, "PASS" if ok else "FAIL", GATES[g].__doc__.strip().split(":")[0]))
        for e in ev:
            print("    " + e)
    errors = [(i.name(), i.count(r"SCRIPT ERROR")) for i in logs + engines if i.count(r"SCRIPT ERROR")]
    print("gate 7 (script errors): %s" % ("FAIL %s" % errors if errors else "PASS, none in %d log(s)" % len(logs + engines)))
    failed = failed or bool(errors)
    print("RESULT: %s" % ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
