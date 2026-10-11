"""Zip src/dv-coop into build/dv-coop.zip and copy it into the game's mods/ folder.

Usage: python tools/build.py [--no-install]

The game folder comes from DV_GAME if set, otherwise the first Steam install found:
Windows Steam, then the Flatpak Steam and native Steam libraries on Linux.
"""
import os, sys, zipfile, shutil, pathlib

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

def main():
    OUT.parent.mkdir(exist_ok=True)
    if OUT.exists():
        OUT.unlink()
    count = 0
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_STORED) as z:
        for p in sorted(SRC.rglob("*")):
            if p.is_file():
                rel = p.relative_to(SRC).as_posix()   # dv-coop/modmain.gd
                z.write(p, rel)
                count += 1
    print(f"built {OUT} ({count} files)")
    if "--no-install" not in sys.argv:
        mods = find_game() / "mods"
        mods.mkdir(exist_ok=True)
        dst = mods / OUT.name
        shutil.copy2(OUT, dst)
        print(f"installed -> {dst}")

if __name__ == "__main__":
    main()
