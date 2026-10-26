"""M4 real-arm gates (2, 3, 4, 10 with a salvage arm and a real MPU), one command once the dev save exists.

Usage: DV_WHO=<you> python tools/gate_arm.py [2] [34] [10]      (default: all three phases, in that order)

Needs the dev slot savegame-arm.dv (a ship with a salvage arm for 2 and 34, an MPU for 10) in the main dev data dir
(~/dvcoop-data/dV; dv_seed copies it to the other instances). It is a copy of Tim's slot d (TRTL: SALVAGE_ARM, MPU,
DND_HAUL). Only B and C ever load it: they run on seeded temp copies, while A runs on ~/dvcoop-data itself, so a stock
save there (a tug rescue ends the dive and saves) would change the dev data. Each phase is one tools/dev3.sh run
(relay + 3 players, 4 windows), kept under 10 minutes, then tools/stop.sh (which keeps the logs), tools/savecheck.sh
before/after, and tools/gate_m4.py on the kept logs:
  2   gate 2r   every instance runs --coop-bot=frac,N (whichever forms the cell coordinates); B and C load the arm
                save and reach with their arms when they are members.
  34  gates 3,4 B and C load the arm save and run --coop-bot=claw,1,hold; each member among them locks a rock its arm
                takes (the salvage arm's stock mineral filter) and holds it. Gate 4 hard-kills the cell authority when a
                surviving holder is not the peer promoted in its place (the next-lowest id), which then must adopt that
                rock from o.list while the holder keeps holding; then gate 3 hard-kills that holder (the new authority
                re-owns within 2 s). If the authority is A, both B and C hold and gate 4 always stages; if it is B or C,
                it stages when A's id is below the other arm member's. Otherwise gate 3 only, and it relaunches (3 tries).
  10  gate 10r  C loads the arm save and runs --coop-bot=mpu,N: the stock MPU claims, processes and frees rocks.
Announce every launch to the lead first (game window rules); this script prints the line to send.
"""
import os, re, subprocess, sys, time, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WHO = os.environ.get("DV_WHO", "")
WIN = os.name == "nt"
DATA = os.path.expanduser(os.environ.get("DV_DATA", "~/dvcoop-data"))
INST = os.path.expanduser(os.environ.get("DV_INST", "~/AppData/Local/Temp" if WIN else "/tmp"))
SLOT = "savegame-arm.dv"
DIVE_X, DIVE_Y, OFF_B, OFF_C = 150000, 0, 1200, 60000
BASE = {"DIVE_X": str(DIVE_X), "DIVE_Y": str(DIVE_Y), "OFF_B": str(OFF_B), "WARP_C": "60", "WARP_C_DIST": "900"}
LOGDIR = {"A": os.path.join(DATA, "dV", "logs"), "B": os.path.join(INST, "dvcoop_instB", "dV", "logs"),
          "C": os.path.join(INST, "dvcoop_instC", "dV", "logs")}
# where the arm phases (2r, 3-4) dive; 10r stays at BASE. Any spot works: mineral rocks are never spawned by the ring,
# only made by breaking class-4 rocks (the bots do that), so this is only a knob for a denser or emptier field.
ARM_DIVE = {"DIVE_X": os.environ.get("ARM_DIVE_X", str(DIVE_X)), "DIVE_Y": os.environ.get("ARM_DIVE_Y", str(DIVE_Y))}
FRAC_N = int(os.environ.get("FRAC_N", "30"))   # 12 s an arm trial: 30 fit in the 9-minute limit with the ~2.5 min warm-up
MPU_N = int(os.environ.get("MPU_N", "5"))
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


def authority():
    # the latest cell status line any player logged names the authority
    best = None
    for inst in "ABC":
        for m in grep(inst, r"\[(\d+/\d+/\d+ \d+:\d+:\d+)\]: COOP: CELL status role=\w+ auth=(\d+)"):
            if best is None or m.group(1) >= best[0]:
                best = (m.group(1), int(m.group(2)))
    return best[1] if best else None


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


def launch(label, extra):
    log("send the lead: launching 4 windows ~10 min for gate %s" % label)
    sh(["tools/dev3.sh"], dict(BASE, **{"EXTRA_" + k: v for k, v in extra.items()}))
    sh(["tools/savecheck.sh", "before", "arm-" + label])


def stop(label, gates):
    out = sh(["tools/stop.sh"], check=False)
    log("send the lead: windows closed for gate %s" % label)
    sh(["tools/savecheck.sh", "after", "arm-" + label], check=False)
    if not gates:
        return False
    m = re.search(r"logs kept in (\S+)", out)
    if not m:
        log("no kept logs from stop.sh; can't score")
        return False
    run = m.group(1)
    r = subprocess.run([sys.executable, "tools/gate_m4.py", "--gates", gates] + glob.glob(os.path.join(run, "*", "dV", "logs", "dv_log_*.txt")), cwd=ROOT)
    return r.returncode == 0


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


def holding(inst):
    # a rock locked in this instance's arm and owned by it (haul drones and the hold also claim; they don't count)
    return bool(grep(inst, r"COOP: BOT claw holding id=\S+ .*locked=True mine=True"))


@at_arm_dive
def phase34(attempt):
    # B and C both load the arm save and hold a rock (whichever of them is a member). Gate 4 needs a holder that
    # survives the authority's kill and is not the peer promoted in its place (the next-lowest id), so wait for both
    # holders, then pick the kill order from the ids; only when no holder qualifies does it fall back to gate 3 alone.
    hold = "--coop-slot=%s --coop-bot=claw,1,hold" % SLOT
    launch("3-4", {"B": hold, "C": hold})
    if not loadout_ok("3-4", "BC"):
        return "fail"
    if not wait_for(lambda: holding("B") or holding("C"), LIMIT - 120):
        log("no arm ever locked a rock (no target the arm's mineral filter passes nearby?)")
        stop("3-4", "3,4")
        return "retry"
    ids = {i: peer(i) for i in "ABC"}
    auth = authority()
    x = [i for i in "ABC" if ids[i] == auth]
    if not x:
        stop("3-4", "3,4")
        return "retry"
    x = x[0]
    survivors = [i for i in "ABC" if i != x]
    promoted = min(survivors, key=lambda i: ids[i])
    want = [i for i in survivors if i != promoted and i in "BC"]
    if want:
        wait_for(lambda: holding(want[0]), 60)   # the other arm may still be reaching
    holders = [i for i in survivors if holding(i)]
    h4 = [i for i in holders if i != promoted]
    log("ids %s, authority %s, promoted next %s, holders %s" % (ids, x, promoted, holders))
    four = bool(h4)
    if four:
        kill(x)       # gate 4: `promoted` takes over and adopts h4's rock from o.list; h4 keeps holding
        wait_for(lambda: grep(promoted, r"COOP: OWN o\.list adopts"), 20, 1)
        time.sleep(8)
        kill(h4[0])   # gate 3: the new authority re-owns the rock of the killed holder
    elif holders:
        kill(holders[0])   # gate 3 only: the holder is the one who would be promoted
    else:
        stop("3-4", "3,4")
        return "retry"
    time.sleep(6)
    ok = stop("3-4", "3,4" if four else "3")
    return "ok" if ok and four else ("gate3-only" if ok else "fail")


def phase10():
    launch("10r", {"C": "--coop-slot=%s --coop-bot=mpu,%d" % (SLOT, MPU_N)})
    if not loadout_ok("10r", "C", arm=False, mpu=True):
        return False
    wait_for(lambda: grep("C", r"COOP: BOT mpu done|COOP: BOT mpu: no MPU"), LIMIT, 10)
    time.sleep(35)   # a conservation line (every 30 s) after the last eat
    return stop("10r", "10r")


def main(argv):
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
            for attempt in range(3):
                r = phase34(attempt)
                res["3,4"] = r
                if r in ("ok", "fail"):
                    break
                log("relaunching for gate 4 (%s)" % r)
        elif p == "10":
            res["10r"] = phase10()
    log("summary: %s" % res)
    return 0 if all(v in (True, "ok") for v in res.values()) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
