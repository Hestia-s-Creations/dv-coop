"""The whole M5 gate, one command: four tools/dev5.sh runs (the staging of docs/M5.md, Results), each scored by
gate_m5.py on the logs stop.sh keeps, with savecheck before/after. Prints one PASS/FAIL table at the end.

Usage: DV_WHO=<you> python tools/m5_final.py [phase ...]      (default: run3 M1 M2 g3)

  run3  B: title join, dive to A, 20 s drop. C: leave, invite no then yes, course to A.          gates 1-7
  M1    resolution matrix 1 (A 1280x720 UI 1.0, B 1920x1080 UI 0.9, C 3440x1440 UI 0), C paused alone
        and B dives to C (gate 8)                                                                    gates 1,2,4,7,8
  M2    resolution matrix 2 (A 1024x768 UI 0.9, B 2560x1440 UI 1.0, C 1280x720 UI 0)              gates 1,2,4,7
  g3    B launched with +connect_lobby (title, yes), Leave and an invite at Enceladus (yes); A Leave
        and Host in a dive (3 windows)                                                               gates 1,2,3,7

savecheck "after" differs on B's slot whenever B dives (the stock pre-dive save); that is expected, and any other
changed save fails the phase. On Windows, tools/capwin.ps1 keeps PrintWindow captures in the run's shots/ folder as
evidence (the machine check of the layout is gate 2). Announce every launch to the lead first (game window rules);
this script prints the lines to send.
"""
import os, re, sys, time, glob, shutil, subprocess
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_arm as ga

UI_B = "8:coop,3:capture,6:slot=savegame-b.dv,2:join"
LEAVE_INVITE_A = ("--coop-dev-ui-scene=dive --coop-dev-ui=8:coop,3:capture,3:leave,3:close,8:capture "
                  "--coop-dev-invite=dive:20,127.0.0.1:7777")

# name: (gates, dev5 env, extra flags per instance, end condition [(instance, pattern, count)], time limit s, windows)
PHASES = {
    "run3": ("1,2,3,4,5,6", {"WITH_C": "1"},
             {"A": "",
              "B": "--coop-dev-ui=8:coop,2:capture,2:slot=savegame-b.dv,2:join --coop-dev-dive-friend=8,A "
                   "--coop-dev-drop=60,20",
              "C": "--coop-dev-ui-scene=dive --coop-dev-ui=5:coop,2:capture,2:leave,2:resume "
                   "--coop-dev-invite=dive:25,127.0.0.1:7777 --coop-dev-invite=dive:40,127.0.0.1:7777 "
                   "--coop-dev-answer=no,yes --coop-dev-plot-friend=70"},
             [("B", r"COOP: SESSION reconnected to lobby", 1), ("C", r"COOP: TRAVEL course to friend .*: arrived", 1)],
             330, 4),
    "M1": ("1,2,4,8", {"WITH_C": "1", "RES_A": "1280x720", "UI_A": "1.0", "RES_B": "1920x1080", "UI_B": "0.9",
                       "RES_C": "3440x1440", "UI_C": "0"},
           {"A": LEAVE_INVITE_A,
            "B": "--coop-dev-ui=%s --coop-dev-dive-friend=8,C" % UI_B,
            "C": "--coop-dev-solo-pause=5,100 --coop-dev-ui-scene=dive --coop-dev-ui=12:coop,3:capture"},
           [("C", r"COOP: TRAVEL dev: closing the pause menu", 1)], 270, 4),
    "M2": ("1,2,4", {"WITH_C": "1", "RES_A": "1024x768", "UI_A": "0.9", "RES_B": "2560x1440", "UI_B": "1.0",
                     "RES_C": "1280x720", "UI_C": "0"},
           {"A": LEAVE_INVITE_A,
            "B": "--coop-dev-ui=%s --coop-dev-dive-friend=8,C" % UI_B,
            "C": "--coop-dev-ui-scene=dive --coop-dev-ui=12:coop,3:capture,3:close,2:resume"},
           [("B", r"COOP: TRAVEL dive to friend .*: arrived", 1)], 270, 4),
    "g3": ("1,2,3", {},
           {"A": "--coop-dev-ui-scene=dive --coop-dev-ui=8:coop,2:leave,3:host,3:resume",
            "B": "+connect_lobby 127.0.0.1:7777 --coop-dev-answer=yes,yes --coop-dev-ui-scene=station "
                 "--coop-dev-ui=6:coop,2:leave,2:close --coop-dev-invite=station:14,127.0.0.1:7777"},
           [("B", r"COOP: SESSION join request for lobby .* answered yes", 2)], 200, 3),
}

ENV_KEYS = ["WITH_C", "RES_A", "UI_A", "RES_B", "UI_B", "RES_C", "UI_C", "EXTRA_A", "EXTRA_B", "EXTRA_C"]


def logdir(inst, env):
    # dev5: A uses the main dev data unless it has its own window size (then its own copy, like B and C)
    if inst == "A" and not env.get("RES_A"):
        return os.path.join(ga.DATA, "dV", "logs")
    return os.path.join(ga.INST, "dvcoop_inst" + inst, "dV", "logs")


def count(inst, env, pattern):
    rx = re.compile(pattern)
    n = 0
    for f in glob.glob(os.path.join(logdir(inst, env), "dv_log_*.txt")):
        n += sum(1 for l in open(f, encoding="utf-8", errors="replace") if rx.search(l))
    return n


def run_phase(name):
    gates, env, extra, until, limit, windows = PHASES[name]
    env = dict(env, **{"EXTRA_" + k: v for k, v in extra.items()})
    env.update({k: "" for k in ENV_KEYS if k not in env})   # nothing leaks in from the caller's shell
    ga.log("send the lead: launching %d windows ~%d min for M5 phase %s" % (windows, limit // 60 + 1, name))
    ga.sh(["tools/dev5.sh"], env)
    ga.sh(["tools/savecheck.sh", "before", "m5-" + name], check=False)
    shots = None
    if ga.WIN and shutil.which("powershell"):
        shots = os.path.join(ga.INST, "dvcoop-m5-shots", "%s-%s" % (name, time.strftime("%Y%m%d-%H%M%S")))
        subprocess.Popen(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                          os.path.join(ga.ROOT, "tools", "capwin.ps1"), "-out", shots,
                          "-count", str(limit // 8), "-every", "8", "-wait", "35"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    hit = ga.wait_for(lambda: all(count(i, env, p) >= n for i, p, n in until), limit, 5)
    ga.log("phase %s %s" % (name, "reached its end marker" if hit else "cut at the time limit"))
    time.sleep(10)
    # engine logs (SCRIPT ERROR) aren't kept by stop.sh: copy them before the next launch clears them
    engines = {i: os.path.join(logdir(i, env), "engine_log.txt") for i in "ABC"}
    out = ga.sh(["tools/stop.sh"], check=False)
    ga.log("send the lead: windows closed for M5 phase %s" % name)
    after = ga.sh(["tools/savecheck.sh", "after", "m5-" + name], check=False)
    m = re.search(r"logs kept in (\S+)", out)
    if not m:
        ga.log("no kept logs from stop.sh; can't score")
        return False
    run = m.group(1)
    if ga.WIN and run.startswith("/") and not os.path.exists(run):
        run = subprocess.run(["cygpath", "-w", run], stdout=subprocess.PIPE, text=True).stdout.strip() or run
    for i, f in engines.items():
        d = os.path.join(run, "A" if i == "A" and not env.get("RES_A") else "dvcoop_inst" + i, "dV", "logs")
        if os.path.exists(f) and os.path.isdir(d):
            shutil.copy(f, d)
    saves_ok = _saves_ok(after, name)
    files = glob.glob(os.path.join(run, "*", "dV", "logs", "*.txt"))
    sys.stdout.flush()   # our lines first, then gate_m5's (it writes straight to the console)
    r = subprocess.run([sys.executable, "tools/gate_m5.py", "--gates", gates] + files, cwd=ga.ROOT)
    if shots:
        ga.log("captures: %s" % shots)
    return r.returncode == 0 and saves_ok


def _saves_ok(text, name):
    """savecheck after: only B's slot may differ (the stock pre-dive save), and only in phases where B dives."""
    if "savecheck: PASS" in text:
        ga.log("save rule PASS: every save byte-identical")
        return True
    changed = re.findall(r"^\s+(\S+\.dv)\s", text, re.M)
    bad = [c for c in changed if not re.search(r"dvcoop_instB[\\/]dV[\\/]savegame-b\.dv$", c) or name == "g3"]
    ok = not bad and bool(changed)
    ga.log("save rule %s: %s" % ("PASS" if ok else "FAIL", "unexpected save changes %s" % bad if bad else
                                 "only B's stock pre-dive save changed" if changed else "savecheck output not understood"))
    return ok


def main(argv):
    if not ga.WHO:
        raise SystemExit("set DV_WHO (the game lock holder name)")
    order = argv or list(PHASES)
    res = {}
    for name in order:
        res[name] = run_phase(name)
    print()
    print("M5 final gate")
    for name, ok in res.items():
        print("  %-6s %-14s %s" % (name, "gates " + PHASES[name][0] + ",7", "PASS" if ok else "FAIL"))
    ok = all(res.values())
    print("RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
