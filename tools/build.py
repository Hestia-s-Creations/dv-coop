"""Zip src/dv-coop into a mod zip and copy it into the game's mods/ folder.

Usage: python tools/build.py [--release] [--no-install]

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
  - any "--coop-dev-" flag or DVCOOP_ variable left outside a block is listed as a warning; --strict fails on it.

The game folder comes from DV_GAME if set, otherwise the first Steam install found:
Windows Steam, then the Flatpak Steam and native Steam libraries on Linux.
"""
import os, re, sys, zipfile, shutil, pathlib, hashlib

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
}
DEV_BEGIN = "# coop:dev{"
DEV_END = "# coop:dev}"
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
                    if DEV_TRACE.search(line.split("#", 1)[0]):
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

def install(zip_path):
    mods = find_game() / "mods"
    mods.mkdir(exist_ok=True)
    for old in mods.glob("dv-coop*.zip"):
        if old.name != INSTALL_NAME:
            old.unlink()
            print(f"removed {old} (the game would load both)")
    dst = mods / INSTALL_NAME
    shutil.copy2(zip_path, dst)
    print(f"installed {zip_path.name} -> {dst}")

def main():
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
