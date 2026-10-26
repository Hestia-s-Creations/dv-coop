"""Zip src/dv-coop into a mod zip and copy it into the game's mods/ folder.

Usage: python tools/build.py [--release] [--strict] [--no-install]

  (default)   build/dv-coop.zip, everything in src/ (dev flags, DevBot, diagnostics)
  --release   build/dv-coop-release.zip, the zip for players: dev-only files left out and dev-only blocks blanked

Both zips are reproducible: same source files, same bytes, on any OS. The SHA-256 is printed so a downloaded zip can be
checked against a build from this repo. Whichever zip is installed lands in <game>/mods/ as dv-coop.zip, and any other
dv-coop*.zip there is removed first, because the game loads every zip in mods/.

Dev-only code in release builds:
  - files listed in DEV_ONLY are not in the zip. A module that may be missing has to be loaded through a
    ResourceLoader.exists() check (CoopNet.MODULES and modmain.EXTENSIONS already do this).
  - lines from "# coop:dev{" to "# coop:dev}" (inclusive, each marker on its own line) are replaced by empty lines,
    so line numbers in a release log match the source. A block must hold whole statements, and the code around it
    must still parse without it (a function or branch must keep at least one statement of its own).
  - any "--coop-dev-" flag or DVCOOP_ variable left outside a block is listed as a warning, and so is a direct
    load("res://...") of a DEV_ONLY file; --strict fails on them.

Installing is refused while another session holds the dev game lock (DV_LOCK, default ~/.dvcoop-gamelock, taken by
dev2/dev3 and released by tools/stop.sh): replacing mods/dv-coop.zip under running instances corrupts their run. The
holder is matched against DV_WHO (or, as tools/dvenv.sh does without it, the repo folder). Unknown flags are an error.

The game folder comes from DV_GAME if set, otherwise the first Steam install found:
Windows Steam, then the Flatpak Steam and native Steam libraries on Linux.
"""
import os, re, sys, zipfile, shutil, pathlib, hashlib, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "build" / "dv-coop.zip"
OUT_RELEASE = ROOT / "build" / "dv-coop-release.zip"
INSTALL_NAME = "dv-coop.zip"
GAME_DIR = "dV Rings of Saturn"
HOME = pathlib.Path.home()
CANDIDATES = [
    pathlib.Path(r"C:\Program Files (x86)\Steam\steamapps\common") / GAME_DIR,
    HOME / ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common" / GAME_DIR,
    HOME / ".local/share/Steam/steamapps/common" / GAME_DIR,
]

# Paths inside the zip that only exist for development and gates.
DEV_ONLY = {
    "dv-coop/net/DevBot.gd",
    "dv-coop/net/PauseProbe.gd",   # M4 gate 11 input probe, made by Npc.gd's --coop-dev-pause
}
DEV_BEGIN = "# coop:dev{"
DEV_END = "# coop:dev}"
# a direct load of a dev-only file outside a block would fail in a release zip (a path in a list that is checked with
# ResourceLoader.exists before loading, like CoopNet.MODULES, is fine)
DEV_LOAD = re.compile(r'\bload\(\s*"res://(%s)"' % "|".join(re.escape(p) for p in sorted(DEV_ONLY)))
DEV_TRACE = re.compile(r"--coop-(dev-|autodive|dive-offset|slot=|warp-to-peer|any-build)|DVCOOP_")

def find_game():
    if os.environ.get("DV_GAME"):
        return pathlib.Path(os.environ["DV_GAME"])
    for p in CANDIDATES:
        if p.is_dir():
            return p
    sys.exit("game folder not found; set DV_GAME to the folder holding the Delta-V binary")

def strip_dev(name, text):
    """Blank the dev blocks in one script. Returns (text, blanked line count, problems)."""
    out = []
    problems = []
    inside = None   # (line number, indent) of the open marker
    blanked = 0
    lines = text.split("\n")
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if s == DEV_BEGIN:
            if inside:
                problems.append(f"{name}:{n}: {DEV_BEGIN} inside the block opened at line {inside[0]}")
            inside = (n, len(line) - len(line.lstrip()))
        if inside:
            out.append("")
            blanked += 1
            if s == DEV_END:
                inside = None
            continue
        if s == DEV_END:
            problems.append(f"{name}:{n}: {DEV_END} without {DEV_BEGIN}")
        out.append(line)
    if inside:
        problems.append(f"{name}:{inside[0]}: {DEV_BEGIN} never closed")
    # a block header (if/for/func/...) whose whole body was blanked no longer parses
    # (a statement continued with a trailing backslash counts as one line at the indent of its first line)
    code = []
    for n, l in enumerate(out, 1):
        if not l.strip() or l.strip().startswith("#"):
            continue
        if code and code[-1][1].split("#", 1)[0].rstrip().endswith("\\"):
            code[-1] = (code[-1][0], code[-1][1].split("#", 1)[0].rstrip()[:-1] + " " + l.strip())
        else:
            code.append((n, l))
    for (n, l), nxt in zip(code, code[1:] + [(None, "")]):
        if l.split("#", 1)[0].rstrip().endswith(":"):
            ind = len(l) - len(l.lstrip())
            nind = len(nxt[1]) - len(nxt[1].lstrip()) if nxt[0] else -1
            if nind <= ind:
                problems.append(f"{name}:{n}: nothing left inside this block after stripping dev code")
    return "\n".join(out), blanked, problems

def sources(release):
    """(zip path, bytes) for every file that goes in the zip, sorted, LF line endings. Release: dev code removed."""
    files = []
    report = {"left_out": [], "blanked": 0, "problems": [], "traces": []}
    for p in sorted(SRC.rglob("*")):
        if not p.is_file():
            continue
        name = p.relative_to(SRC).as_posix()   # dv-coop/modmain.gd
        data = p.read_bytes().replace(b"\r\n", b"\n")
        if release:
            if name in DEV_ONLY:
                report["left_out"].append(name)
                continue
            if name.endswith(".gd"):
                text, blanked, problems = strip_dev(name, data.decode("utf-8"))
                report["blanked"] += blanked
                report["problems"] += problems
                for n, line in enumerate(text.split("\n"), 1):
                    code = line.split("#", 1)[0]
                    if DEV_TRACE.search(code) or DEV_LOAD.search(code):
                        report["traces"].append(f"{name}:{n}: {line.strip()}")
                data = text.encode("utf-8")
        files.append((name, data))
    return files, report

def build(out, release=False):
    """Write the mod zip to out with fixed timestamps and permissions; return the file count.
    Exits on a malformed dev block in a release build."""
    files, report = sources(release)
    if report["problems"]:
        sys.exit("release build stopped, dev blocks are malformed:\n  " + "\n  ".join(report["problems"]))
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for name, data in files:
            info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o644 << 16
            z.writestr(info, data)
    build.report = report
    return len(files)

FLAGS = {"--release", "--strict", "--no-install"}

def lock_holder():
    """Who holds the dev game lock, or None. A lock we hold ourselves counts as free."""
    lock = pathlib.Path(os.environ.get("DV_LOCK") or (HOME / ".dvcoop-gamelock"))
    owner = lock / "owner"
    if not lock.is_dir():
        return None
    try:
        holder = owner.read_text(encoding="utf-8").split()[0]
    except (OSError, IndexError):
        return "unknown (lock folder without an owner file)"
    me = os.environ.get("DV_WHO")
    if me and holder == me:
        return None
    # dvenv.sh writes $(pwd) when DV_WHO is unset: /c/Users/... in Git Bash
    p = holder
    if len(p) > 2 and p[0] == "/" and p[2] == "/":
        p = p[1] + ":" + p[2:]
    try:
        if pathlib.Path(p).resolve() == ROOT:
            return None
    except OSError:
        pass
    return holder

def lock_held_by_me():
    lock = pathlib.Path(os.environ.get("DV_LOCK") or (HOME / ".dvcoop-gamelock"))
    return lock.is_dir() and lock_holder() is None

def game_running():
    """True if any Delta-V process is running (Windows tasklist, else pgrep)."""
    try:
        if os.name == "nt":
            out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq Delta-V.exe", "/NH"], capture_output=True, text=True).stdout
            return "Delta-V.exe" in out
        return subprocess.run(["pgrep", "-f", "Delta-V"], capture_output=True).returncode == 0
    except OSError:
        return False

def install(zip_path):
    me = os.environ.get("DV_WHO") or "unset DV_WHO"
    game = find_game()
    shared = any(game.resolve() == c.resolve() for c in CANDIDATES if c.exists())
    holder = lock_holder() if shared else None   # a private copy (sandbox.sh's DV_GAME) isn't the locked install
    if holder:
        sys.exit(f"not installing: the game is held by {holder} (you are {me}). The zip is built at {zip_path}; "
                 f"wait for their run to end, or set DV_WHO if the lock is yours. --no-install builds are always allowed.")
    if shared and game_running() and not lock_held_by_me():
        sys.exit(f"not installing: Delta-V is running and you ({me}) don't hold the game lock. The zip is built at {zip_path}; "
                 f"take the lock (tools/dvenv.sh dv_lock) or close the game first.")
    mods = game / "mods"
    mods.mkdir(exist_ok=True)
    for old in mods.glob("dv-coop*.zip"):
        if old.name != INSTALL_NAME:
            old.unlink()
            print(f"removed {old} (the game would load both)")
    dst = mods / INSTALL_NAME
    shutil.copy2(zip_path, dst)
    print(f"installed {zip_path.name} -> {dst}")

def main():
    args = sys.argv[1:]
    if any(a in ("-h", "--help") for a in args):
        print(__doc__)
        return
    unknown = [a for a in args if a not in FLAGS]
    if unknown:
        sys.exit("unknown option(s): %s\nusage: python tools/build.py [--release] [--strict] [--no-install]" % " ".join(unknown))
    release = "--release" in sys.argv
    out = OUT_RELEASE if release else OUT
    out.parent.mkdir(exist_ok=True)
    if out.exists():
        out.unlink()
    count = build(out, release)
    print(f"built {out} ({count} files)")
    print(f"sha256 {hashlib.sha256(out.read_bytes()).hexdigest()}")
    if release:
        r = build.report
        print(f"release: left out {', '.join(r['left_out']) or 'nothing'}; {r['blanked']} dev lines blanked")
        for t in r["traces"]:
            print(f"warning: dev path outside a coop:dev block: {t}")
        if r["traces"] and "--strict" in sys.argv:
            sys.exit(f"{len(r['traces'])} dev path(s) outside coop:dev blocks (--strict)")
    if "--no-install" not in sys.argv:
        install(out)

if __name__ == "__main__":
    main()
