"""M4 real-arm gates (2, 3, 4, 10 with a salvage arm and a real MPU), one command once the dev save exists.

Usage: DV_WHO=<you> python tools/gate_arm.py [2] [34] [10]      (default: all three phases, in that order)

Needs the dev slot savegame-arm.dv (a ship with a salvage arm for 2 and 34, an MPU for 10) in the main dev data dir
(~/dvcoop-data/dV; dv_seed copies it to the other instances). It is a copy of Tim's slot d (TRTL: SALVAGE_ARM, MPU,
DND_HAUL). A never loads it: B and C run on seeded temp copies, while A runs on ~/dvcoop-data itself, so a stock save
there (a tug rescue or an escape to Enceladus ends the dive and saves) would change the dev data. Where A needs the arm
(phase 34) it loads SLOT_A, a throwaway copy made fresh before each launch. Each phase is one tools/dev3.sh run
(relay + 3 players, 4 windows), kept under 10 minutes, then tools/stop.sh (which keeps the logs), tools/savecheck.sh
before/after, and tools/gate_m4.py on the kept logs:
  2   gate 2r   every instance runs --coop-bot=frac,N (whichever forms the cell coordinates); B and C load the arm
                save and reach with their arms when they are members.
  34  gates 3,4 A (on SLOT_A), B and C run --coop-bot=claw,1,hold; each member among them locks a rock its arm
                takes (the salvage arm's stock mineral filter) and holds it. Gate 4 hard-kills the cell authority when a
                surviving holder is not the peer promoted in its place (the next-lowest id), which then must adopt that
                rock from o.list while the holder keeps holding; then gate 3 hard-kills that holder (the new authority
                re-owns within 2 s). With all three holding, both survivors hold and one of them is not promoted, so gate
                4 stages whatever the ids (with only B and C, runs 060224/060756/061503 drew B as authority and C as next
                three times). Otherwise gate 3 only, and it relaunches (3 tries).
  10  gate 10r  C loads the arm save and runs --coop-bot=mpu,N: the stock MPU claims, processes and frees rocks.
Announce every launch to the lead first (game window rules); this script prints the line to send.

Every launch (here and in m4_final.py) first checks the master dev saves (~/dvcoop-data/dV/savegame*.dv, which dev3
seeds B and C from) against MASTER, a sha1 manifest beside dV/, and refuses to launch, naming the file, if one differs
or is new or missing: a stock save on A must never spread to the other instances (run 063348). Record the manifest
once the masters are known good:  python tools/gate_arm.py --record-master
"""
import hashlib, json, os, re, shutil, subprocess, sys, time, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WHO = os.environ.get("DV_WHO", "")
WIN = os.name == "nt"
DATA = os.path.expanduser(os.environ.get("DV_DATA", "~/dvcoop-data"))
INST = os.path.expanduser(os.environ.get("DV_INST", "~/AppData/Local/Temp" if WIN else "/tmp"))
SLOT = "savegame-arm.dv"
MASTER = os.path.join(DATA, "master-saves.json")   # name -> sha1 of every known-good master save (beside dV/, not seeded)
SLOT_A = "savegame-arm-a.dv"   # A's throwaway copy of SLOT (phase 34): a stock save on A lands here, never in SLOT
DIVE_X, DIVE_Y, OFF_B, OFF_C = 150000, 0, 1200, 60000
BASE = {"DIVE_X": str(DIVE_X), "DIVE_Y": str(DIVE_Y), "OFF_B": str(OFF_B), "WARP_C": "60", "WARP_C_DIST": "900"}
LOGDIR = {"A": os.path.join(DATA, "dV", "logs"), "B": os.path.join(INST, "dvcoop_instB", "dV", "logs"),
          "C": os.path.join(INST, "dvcoop_instC", "dV", "logs")}
# where the arm phases (2r, 3-4) dive; 10r stays at BASE. Any spot works: mineral rocks are never spawned by the ring,
# only made by breaking class-4 rocks (the bots do that), so this is only a knob for a denser or emptier field.
ARM_DIVE = {"DIVE_X": os.environ.get("ARM_DIVE_X", str(DIVE_X)), "DIVE_Y": os.environ.get("ARM_DIVE_Y", str(DIVE_Y))}
FRAC_N = int(os.environ.get("FRAC_N", "30"))   # 12 s an arm trial: 30 fit in the 9-minute limit with the ~2.5 min warm-up
MPU_N = int(os.environ.get("MPU_N", "2"))   # one mineral (up to ~4 min with seeding) + one ice rock
LIMIT = 9 * 60


def log(msg):
    print("[gate_arm %s] %s" % (time.strftime("%H:%M:%S"), msg), flush=True)


def lines(inst):
    out = []
    for f in sorted(glob.glob(os.path.join(LOGDIR[inst], "dv_log_*.txt"))):
        out += open(f, encoding="utf-8", errors="replace").read().splitlines()
    return out


def grep(inst, pattern):
    rx = re.compile(pattern)
    return [m for m in (rx.search(l) for l in lines(inst)) if m]


def peer(inst):
    m = grep(inst, r"COOP: ENet connected to server, I am (\d+)")
    return int(m[0].group(1)) if m else None


def status(inst):
    """(role, auth, members) from the instance's latest CELL status line, or None."""
    m = grep(inst, r"COOP: CELL status role=(\w+) auth=(\d+) .*? members=\[([\d, ]*)\]")
    if not m:
        return None
    last = m[-1]
    return last.group(1), int(last.group(2)), sorted(int(x) for x in last.group(3).replace(" ", "").split(",") if x)


def authority():
    # the authority as players in a cell see it (a SOLO line names the player itself: never use one)
    for inst in "ABC":
        s = status(inst)
        if s and s[0] in ("MEMBER", "AUTHORITY"):
            return s[1]
    return None


def one_cell():
    """True once A, B and C all report the same cell (C joins only after its warp, 60 s into its dive)."""
    ss = [status(i) for i in "ABC"]
    return all(s and s[0] in ("MEMBER", "AUTHORITY") and len(s[2]) == 3 for s in ss) and len({s[1] for s in ss}) == 1


# Git Bash, not WSL's bash.exe, which a bare "bash" can resolve to when this runs outside Git Bash
BASH = next((b for b in ["C:/Program Files/Git/bin/bash.exe"] if WIN and os.path.exists(b)), "bash")


def sh(args, env=None, check=True):
    e = dict(os.environ, DV_WHO=WHO, **(env or {}))
    r = subprocess.run([BASH] + args, cwd=ROOT, env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sys.stdout.write(r.stdout)
    if check and r.returncode != 0:
        raise SystemExit("%s failed (%d)" % (args[0], r.returncode))
    return r.stdout


def at_arm_dive(fn):
    """Run a phase with BASE moved to ARM_DIVE, then put it back."""
    def run(*a):
        saved = dict(BASE)
        BASE.update(ARM_DIVE)
        try:
            return fn(*a)
        finally:
            BASE.clear()
            BASE.update(saved)
    return run


def _masters():
    """name -> sha1 of each master save, A's throwaway copy left out (it is remade from SLOT before every use)."""
    out = {}
    for f in sorted(glob.glob(os.path.join(DATA, "dV", "savegame*.dv"))):
        if os.path.basename(f) != SLOT_A:
            out[os.path.basename(f)] = hashlib.sha1(open(f, "rb").read()).hexdigest()
    return out


def record_master():
    json.dump(_masters(), open(MASTER, "w"), indent=1, sort_keys=True)
    print("recorded %d master saves -> %s" % (len(_masters()), MASTER))


def check_master():
    """Refuse to launch on a master save that differs from the manifest (or with no manifest at all)."""
    if not os.path.exists(MASTER):
        raise SystemExit("no master save manifest %s: check the masters, then python tools/gate_arm.py --record-master"
                         % MASTER)
    want, now = json.load(open(MASTER)), _masters()
    bad = ["%s %s" % (n, "missing" if n not in now else "new" if n not in want else "changed (%s, manifest %s)"
                      % (now[n][:8], want[n][:8])) for n in sorted(set(want) | set(now)) if want.get(n) != now.get(n)]
    if bad:
        raise SystemExit("refusing to launch: master dev save(s) in %s differ from %s: %s. Restore each to its manifest "
                         "hash (not blindly from <slot>.dvb: the game renames the previous save there on every save, so "
                         "after two saves it is a bad one too, run 063348) or re-record if the change is intended."
                         % (os.path.join(DATA, "dV"), MASTER, "; ".join(bad)))


def launch(label, extra):
    check_master()   # before announcing: a refused launch opens no windows
    log("send the lead: launching 4 windows ~10 min for gate %s" % label)
    sh(["tools/dev3.sh"], dict(BASE, **{"EXTRA_" + k: v for k, v in extra.items()}))
    sh(["tools/savecheck.sh", "before", "arm-" + label])


KILLS = []    # [(peer id, wall ms just before the kill)] in this run; stop() writes them next to the kept logs
SCORES = {}   # gate -> passed, from the last stop()


HEALTH = []   # every run's ship/save failures (ship_health); any of them fails the whole gate_arm / m4_final run


def ship_health(run, savecheck, label):
    """Run 081334: a bot ship went dry (helpless), the stock rescue tow docked it home and saved its seeded slot. Any
    "COOP: BOT ship ... helpless=True" or "COOP: BOT ship draining" line is a FAIL, and so is a savecheck diff (M4
    phases never save); the changed saves are copied next to the kept logs before the next launch reseeds them.
    Returns the failures (also appended to HEALTH)."""
    bad = []
    for f in sorted(glob.glob(os.path.join(run, "*", "dV", "logs", "dv_log_*.txt")) if run else []):
        inst = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(f))))
        for ln in open(f, encoding="utf-8", errors="replace"):
            if "COOP: BOT ship draining" in ln or re.search(r"COOP: BOT ship remass=.* helpless=True", ln):
                bad.append("%s: %s" % (inst, ln.strip()))
                break
    if "savecheck: PASS" not in savecheck:
        changed = re.findall(r"^\s+(\S+\.dv)\s+\S+ -> \S+", savecheck, re.M)
        bad.append("savecheck: %s" % (", ".join(changed) or "output not understood"))
        if run:
            keep = os.path.join(run, "saves-changed")
            os.makedirs(keep, exist_ok=True)
            for c in changed:
                if WIN and re.match(r"^/([a-zA-Z])/", c):
                    c = c[1].upper() + ":" + c[2:]
                if os.path.exists(c):
                    shutil.copy(c, os.path.join(keep, os.path.basename(os.path.dirname(os.path.dirname(c)))
                                                + "_" + os.path.basename(c)))
    for b in bad:
        log("FAIL ship/save health (%s): %s" % (label, b))
    HEALTH.extend(bad)
    return bad


def stop(label, gates):
    """Close the run, keep its logs (with kills.txt), and score each gate on its own; True when all of them pass and
    the ships and saves are healthy (ship_health)."""
    out = sh(["tools/stop.sh"], check=False)
    log("send the lead: windows closed for gate %s" % label)
    sc = sh(["tools/savecheck.sh", "after", "arm-" + label], check=False)
    kills = list(KILLS)
    del KILLS[:]
    SCORES.clear()
    m = re.search(r"logs kept in (\S+)", out)
    run = m.group(1) if m else None
    if run and WIN and re.match(r"^/([a-zA-Z])/", run):   # stop.sh prints a Git Bash path; Windows Python can't glob it
        run = run[1].upper() + ":" + run[2:]
    healthy = not ship_health(run, sc, label)
    if not gates:
        return False
    if not run:
        log("no kept logs from stop.sh; can't score")
        return False
    if kills:
        # gate 3 measures kill -> reown from these (the game logs whole seconds; Own's reown line carries wall ms)
        with open(os.path.join(run, "kills.txt"), "w") as f:
            for p, ms in kills:
                f.write("%s %d\n" % (p, ms))
    logs = glob.glob(os.path.join(run, "*", "dV", "logs", "dv_log_*.txt"))
    for g in gates.split(","):
        r = subprocess.run([sys.executable, "tools/gate_m4.py", "--gates", g] + logs, cwd=ROOT)
        SCORES[g] = r.returncode == 0
    return all(SCORES.values()) and healthy


def wait_for(cond, limit, every=5):
    end = time.time() + limit
    while time.time() < end:
        v = cond()
        if v:
            return v
        time.sleep(every)
    return None


def kill(inst):
    # the game process whose command line has this instance's dive offset
    if WIN:
        ps = "Get-CimInstance Win32_Process -Filter \"Name='Delta-V.exe'\" | ForEach-Object { \"$($_.ProcessId) $($_.CommandLine)\" }"
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], stdout=subprocess.PIPE, text=True).stdout
    else:
        out = subprocess.run(["pgrep", "-af", "Delta-V"], stdout=subprocess.PIPE, text=True).stdout
    # dev3: A dives at (DIVE_X, DIVE_Y), B OFF_B below it, C OFF_C (dev3's default 60000) below it
    x, y = int(BASE["DIVE_X"]), int(BASE["DIVE_Y"])
    dy = {"A": 0, "B": int(BASE.get("OFF_B", OFF_B)), "C": OFF_C}[inst]
    tok = "--coop-dive-offset=%d,%d" % (x, y + dy)
    for row in out.splitlines():
        if tok in row.split():
            pid = row.split()[0]
            KILLS.append((peer(inst), int(time.time() * 1000)))
            subprocess.run(["taskkill", "/PID", pid, "/F"] if WIN else ["kill", "-9", pid])
            log("hard-killed %s (pid %s, peer %s)" % (inst, pid, peer(inst)))
            return True
    log("no process found for %s" % inst)
    return False


def loadout_ok(label, insts, arm=True, mpu=False):
    """Fail fast: every instance that loaded the arm save must log a loadout with what the phase needs mounted."""
    got = wait_for(lambda: all(grep(i, r"COOP: BOT loadout ") for i in insts) and
                   {i: grep(i, r"COOP: BOT loadout .*")[-1].group(0) for i in insts}, 120)
    if not got:
        log("no loadout line from %s within 2 min" % insts)
    else:
        for i, line in got.items():
            log("%s %s" % (i, line))
        if all((not arm or "arm=True" in l) and (not mpu or "mpu=True" in l) for l in got.values()):
            return True
        need = " and ".join(n for n, w in (("salvage arm", arm), ("MPU", mpu)) if w)
        log("FAIL: %s does not have the %s mounted; stopping this phase" % (SLOT, need))
    stop(label, "")
    return False


@at_arm_dive
def phase2():
    arm = "--coop-slot=%s --coop-bot=frac,%d" % (SLOT, FRAC_N)
    launch("2r", {"A": "--coop-bot=frac,%d" % FRAC_N, "B": arm, "C": arm})
    if not loadout_ok("2r", "BC"):
        return False
    done = wait_for(lambda: sum(len(grep(i, r"COOP: BOT frac trial=\d+ id=\S+ shards spawned=")) for i in "ABC") >= FRAC_N, LIMIT, 10)
    log("fracture trials %s" % ("complete" if done else "cut at the time limit"))
    time.sleep(8)   # the last trial's member result
    return stop("2r", "2r")


HOLD_FRESH = 3.0   # s: the claw bot logs "holding" every second, at whole-second resolution


# The stock salvage arm lets go of a fresh grab on its own a few seconds after locking ("Switching [..] from invalid
# target"; runs 005702, 014836, 015627, 051003): it re-checks its mineral filter every frame (DockingArm.isValidTarget,
# pickupOnlyMineralTargets), and ship.isValidMineralTarget passes a rock the lidar hasn't identified yet on albedo
# alone, then drops it once identified (hud/MineralMark) unless it holds a wanted mineral worth the min value. So a
# hold is final only once the rock is identified down to its value and still passes: the bot logs identified=value
# takes=True. A hold counts after HOLD_STABLE such lines (one a second).
HOLD_STABLE = 5


def holding(inst, stable=1):
    """The rock id this instance holds right now: its last `stable` claw "holding" lines are all for one rock, locked
    in the arm and owned (haul drones and the hold also claim; they don't count), identified down to its value and
    passing the arm's mineral filter, the latest at most HOLD_FRESH s old. None otherwise."""
    rows = grep(inst, r"\[(\d+/\d+/\d+ \d+:\d+:\d+)\]: COOP: BOT claw holding id=(\S+) .*locked=(\w+) mine=(\w+)"
                      r"(?: identified=(\w+) takes=(\w+))?")
    if len(rows) < stable:
        return None
    last = rows[-stable:]
    t = time.mktime(time.strptime(last[-1].group(1), "%Y/%m/%d %H:%M:%S"))
    if time.time() - t > HOLD_FRESH:
        return None
    if any(r.group(2) != last[-1].group(2) or r.group(3) != "True" or r.group(4) != "True"
           or r.group(5) != "value" or r.group(6) != "True" for r in last):
        return None
    return last[-1].group(2)


@at_arm_dive
def phase34(attempt):
    # A, B and C all load the arm save and hold a rock (whichever of them are members). Gate 4 needs a holder that
    # survives the authority's kill and is not the peer promoted in its place (the next-lowest id): with all three
    # holding, the two survivors both hold and one of them is not promoted, whatever the ids (with only B and C holding,
    # runs 060224/060756/061503 drew B as authority and C as next three times: gate 4 could not be staged).
    # Returns {"3": passed, "4": passed}, with None for a gate this launch could not stage.
    hold = "--coop-slot=%s --coop-bot=claw,1,hold"
    # run 063348: A on SLOT itself saved over the dev master after a stock escape to Enceladus; A gets a fresh copy
    shutil.copyfile(os.path.join(DATA, "dV", SLOT), os.path.join(DATA, "dV", SLOT_A))
    launch("3-4", {"A": hold % SLOT_A, "B": hold % SLOT, "C": hold % SLOT})
    if not loadout_ok("3-4", "ABC"):
        return {"3": False, "4": False}
    if not wait_for(lambda: holding("A") or holding("B") or holding("C"), LIMIT - 120):   # A holds too (run 090808)
        log("no arm ever locked a rock (no target the arm's mineral filter passes nearby?)")
        stop("3-4", "")
        return {"3": None, "4": None}
    # the promotion order only means something once all three are in one cell (C warps in 60 s into its dive)
    if not wait_for(one_cell, 120, 2):
        log("A, B and C never shared one cell: %s" % {i: status(i) for i in "ABC"})
        stop("3-4", "")
        return {"3": None, "4": None}
    ids = {i: peer(i) for i in "ABC"}
    auth = authority()
    x = [i for i in "ABC" if ids[i] == auth]
    if not x:
        stop("3-4", "")
        return {"3": None, "4": None}
    x = x[0]
    survivors = [i for i in "ABC" if i != x]
    promoted = min(survivors, key=lambda i: ids[i])
    # gate 4 needs, at the instant of the kill, a member that holds a rock right now and is not the promotion target
    # (a hold can lapse: the arm lets go and the bot reaches again), so poll for that and kill the moment it holds
    h4 = wait_for(lambda: [i for i in survivors if i != promoted and holding(i, HOLD_STABLE)], 120, 0.5) or []
    holders = [i for i in survivors if holding(i)]
    log("ids %s, authority %s, promoted next %s, holding now %s%s" % (ids, x, promoted, holders,
        "" if not h4 else ", gate 4 holder %s with %s" % (h4[0], holding(h4[0]))))
    four = bool(h4)
    if four:
        kill(x)       # gate 4: `promoted` takes over and adopts h4's rock from o.list; h4 keeps holding
        wait_for(lambda: grep(promoted, r"COOP: OWN o\.list adopts"), 20, 1)
        time.sleep(8)
        kill(h4[0])   # gate 3: the new authority re-owns the rock of the killed holder
    elif holders or wait_for(lambda: [i for i in survivors if holding(i)], 30, 0.5):
        holders = [i for i in survivors if holding(i)] or holders
        if not holders:
            stop("3-4", "")
            return {"3": None, "4": None}
        kill(holders[0])   # gate 3 only: the holder is the one who would be promoted
    else:
        stop("3-4", "")
        return {"3": None, "4": None}
    time.sleep(6)
    stop("3-4", "3,4" if four else "3")   # each gate scored on its own
    return {"3": SCORES.get("3"), "4": SCORES.get("4") if four else None}


def phase10():
    launch("10r", {"C": "--coop-slot=%s --coop-bot=mpu,%d" % (SLOT, MPU_N)})
    if not loadout_ok("10r", "C", arm=False, mpu=True):
        return False
    # under 10 min in all: ~0.5 min launch, at most 7 min of trials, 35 s for a conservation line, stop
    wait_for(lambda: grep("C", r"COOP: BOT mpu done|COOP: BOT mpu: no MPU"), 7 * 60, 10)
    time.sleep(35)   # a conservation line (every 30 s) after the last eat
    return stop("10r", "10r,memberfrac")   # the MPU breaking ice is a member fracture: its shards must spawn


def main(argv):
    if argv[:1] == ["--record-master"]:
        record_master()
        return 0
    if not WHO:
        raise SystemExit("set DV_WHO (the game lock holder name)")
    if not os.path.exists(os.path.join(DATA, "dV", SLOT)):
        raise SystemExit("no %s in %s: make the salvage-arm + MPU dev save first" % (SLOT, os.path.join(DATA, "dV")))
    phases = argv or ["2", "34", "10"]
    res = {}
    for p in phases:
        if p == "2":
            res["2r"] = phase2()
        elif p == "34":
            # gates 3 and 4 are reported separately; relaunch (3 tries) while one of them is still unstaged, and
            # keep a pass once seen (a later launch only adds the gate it couldn't stage before)
            got = {"3": None, "4": None}
            for attempt in range(3):
                r = phase34(attempt)
                for g in got:
                    if r[g] is not None and got[g] is not True:
                        got[g] = r[g]
                if None not in got.values():
                    break
                log("relaunching for gate(s) %s, not staged yet" % [g for g in got if got[g] is None])
            res["3"] = bool(got["3"])
            res["4"] = bool(got["4"])
        elif p == "10":
            res["10r"] = phase10()
    res["ship/save health"] = not HEALTH
    log("summary: %s" % res)
    return 0 if all(v in (True, "ok") for v in res.values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
