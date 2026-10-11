# dv-coop

Networked 2-player co-op mod for ΔV: Rings of Saturn (Steam build 1.90.12, Godot 3.6 + GodotSteam).
Spec: https://claude.ai/code/artifact/ab50c617-6d3a-4a2a-922a-e30e64023af3

## Status

- **M0 spike (2026-10-09): PASSED.** Mod loads through the official ModLoader, the `ship-ctrl.gd`
  script extension is live on real ships, Steam lobby creation works from a direct exe launch,
  and hello/ping/pong packets flow between two instances (ENet on one PC, ~16 ms RTT).
- **M1 two ships (2026-10-09): working, formation gate pending a human pilot.** Both instances auto-enter
  one dive at the same world offset, exchange ship configs, and each spawns a `netControlled` puppet
  of the other's ship. Each machine owns its own ship's transform; the other side streams intent
  (thruster schedule, 30 Hz) and state (transform, 20 Hz) and the puppet is velocity-corrected toward
  it. About 10 kB/s each way. Both sides agree on separation to within 2 px.
- **Spec v2 (2026-10-09): full co-op.** Up to 5 players, each playing their own full game; 1 Hz beacons
  to everyone; players within 40,000 px form a *cell* whose lowest peer id simulates the rocks for the
  others. See the spec for the whole model.
- **M2 mesh + beacons (2026-10-09): working on three instances.** Peers dict instead of host/guest, ENet
  star with server relay for dev, beacons, range-based puppets (spawn under 40,000 px, drop past 45,000),
  and a friend-marker overlay (chevron at the screen edge, name, distance) that works at any distance.
  Out-of-range peers cost about 1 kB/s.
- Not yet proven: Steam P2P packets between two different Steam accounts (needs a second person);
  10 minutes of hand-flown formation with no rubber-banding (needs a pilot).

## Layout

```
src/dv-coop/            what gets zipped; paths inside the zip are res://dv-coop/...
  modmain.gd            ModLoader entry: installs script extensions, attaches CoopNet
  net/CoopNet.gd        Steam lobby + P2P transport, ENet fallback, ping/pong
  ext/ship-ctrl.gd      extends res://ships/ship-ctrl.gd (netControlled mode, intent capture, correction)
  ui/FriendOverlay.gd   friend markers drawn from beacons
tools/build.py          zips src/ -> build/dv-coop.zip and copies it into <game>/mods/
reference/              decompiled game source (gitignored; regenerate with GDRE Tools, see below)
```

## Build and install

```
python tools/build.py
```

Copies `build/dv-coop.zip` into `C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\mods\`.

## Run

The game only loads mods with `--enable-mods`. Either put that in Steam launch options, or run the
exe directly (Steam must be running; the Steam API initializes fine without a Steam launch).

Host (Steam, friends-only lobby; the lobby id is printed in the log):

```
Delta-V.exe --enable-mods --coop-host
Delta-V.exe --enable-mods --coop-host --coop-invite     # also pops the Steam invite overlay
```

Guest (Steam):

```
Delta-V.exe --enable-mods --coop-join=<lobby id>
```

Accepting a Steam overlay invite also works (`join_requested` is handled).

LAN / same-PC dev loop (no Steam lobby):

```
Delta-V.exe --enable-mods --coop-enet-host=7777
Delta-V.exe --enable-mods --coop-enet-join=127.0.0.1:7777
```

Two instances on one PC need separate user data dirs so saves and logs don't collide:
launch the second with a different `APPDATA` (user data lives in `%APPDATA%\dV\`).

Add `--coop-selftest` to any launch to log a PASS/FAIL that the ship extension is active.

Dev flags:

```
--coop-autodive            skip menus: host loads its save and dives; guest dives into the host's world when told
--coop-slot=savegame-b.dv  use another save slot (so host and guest fly different ships)
```

`tools/dev2.sh [guest-save]` does the whole two-instance loop: build, seed the guest data dir, launch both.
`tools/dev3.sh [offset_c] [slot_b] [slot_c]` launches three: A (server), B 5,000 px away (in range), C `offset_c`
px away (default 60,000, out of range). Note `savegame-c.dv` holds a stranded ship the game immediately rescues
to Enceladus, so C defaults to the main save.

## Logs

`%APPDATA%\dV\logs\dv_log_N.txt` (newest by mtime). All mod lines are prefixed `COOP:`.
Engine-level script errors go to `%APPDATA%\dV\logs\engine_log.txt`.

## Regenerating the reference source

```
gdre_tools.exe --headless --recover="C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\Delta-V.pck" --output=reference
```

GDRE Tools 2.7.1 recovers all 489 scripts in about five seconds. Re-run after every game update
and diff against the previous recovery to see whether a hooked function changed.
