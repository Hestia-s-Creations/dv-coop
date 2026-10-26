# When the game updates

A runbook for an agent (or a person) after a Steam update to ΔV: Rings of Saturn. The mod is pinned to one game
build (`BUILD` in `src/dv-coop/Compat.gd`). On any other build it switches itself off and logs one line:

```
COOP: REFUSED, dv-coop is switched off: this is game build 1.91.0; dv-coop was made for 1.90.12. ...
```

The job is to find out whether anything the mod hooks has changed, fix what has, re-run the gates, and bump the pin.
Target time: about an hour of agent work when no hooked function changed (SPEC, *Definition of done*).

Rules that hold throughout:

- The decompiled source stays outside git: in `reference/` (gitignored) or a folder outside the repo. Never commit it,
  and never copy game code into `src/`. `ext/` scripts extend game scripts; they don't contain them.
- Never touch the player's own data (`%APPDATA%\dV` on Windows). Dev runs use the sandboxed data dirs from
  `tools/dvenv.sh`.
- Don't launch the game without the lead's go-ahead.
- `tools/build.py` without `--no-install` replaces `mods/dv-coop.zip` in the shared game folder. Only run it while you
  hold the game lock: `tools/dev2.sh` and `tools/dev3.sh` take it, `tools/stop.sh` releases it, and `DV_WHO` names
  you. build.py refuses to install while someone else holds the lock, or while the game runs without your lock. Don't
  rely on that: for anything that isn't your own run, use `--no-install`.
- Each file has one owner (see the current milestone doc). Send changes to a file you don't own to its owner.

## 1. Record what changed

```
python tools/verify.py                                   # the repo itself is intact
```

**Prerequisite: GDRE Tools 2.7.1** (Windows `gdre_tools.exe`, Linux `gdre_tools.x86_64`). It isn't in this repo.
Tim keeps a copy on the NAS under `dV-Coop/tools/` (see `docs/HANDOFF.md`). Upstream, it's release v2.7.1 of
GDRETools/gdsdecomp on GitHub. If you can reach neither, stop and ask the lead, because nothing below works without a
fresh recovery. Use the same version as last time. A different decompiler version can make a no-op update look like
a diff.

**Where the recovery lives.** The README puts it in `reference/` at the repo root (gitignored). From a worktree it
may be in the main checkout instead: on Tim's Windows box it is `C:/Users/Tim/dv-coop/reference`. This runbook calls
that folder `<ref>`.

Keep the previous recovery: rename `<ref>` to `<ref>-<old build>` (for example `reference-1.90.12`). Then recover the
new one into `<ref>` (about five seconds):

```
gdre_tools.exe --headless --recover="C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\Delta-V.pck" --output=<ref>
```

On Linux: `./gdre_tools.x86_64 --headless --recover=<path to Delta-V.pck> --output=<ref>`.

The new build number is the `text = "..."` line of `<ref>/VersionLabel.tscn`. `Compat.gameBuild()` reads the same
value at runtime, so the two always agree. Note the old and new numbers.

If GDRE fails, stop and report. Step 2c checks the engine version.

## 2. Diff the hooked seams

There are three kinds of seams. They're listed from most to least likely to break.

**a. Scripts the mod extends.** Every file in `src/dv-coop/ext/` starts `extends "res://<game script>"` and overrides
some of its functions. For each one, the script below checks three things: the parent script still exists, every
overridden function is still there with the same arguments, and how each overridden function's body changed. Save it
in your scratchpad, not in the repo, and run it from the repo root. Every ext file must end on an `ok` line. A `!!`
(gone) or `~~` (changed) line goes to step 3.

```python
# seams.py OLD NEW   e.g. python seams.py C:/Users/Tim/dv-coop/reference-1.90.12 C:/Users/Tim/dv-coop/reference
import re, sys, pathlib, difflib
old, new = map(pathlib.Path, sys.argv[1:3])
def funcs(text):
    out, name, body = {}, None, []
    for line in text.splitlines():
        m = re.match(r"(static\s+)?func\s+(\w+)\s*(\(.*)", line)
        if m:
            if name: out[name] = body
            name, body = m.group(2), [line]
        elif name:
            body.append(line)
    if name: out[name] = body
    return out
for ext in sorted(pathlib.Path("src/dv-coop/ext").glob("*.gd")):
    text = ext.read_text(encoding="utf-8")
    parent = re.search(r'extends\s+"res://([^"]+)"', text).group(1)
    mine = [m.group(2) for m in re.finditer(r"^(static\s+)?func\s+(\w+)", text, re.M)]
    po, pn = old / parent, new / parent
    if not pn.exists():
        print(f"!! {ext.name}: parent {parent} is GONE"); continue
    fo, fn = funcs(po.read_text(encoding="utf-8")), funcs(pn.read_text(encoding="utf-8"))
    overrides = [f for f in mine if f in fo]   # the rest are the mod's own helpers
    bad = 0
    for f in overrides:
        if f not in fn:
            print(f"!! {ext.name}: overridden {parent}::{f} is GONE")
            bad += 1
        elif fo[f] != fn[f]:
            sig = "SIGNATURE CHANGED" if fo[f][0] != fn[f][0] else "body changed"
            print(f"~~ {ext.name}: {parent}::{f} {sig}")
            print("\n".join(difflib.unified_diff(fo[f], fn[f], lineterm="", n=1)))
            bad += 1
    print(f"{'ok' if bad == 0 else 'XX'} {ext.name}: {parent}, {len(overrides)} overrides, {bad} changed or gone")
```

**b. Game API the net code calls.** The scripts in `src/dv-coop/net/` and `ui/` call into game autoloads and nodes by
name. That's CoopNet, Cell and RockSync, plus Own, Npc and Travel from M4 on. List every name they use:

```
grep -ohE "\b(CurrentGame|Shipyard|Loader|Tool|Settings|Debug|ModLoader)\.[a-zA-Z_]+" -r src/dv-coop | sort -u
```

For each `X.name`, grep `<ref>` for `func name` or `var name` in the autoload's script. The `[autoload]` section of
`project.godot` maps names to files. `Debug` and `Loader` are scenes (`Debug.tscn`, `Loader.tscn`); their code is in
`Debug.gd` and `Loader.gd`. Skip names that every Godot object has (`get`, `set`, `has_meta`, `set_meta`,
`get_meta`, `remove_meta`, `connect`, `emit_signal`, `has_method`, `get_node`, ...). Also skip `X.gd` matches; those
are paths, not calls. Then check the node fields the modules read directly. These are the ones most likely to move:

- `AsteroidSpawner.gd`: `spawnThings`, `slipstreamRadius`, `slipstream()`, `debrises`, `despawn()`,
  `spawnByBlueprint()`, `objectClass`, `getDensityByPosition()`, `kill()`, `asteroidIntersectionTest`
- `TheRing.gd`: `spawnNow`, `unspawnedOddities`, `unspawnedOdditiesLocation`
- `ships/ship-ctrl.gd`: `thrusterShedule`, `executeThrusterFire()`, `cutscene`, `setup`, `teleportBy()`,
  `vanish()`, `initialShockSupress`, the `apply*Damage()` family
- `asteroids/asteroid.gd` and `mineral*.gd`: `additionalScale`, `splitsTo`, `rnd`, `estimatedRadius`,
  `asteroidClass`, `mineralContent`, `composition`, `fracturing`

Every `res://` path the mod names must exist under `<ref>`:
`grep -ohE '"res://[^"]+"' -r src/dv-coop | grep -v dv-coop | sort -u`.

**c. The engine and GodotSteam.** Both are inside the exe, not the pck, so the decompile doesn't show them. This
script checks the strings the mod depends on. It only reads the exe and never runs the game. Run it from the repo
root:

```python
import re, pathlib
d = open(r"C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\Delta-V.exe", "rb").read()
src = " ".join(p.read_text(encoding="utf-8") for p in pathlib.Path("src/dv-coop").rglob("*.gd"))
calls = sorted(set(re.findall(r"\bSteam\.(\w+)", src)) - {"connect", "disconnect", "is_connected"})
signals = sorted(set(re.findall(r'Steam\.connect\("(\w+)"', src)))
for k in calls + signals + ["remote_steam_id"]:
    print(f"{d.count(k.encode()):3}  {k}")
print("engine:", sorted(set(m.decode() for m in re.findall(rb"\d\.\d[\w.]*\.stable[\w.]*", d))))
```

Every Steam call and signal the mod uses should be found at least once, and so should `remote_steam_id`, the sender
key that `readP2PPacket` returns (CoopNet reads it). On 1.90.12 the engine line reads
`['3.6.stable', '3.6.stable.custom_build']`. Any other version means the engine changed.

Finally, skim `git diff --no-index --stat <ref>-<old build> <ref>` for new or renamed spawn sites (`spawnByBlueprint`,
`createShipBy`) in `story/` and `comms/`. M4's spawn audit (`docs/M4-SPAWN-AUDIT.md`, on `main` once M4 is merged)
lists the ones members must not run.

## 3. Decide

- **Nothing in a, b or c changed:** go to step 4.
- **A body changed in a seam:** read it. The change may be somewhere the override doesn't depend on, so that the
  mod's override still does the right thing against the new parent. If so, note it and go on. Otherwise the file's
  owner re-points the hook, and the SPEC's *Game-side seams* table gets updated to match.
- **A function, field or script is gone, or a signature changed:** the owner re-points it before any gate runs. Each
  of these is a real fix; count about an extra hour of agent work for each.
- **The engine or GodotSteam changed:** stop and report to the lead with the step 2c output. An engine upgrade means
  porting the mod, not patching it.

Write down what you found, one line per seam that changed and what was done about it, for the PR description.

## 4. Re-run the gates on the new build

Game runs need the lead's go-ahead and the game lock. Use the dev zip. `tools/dev3.sh` takes the lock, then builds and
installs the zip for you. To build by hand while you hold the lock, run `python tools/build.py`. Launch every
instance with `--coop-any-build`, which lets the dev zip run on a build it isn't pinned to. The flag is blanked out
of release zips, so players can't use it.

1. `--coop-selftest` on one instance: the log shows `COOP-SELFTEST: PASS`, and the logged game version is the new build.
2. The M3 gate on `tools/dev3.sh`: `docs/M3.md`, *Gate*, items 1, 3, 4, 5 and 6.
3. The M4 gate (`docs/M4.md` *Gate*; `tools/gate_m4.py` reads the logs). Both are on `main` once M4 is merged.
4. Zero `SCRIPT ERROR` lines in every instance's `engine_log.txt`.

Anything that fails goes back to step 3 for its owner.

## 5. Bump the pin

1. `src/dv-coop/Compat.gd`: `const BUILD = "<new build>"`.
2. `src/dv-coop/modmain.gd`: raise `MOD_VERSION` (the lead's file).
3. Update the build number everywhere it is written: `grep -rn "<old build>" README.md llms.txt docs/ src/`. Today
   that means the README's first paragraph and its *Known limits*, the first line of `llms.txt`, and `Compat.BUILD`.
   Leave dated history alone (milestone docs, SPEC status lines).
4. `python tools/verify.py --update`.
5. Whoever holds the game lock makes two launches, then runs `tools/gate_m6.py` on their logs (M6 gates 4–6):
   - the dev zip with `--coop-dev-compat-test`: the refusal shows;
   - the release zip (`python tools/build.py --release`) with `--coop-selftest`: no refusal, and the selftest passes.

   `python tools/gate_m6.py --compat <dv log of the first> --normal <dv log of the second>` must exit 0. It also runs
   verify.py, the `--release --strict` build and the reproducibility check. Take the release zip's SHA-256 from its
   output.
6. Create a branch `update-<new build>` and open a PR to `main`. Include the findings from step 3, the gate results,
   and the release zip's SHA-256. The lead merges.

Keep `<ref>-<old build>` until the PR is merged. It is the baseline for the next update's diff.

## If the update can't be handled quickly

Until a matching dv-coop is out, players on the new build get the refusal notice and play the stock game. That is
the intended behaviour. Never ship a release built with the pin check removed. In the README's *Status* section, tell
users which game build the current release needs.
