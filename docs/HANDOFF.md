# dv-coop handoff (written 2026-10-10, for continuing on Linux)

Everything a fresh session needs to pick this up without re-deriving it. The spec is in `SPEC.md`
next to this file (exported from the live Claude Doc; the three diagrams are text placeholders there)
and the live, editable version is https://claude.ai/code/artifact/ab50c617-6d3a-4a2a-922a-e30e64023af3.

## Where things are

| What | Where |
| --- | --- |
| Mod source (this repo) | `dv-coop/` on the NAS, `C:\Users\Tim\dv-coop` on the Windows box. Uncommitted git working tree. |
| Decompiled game source | `dv-coop/reference/` (gitignored, 108 MB). Regenerate with GDRE Tools, see README. |
| Windows game install, build 1.90.12 | NAS `dV-Coop/game-win64-1.90.12/` (exe + 1.5 GB pck + steam_api64.dll). Only the pck matters on Linux, as decompile input; Steam installs the native Linux build. |
| Windows saves and settings | NAS `dV-Coop/saves-windows/` (copy of `%APPDATA%\dV`, minus logs). |
| GDRE Tools 2.7.1, Windows and Linux | NAS `dV-Coop/tools/` |

## State of the work

- M0 spike: passed. Official ModLoader loads the zip, `installScriptExtension` makes `ext/ship-ctrl.gd` live on real
  ships, Steam lobby creation works from a direct exe launch (Steam running, no steam_appid.txt needed), ENet packets
  flow between instances at ~16 ms.
- M1 two ships: works. Owner-authoritative ship transforms; other side streams intent (thruster schedule, 30 Hz) and
  state (transform, 20 Hz); puppet is velocity-corrected in `_integrate_forces`, snaps past 400 px. ~10 kB/s each way.
- Spec v2 (full co-op, up to 5 players, join anywhere, any distance): "local bubbles, shared cells". See SPEC.md.
- M2 mesh + beacons + markers: works on three instances. Peers dict, ENet star relay for dev, 1 Hz beacons,
  puppets under 40,000 px (drop past 45,000), friend-marker overlay at any distance.
- Next: M3 cells. Authority = lowest peer id among players in range; members suspend their spawner, adopt the
  authority's `globalOffset` exactly, and track the authority's asteroids streamed by distance tier.

Unproven: Steam P2P between two different Steam accounts (code written, never carried a packet); a hand-flown
formation test; a hand-flown approach from out of range into range.

## Gotchas learned the hard way

- `"x" in CurrentGame` is a GDScript parse error on autoloads in this build. Use `CurrentGame.get("x")`.
- Install script extensions in `modmain._init`, before the Shipyard autoload loads ship scenes.
- Overriding `_process` / `_physics_process` / `_ready` / `_integrate_forces` in an extension must call the parent
  (`._process(delta)`), or the ship stops working.
- Apply all network state on the physics tick, never from a packet callback (`thread_model=2`, ship has a mutex).
- `thrusterShedule` is consumed and cleared by `executeThrusterFire` every frame; the puppet must re-apply the last
  received schedule each frame before parent `_process`. The `fired` dict (weapons) is reset at the top of parent
  `_process`, so weapon replication needs its own hook (not done yet).
- Godot 3 `Vector2` is float32. Global ring coordinates at ~12,000,000 px have ~1 px precision, ~2-4 px at 30,000,000.
  Fine for beacons and spawn points; inside a cell, members must adopt the authority's origin exactly.
- Save slot `savegame-c.dv` holds a stranded ship that the game rescues to Enceladus within a minute. Don't use it
  for a dive test.
- Two instances on one PC need separate user-data dirs: on Windows, a different `APPDATA`; on Linux, a different
  `HOME` or `XDG_DATA_HOME` (user:// is `~/.local/share/dV`).
- Auto-dive (`--coop-autodive`) skips Enceladus: `loadFromFile()`, set `CurrentGame.diveTarget`, `Loader.go("res://Game.tscn")`.
  `diveTarget` is only set by `newGame` / the station picker, so it is (0,0) after a load.
- Screen capture (PowerShell `CopyFromScreen`) is a fine way to see what the game is drawing without a human.

## Linux notes

- The mod is pure GDScript in a zip: identical on Linux. The Linux game build has the same GodotSteam module.
- Mods folder: `<steam library>/steamapps/common/dV Rings of Saturn/mods/` next to the Linux binary. Launch with
  `--enable-mods` (Steam launch options, or run the binary directly with Steam running).
- Logs: `~/.local/share/dV/logs/dv_log_N.txt` and `engine_log.txt`.
- `tools/build.py` has the Windows game path hard-coded in `GAME`; change it or add a `DV_GAME` env override.
- `tools/dev2.sh` / `dev3.sh` use `APPDATA` and `cygpath`; on Linux replace with `HOME=/tmp/dvcoop_instB` and the
  Linux binary name.
- GDRE Tools Linux: `./gdre_tools.x86_64 --headless --recover=<Delta-V.pck> --output=reference`.
