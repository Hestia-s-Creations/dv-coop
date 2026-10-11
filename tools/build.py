"""Zip src/dv-coop into build/dv-coop.zip and copy it into the game's mods/ folder.

Usage: python tools/build.py [--no-install]
"""
import os, sys, zipfile, shutil, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "build" / "dv-coop.zip"
GAME = pathlib.Path(r"C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn")
MODS = GAME / "mods"

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
        MODS.mkdir(exist_ok=True)
        dst = MODS / OUT.name
        shutil.copy2(OUT, dst)
        print(f"installed -> {dst}")

if __name__ == "__main__":
    main()
