# When the game updates

A runbook for an agent (or a person) after a Steam update to ΔV: Rings of Saturn. The mod is pinned to one game
build (`BUILD` in `src/dv-coop/Compat.gd`). On any other build it switches itself off and logs one line:

```
COOP: REFUSED, dv-coop is switched off: this is game build 1.91.0; dv-coop was made for 1.90.12. ...
```

The job is to find out whether anything the mod hooks has changed, fix what has, re-run the gates, and bump the pin.
Target time: about an hour of agent work when no hooked function changed (SPEC, *Definition of done*).

Rules that hold throughout:

- The decompiled source goes in `reference/` (gitignored) or another folder outside the repo. Never commit it, and
  never copy game code into `src/`. `ext/` scripts extend game scripts, they don't contain them.
- Never touch the player's own data (`%APPDATA%\dV` on Windows). Dev runs use the sandboxed data dirs from
  `tools/dvenv.sh`.
- Don't launch the game without the lead's go-ahead, and take the game lock (`DV_WHO`, `tools/stop.sh`) before
  running `tools/build.py`, which installs into the game folder.
- Each file has one owner (see the current milestone doc). Send changes to a file you don't own to its owner.

## 1. Record what changed

```
python tools/verify.py                                   # the repo itself is intact
```

Keep the previous recovery: rename `reference/` to `reference-<old build>/` (for example `reference-1.90.12/`).
Then recover the new one (GDRE Tools 2.7.1, about five seconds):

```
gdre_tools.exe --headless --recover="C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\Delta-V.pck" --output=reference
```

On Linux: `./gdre_tools.x86_64 --headless --recover=<path to Delta-V.pck> --output=reference`.

The new build number is the `text = "..."` line of `reference/VersionLabel.tscn`. That is the same value
`Compat.gameBuild()` reads at runtime, so they agree by construction. Note the old and new numbers.

If GDRE fails, or reports a Godot version other than 3.x, stop and report: an engine upgrade means the mod has to be
ported, not patched.

## 2. Diff the hooked seams

Three kinds of seams, from most to least likely to break:

**a. Scripts the mod extends.** Every file in `src/dv-coop/ext/` starts `extends "res://<game script>"` and overrides
some of its functions. For each one, check that the parent script still exists, that every overridden function
still exists with the same arguments, and read the diff of those functions. Run this from the repo root, with the
script saved in your scratchpad (not in the repo):

```python
# seams.py OLD NEW   e.g. python seams.py reference-1.90.12 reference
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
    for f in mine:
        if f not in fo:
            continue   # the mod's own helper, not an override
        if f not in fn:
            print(f"!! {ext.name}: overridden {parent}::{f} is GONE")
        elif fo[f] != fn[f]:
            sig = "SIGNATURE CHANGED" if fo[f][0] != fn[f][0] else "body changed"
            print(f"~~ {ext.name}: {parent}::{f} {sig}")
            print("\n".join(difflib.unified_diff(fo[f], fn[f], lineterm="", n=1)))
    print(f"ok {ext.name}: {parent} checked ({len(mine)} funcs)")
```

**b. Game API the net code calls.** CoopNet, Cell, RockSync, Own, Npc and FriendOverlay call into game autoloads and
nodes by name. List every name they use and check that each still exists in the new source:

```
grep -ohE "\b(CurrentGame|Shipyard|Loader|Tool|Settings|Debug|ModLoader)\.[a-zA-Z_]+" -r src/dv-coop | sort -u
```

For each `X.name`, grep `reference/` for `func name` or `var name` in the autoload's script (`project.godot`'s
`[autoload]` section maps names to files). Also check the node fields the modules read directly. These are the ones
most likely to move:

- `AsteroidSpawner.gd`: `spawnThings`, `slipstreamRadius`, `slipstream()`, `debrises`, `despawn()`,
  `spawnByBlueprint()`, `objectClass`, `getDensityByPosition()`, `kill()`, `asteroidIntersectionTest`
- `TheRing.gd`: `spawnNow`, `unspawnedOddities`, `unspawnedOdditiesLocation`
- `ships/ship-ctrl.gd`: `thrusterShedule`, `executeThrusterFire()`, `cutscene`, `setup`, `teleportBy()`,
  `vanish()`, `initialShockSupress`, the `apply*Damage()` family
- `asteroids/asteroid.gd` and `mineral*.gd`: `additionalScale`, `splitsTo`, `rnd`, `estimatedRadius`,
  `asteroidClass`, `mineralContent`, `composition`, `fracturing`
- resource paths the mod loads by string: `res://VersionLabel.tscn`, `res://hud/NotoMono-Regular.ttf` and the CJK/
  Thai fallbacks, `res://ships/modules/ClaimOwner.gd`, `res://TitleScreen.tscn`, `res://Game.tscn`

A quick way to see every `res://` path the mod names:
`grep -ohE '"res://[^"]+"' -r src/dv-coop | grep -v dv-coop | sort -u`. Check that each one exists under `reference/`.

**c. The engine and GodotSteam.** Both live in the exe, not the pck, so the decompile doesn't show them. Check the
strings the transport depends on (read-only, it doesn't run the game):

```python
d = open(r"C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\Delta-V.exe", "rb").read()
for k in [b"remote_steam_id", b"readP2PPacket", b"sendP2PPacket", b"getAvailableP2PPacketSize", b"createLobby",
          b"joinLobby", b"lobby_created", b"lobby_joined", b"lobby_chat_update", b"p2p_session_request",
          b"join_requested", b"acceptP2PSessionWithUser", b"setLobbyData"]:
    print(k.decode(), d.count(k))
```

Each one should be found at least once. A zero means GodotSteam changed its API. In particular,
`readP2PPacket`'s sender key (`remote_steam_id` in 1.90.12) is read by `CoopNet._physics_process`.

Finally, skim `git diff --no-index --stat reference-<old> reference` for new or renamed spawn sites
(`spawnByBlueprint`, `createShipBy`) in `story/` and `comms/`. M4's spawn audit (`docs/M4-SPAWN-AUDIT.md`) lists the
ones members must not run.

## 3. Decide

- **Nothing in a, b or c changed:** go to step 4.
- **A body changed in a seam:** read it. If the mod's override still does the right thing against the new parent
  (the change is somewhere the override doesn't depend on), note it and go on. Otherwise the file's owner re-points
  the hook, and the SPEC's *Game-side seams* table gets updated to match.
- **A function, field or script is gone, or a signature changed:** the owner re-points it before any gate runs. Each
  of these is a real fix; count about an extra hour of agent work for each.
- **The engine or GodotSteam changed:** stop and report to the lead with the step 2c output.

Write down what you found (one line per seam that changed and what was done) for the PR description.

## 4. Re-run the gates on the new build

Use the dev zip (`python tools/build.py`). Launch every instance with `--coop-any-build`, which lets the dev zip run
on a build it isn't pinned to. The flag is blanked out of release zips, so players can't use it.

1. `--coop-selftest` on one instance: `COOP-SELFTEST: PASS`, and the logged game version is the new build.
2. M3 gate on `tools/dev3.sh` (docs/M3.md *Gate*, items 1, 3, 4, 5, 6).
3. M4 gate (`docs/M4.md` *Gate*; `tools/gate_m4.py` reads the logs).
4. Zero `SCRIPT ERROR` lines in every instance's `engine_log.txt`.

Anything failing goes back to step 3 for its owner.

## 5. Bump the pin

1. `src/dv-coop/Compat.gd`: `const BUILD = "<new build>"`.
2. `src/dv-coop/modmain.gd`: raise `MOD_VERSION` (lead's file).
3. The build number in `README.md` (top paragraph), `llms.txt`, and the SPEC header, if they name it.
4. One launch with the dev zip and no `--coop-any-build`: no `REFUSED` line. One launch with
   `--coop-dev-compat-test`: the refusal shows (M6 gate 3).
5. `python tools/build.py --release --strict --no-install` and note the SHA-256.
6. `python tools/verify.py --update`, then `python tools/verify.py` must pass.
7. Branch `update-<new build>`, open a PR to `main` with the findings from step 3, the gate results, and the release
   zip's SHA-256. The lead merges.

Keep `reference-<old build>/` until the PR is merged. It is the baseline for the next update's diff.

## If the update can't be handled quickly

Players on the new build get the refusal notice and play stock until a matching dv-coop is out. That is the
intended behaviour. Never ship a release built with the pin check removed. Tell users in the README *Status* section
which game build the current release needs.
