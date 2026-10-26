"""Zip src/dv-coop into build/dv-coop.zip and copy it into the game's mods/ folder.

Usage: python tools/build.py [--no-install]

Installing is refused while another session holds the dev game lock (DV_LOCK, default ~/.dvcoop-gamelock, taken by
dev2/dev3 and released by tools/stop.sh), or while the game runs and we hold no lock: replacing mods/dv-coop.zip
under running instances corrupts their run. The holder is matched against DV_WHO (or, as tools/dvenv.sh does without
it, the repo folder). --no-install builds are always allowed. Unknown flags are an error.

The zip is reproducible: same source files, same bytes, on any OS. Its SHA-256 is printed so a downloaded
dv-coop.zip can be checked against a build from this repo.

The game folder comes from DV_GAME if set, otherwise the first Steam install found:
Windows Steam, then the Flatpak Steam and native Steam libraries on Linux.
"""
import os, sys, zipfile, shutil, pathlib, hashlib, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "build" / "dv-coop.zip"
GAME_DIR = "dV Rings of Saturn"
HOME = pathlib.Path.home()
CANDIDATES = [
    pathlib.Path(r"C:\Program Files (x86)\Steam\steamapps\common") / GAME_DIR,
    HOME / ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common" / GAME_DIR,
    HOME / ".local/share/Steam/steamapps/common" / GAME_DIR,
]

def find_game():
    if os.environ.get("DV_GAME"):
        return pathlib.Path(os.environ["DV_GAME"])
    for p in CANDIDATES:
        if p.is_dir():
            return p
    sys.exit("game folder not found; set DV_GAME to the folder holding the Delta-V binary")

def build(out):
    """Write the mod zip to out with fixed timestamps and permissions; return the file count."""
    count = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_STORED) as z:
        for p in sorted(SRC.rglob("*")):
            if p.is_file():
                info = zipfile.ZipInfo(p.relative_to(SRC).as_posix(), (1980, 1, 1, 0, 0, 0))   # dv-coop/modmain.gd
                info.external_attr = 0o644 << 16
                z.writestr(info, p.read_bytes().replace(b"\r\n", b"\n"))
                count += 1
    return count

FLAGS = {"--no-install"}

def lock_holder():
    """Who holds the dev game lock, or None. A lock we hold ourselves counts as free."""
    lock = pathlib.Path(os.environ.get("DV_LOCK") or (HOME / ".dvcoop-gamelock"))
    if not lock.is_dir():
        return None
    try:
        holder = (lock / "owner").read_text(encoding="utf-8").split()[0]
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

def guard(game):
    """Exit before touching mods/ if another session's run could be using it."""
    me = os.environ.get("DV_WHO") or "unset DV_WHO"
    shared = any(game.resolve() == c.resolve() for c in CANDIDATES if c.exists())
    if not shared:
        return   # a private copy (sandbox.sh's DV_GAME) isn't the locked install
    holder = lock_holder()
    if holder:
        sys.exit(f"not installing: the game is held by {holder} (you are {me}). The zip is built at {OUT}; "
                 f"wait for their run to end, or set DV_WHO if the lock is yours. --no-install builds are always allowed.")
    if game_running() and not lock_held_by_me():
        sys.exit(f"not installing: Delta-V is running and you ({me}) don't hold the game lock. The zip is built at {OUT}; "
                 f"take the lock (tools/dvenv.sh dv_lock) or close the game first.")

def main():
    args = sys.argv[1:]
    if any(a in ("-h", "--help") for a in args):
        print(__doc__)
        return
    unknown = [a for a in args if a not in FLAGS]
    if unknown:
        sys.exit("unknown option(s): %s; usage: python tools/build.py [--no-install]" % " ".join(unknown))
    OUT.parent.mkdir(exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    count = build(OUT)
    print(f"built {OUT} ({count} files)")
    print(f"sha256 {hashlib.sha256(OUT.read_bytes()).hexdigest()}")
    if "--no-install" not in sys.argv:
        game = find_game()
        guard(game)
        mods = game / "mods"
        mods.mkdir(exist_ok=True)
        dst = mods / OUT.name
        shutil.copy2(OUT, dst)
        print(f"installed -> {dst}")

if __name__ == "__main__":
    main()
