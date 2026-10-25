"""Zip src/dv-coop into build/dv-coop.zip and copy it into the game's mods/ folder.

Usage: python tools/build.py [--no-install]

The zip is reproducible: same source files, same bytes, on any OS. Its SHA-256 is printed so a downloaded
dv-coop.zip can be checked against a build from this repo.

The game folder comes from DV_GAME if set, otherwise the first Steam install found:
Windows Steam, then the Flatpak Steam and native Steam libraries on Linux.
"""
import os, sys, zipfile, shutil, pathlib, hashlib

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

def main():
    OUT.parent.mkdir(exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    count = build(OUT)
    print(f"built {OUT} ({count} files)")
    print(f"sha256 {hashlib.sha256(OUT.read_bytes()).hexdigest()}")
    if "--no-install" not in sys.argv:
        mods = find_game() / "mods"
        mods.mkdir(exist_ok=True)
        dst = mods / OUT.name
        shutil.copy2(OUT, dst)
        print(f"installed -> {dst}")

if __name__ == "__main__":
    main()
