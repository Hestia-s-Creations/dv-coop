"""M6 gate: everything a machine can check about the release, printed as PASS / FAIL per gate. No game launches.

Usage: python tools/gate_m6.py [--compat <dv log>] [--normal <dv log>]

  1  verify      python tools/verify.py passes
  2  release     the --release --strict build: no malformed dev blocks, no dev path outside a block, dev-only
                 files left out, and nothing dev-only left in the zip's code
  3  repro       the dev zip and the release zip each build twice with the same SHA-256
  4  compat      (--compat) the log of a run with the dev zip and --coop-dev-compat-test: the mod loaded, refused
                 with the faked build, showed the title-screen notice, installed no extension, started no CoopNet
  5  normal      (--normal) the log of a normal run on the pinned build: no refusal, extensions installed, CoopNet
                 attached; if --coop-selftest was on, the selftest passed
  6  errors      zero SCRIPT ERROR lines in the given logs and in the engine_log.txt beside each of them

Gates 4-6 run only when a log is given; without one they're reported as SKIP, and the gate isn't PASS overall
until they've run. Logs: %APPDATA%\\dV\\logs\\dv_log_N.txt (or the sandboxed data dir of a dev run), newest by mtime.
Exit 1 if any gate fails, 2 if all that ran passed but some were skipped.
"""
import sys, re, glob, os, hashlib, pathlib, subprocess, tempfile, zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))
import build

FAKE_BUILD = "0.0.0-compat-test"   # what Compat.gd pretends under --coop-dev-compat-test


def _read(path):
    return open(path, encoding="utf-8", errors="replace").read().splitlines()


def _has(lines, pattern):
    rx = re.compile(pattern)
    return [l for l in lines if rx.search(l)]


def gate_verify(args):
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "verify.py")], capture_output=True, text=True)
    tail = r.stdout.strip().splitlines()[-1:] if r.stdout.strip() else []
    ok = r.returncode == 0 and tail and tail[0].startswith("PASS")
    ev = tail if ok else (r.stdout.strip().splitlines()[-8:] + r.stderr.strip().splitlines()[-4:])
    return ok, ev


def gate_release(args):
    files, rep = build.sources(True)
    ev = []
    ok = True
    if rep["problems"]:
        ok = False
        ev += ["FAIL malformed dev block: " + p for p in rep["problems"]]
    if rep["traces"]:
        ok = False
        ev += ["FAIL dev path outside a coop:dev block: " + t for t in rep["traces"]]
    names = {n for n, _ in files}
    for n in build.DEV_ONLY:
        if n in names:
            ok = False
            ev.append("FAIL dev-only file in the release zip: " + n)
    for n, data in files:
        text = data.decode("utf-8", errors="replace")
        for k, line in enumerate(text.split("\n"), 1):
            if build.DEV_BEGIN in line or build.DEV_END in line:
                ok = False
                ev.append("FAIL marker left in the release zip: %s:%d" % (n, k))
    ev.insert(0, "%d files, left out: %s, %d dev lines blanked" % (len(files), ", ".join(rep["left_out"]) or "nothing", rep["blanked"]))
    return ok, ev


def gate_repro(args):
    if build.sources(True)[1]["problems"]:
        return False, ["FAIL the release build stops on malformed dev blocks (gate 2)"]
    ev = []
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        for release in (False, True):
            hashes = []
            for k in (1, 2):
                out = pathlib.Path(tmp) / ("%s-%d.zip" % ("release" if release else "dev", k))
                build.build(out, release)
                with zipfile.ZipFile(out) as z:
                    if z.testzip() is not None:
                        ok = False
                        ev.append("FAIL corrupt zip: " + out.name)
                hashes.append(hashlib.sha256(out.read_bytes()).hexdigest())
            name = "dv-coop-release.zip" if release else "dv-coop.zip"
            if hashes[0] != hashes[1]:
                ok = False
                ev.append("FAIL %s differs between builds: %s vs %s" % (name, hashes[0], hashes[1]))
            else:
                ev.append("%s sha256 %s (twice)" % (name, hashes[0]))
    return ok, ev


def gate_compat(args):
    path = args.get("compat")
    if not path:
        return None, ["SKIP: pass --compat <dv log of a run with --coop-dev-compat-test>"]
    lines = _read(path)
    ev = [os.path.basename(path)]
    checks = [
        ("the game loaded the mod zip", bool(_has(lines, r"ModLoader: dv-coop\.zip loaded\.")), True),
        ("REFUSED with the faked build %s" % FAKE_BUILD, bool(_has(lines, r"COOP: REFUSED, .*%s" % re.escape(FAKE_BUILD))), True),
        ("the title-screen notice was shown", bool(_has(lines, r"COOP: compat notice shown")), True),
        ("no script extension installed", not _has(lines, r"COOP: installed extension|Installing script extension: .* <- res://dv-coop/"), True),
        ("no CoopNet started", not _has(lines, r"CoopNet attached|COOP: (waiting for Steam|no session requested|ENet )"), True),
    ]
    ok = True
    for what, good, _ in checks:
        ev.append("%s %s" % ("ok  " if good else "FAIL", what))
        ok = ok and good
    return ok, ev


def gate_normal(args):
    path = args.get("normal")
    if not path:
        return None, ["SKIP: pass --normal <dv log of a normal run, ideally with --coop-selftest>"]
    lines = _read(path)
    ev = [os.path.basename(path)]
    ok = True
    for what, good in [
        ("no refusal", not _has(lines, r"COOP: REFUSED")),
        ("modmain loading on build %s" % build_pin(), bool(_has(lines, r"COOP: modmain .* loading \(game %s\)" % re.escape(build_pin())))),
        ("script extensions installed", bool(_has(lines, r"COOP: installed extension"))),
        ("CoopNet attached", bool(_has(lines, r"COOP: modmain ready, CoopNet attached"))),
    ]:
        ev.append("%s %s" % ("ok  " if good else "FAIL", what))
        ok = ok and good
    if _has(lines, r"COOP-SELFTEST:"):
        good = bool(_has(lines, r"COOP-SELFTEST: PASS"))
        ev.append("%s selftest" % ("ok  " if good else "FAIL"))
        ok = ok and good
    else:
        ev.append("note: no --coop-selftest in this run")
    return ok, ev


def gate_errors(args):
    logs = [args[k] for k in ("compat", "normal") if args.get(k)]
    if not logs:
        return None, ["SKIP: no logs given"]
    ok = True
    ev = []
    for path in logs:
        for f in [path, os.path.join(os.path.dirname(path), "engine_log.txt")]:
            if not os.path.exists(f):
                ev.append("note: %s not found" % f)
                continue
            n = len(_has(_read(f), r"SCRIPT ERROR"))
            ev.append("%s %s: %d SCRIPT ERROR" % ("ok  " if n == 0 else "FAIL", f, n))
            ok = ok and n == 0
    return ok, ev


def build_pin():
    m = re.search(r'const BUILD = "([^"]+)"', (ROOT / "src" / "dv-coop" / "Compat.gd").read_text(encoding="utf-8"))
    return m.group(1) if m else "?"


GATES = [
    ("1 verify", gate_verify),
    ("2 release", gate_release),
    ("3 repro", gate_repro),
    ("4 compat", gate_compat),
    ("5 normal", gate_normal),
    ("6 errors", gate_errors),
]


def main(argv):
    args = {}
    i = 0
    while i < len(argv):
        if argv[i] in ("--compat", "--normal") and i + 1 < len(argv):
            hits = sorted(glob.glob(os.path.expanduser(argv[i + 1])), key=os.path.getmtime)
            if not hits:
                print("no file matches %s" % argv[i + 1])
                return 1
            args[argv[i][2:]] = hits[-1]   # newest if a glob matched several
            i += 2
        else:
            print(__doc__)
            return 1
    print("M6 gate, pin %s" % build_pin())
    failed = skipped = 0
    for name, fn in GATES:
        ok, ev = fn(args)
        status = "SKIP" if ok is None else ("PASS" if ok else "FAIL")
        print("%s  gate %s" % (status, name))
        for e in ev:
            print("      " + e)
        failed += ok is False
        skipped += ok is None
    print()
    if failed:
        print("FAIL: %d gate(s) failed" % failed)
        return 1
    if skipped:
        print("INCOMPLETE: everything that ran passed; %d gate(s) need a game log" % skipped)
        return 2
    print("PASS: every machine-checkable M6 gate passed. Human gates H1 and H2 are listed in docs/M6.md.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
