# dv-coop

A work-in-progress co-op mod for ΔV: Rings of Saturn: up to five players, each playing their own game,
sharing the same rocks whenever they fly near each other. Built for the Steam release (build 1.90.12, Godot 3.6 + GodotSteam).

**It is not playable yet.** Ships fly together and nearby players share the same asteroids, but mining together,
combat and the in-game join menu are still to come. See Status below.

- Design spec: [docs/SPEC.md](docs/SPEC.md) ([PDF](docs/SPEC.pdf))
- Check what's in this repo: [Verify it yourself](#verify-it-yourself)
- Setting it up with an AI agent: point it at [llms.txt](llms.txt)
- License: [MIT](LICENSE), covering this repo's code only, not the game

> This is an unofficial fan mod. It is not made, endorsed or supported by the developer of ΔV: Rings of Saturn
> (Kodera Software). You need your own copy of the game. This repo contains none of the game's files or code:
> the mod is a few GDScript files that load through the game's own mod loader (`--enable-mods`).

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
- **M3 shared rocks (2026-10-25): working on one PC with up to three players.** Players within 40,000 px form a
  *cell*; one of them (the incumbent, see the spec) simulates the asteroids and streams them to the others, who
  adopt its coordinate origin exactly (0 px jump) and suspend their own spawner. Measured: slow rocks agree within
  0.2 px, rocks moving ~95 px/s trail by ~6 px; authority upload ~16 kB/s with two members. A player can warp in,
  join, and the cell survives its authority quitting (handoff under 1 s) or crashing (1.5 s). Puppets of other
  players' ships take no local damage and never touch your save. Checked at six resolutions from 1280x720 to
  3440x1440 and at the game's UI-scale extremes. Details: [docs/M3.md](docs/M3.md).
- **M6 polish and release (in progress).** The mod checks the game build and switches itself off with a plain message
  on any other build; `tools/build.py --release` builds the zip for players without the dev tooling; a game-update
  runbook ([docs/UPDATING.md](docs/UPDATING.md)) and the troubleshooting section below. Plan: [docs/M6.md](docs/M6.md).
- Not yet proven: Steam P2P between two different Steam accounts and networks; a human flying into a cell
  (all M3 testing used dev flags on one PC); HiDPI laptops and Windows display scaling above 100%.

## Layout

```
src/dv-coop/            what gets zipped; paths inside the zip are res://dv-coop/...
  modmain.gd            ModLoader entry: checks the game build, installs script extensions, attaches CoopNet
  Compat.gd             the game build pin: on any other build the mod switches itself off and says why
  net/CoopNet.gd        Steam lobby + P2P transport, ENet fallback, ping/pong, puppets, module hooks
  net/Cell.gd           which players share a world, who simulates it, origin adoption, handoff
  net/RockSync.gd       asteroid net ids, recipes and streaming from the cell authority
  ext/ship-ctrl.gd      extends res://ships/ship-ctrl.gd (netControlled mode, intent capture, correction, puppet safety)
  ext/asteroid.gd       tracked rocks only break on the machine that simulates them
  ext/AsteroidSpawner.gd  never despawns tracked rocks or puppets; members don't slipstream
  ui/FriendOverlay.gd   friend markers drawn from beacons
tools/build.py          zips src/ -> build/dv-coop.zip, or build/dv-coop-release.zip with --release (reproducible,
                        prints its SHA-256) and copies it into <game>/mods/ as dv-coop.zip
tools/verify.py         checks the repo against MANIFEST.sha256 and the rules below
tools/spec_pdf.py       renders docs/SPEC.md to docs/SPEC.pdf
tools/setres.py         dev: per-instance window size and UI scale (RES_A/B/C, UI_A/B/C in dev3)
MANIFEST.sha256         every file in the repo and its SHA-256
llms.txt                setup instructions for AI agents
tools/dvenv.sh          game, data and launcher paths for the dev loops (Windows Git Bash or Linux)
reference/              decompiled game source (gitignored; regenerate with GDRE Tools, see below)
```

## Verify it yourself

You shouldn't have to take a stranger's mod on trust. One command, Python 3.8+ and nothing else (no game needed):

```
python tools/verify.py
```

It checks, and prints a report:

1. **Exactly these files.** Every file in the repo is listed in `MANIFEST.sha256` with its SHA-256, and nothing
   unlisted is present. Works on a clone or on GitHub's *Download ZIP*.
2. **No game files or code.** Everything is plain text (except `docs/SPEC.pdf`, a rendering of `docs/SPEC.md`),
   `src/` holds only `.gd` scripts, and each script in `src/dv-coop/ext/` *extends* a game script rather than copying it.
   The decompiled game source used during development lives in `reference/`, which is gitignored and never published.
3. **No hidden reach.** The mod's scripts are scanned for anything that runs programs, opens web pages, reads or writes
   files, or opens connections. None of that is allowed. What the mod *does* use is printed in full: the Steam lobby
   and P2P packets, the ENet transport for LAN testing, the game's launch options, your Windows/Linux user name as a
   fallback display name, and the game's own save slot.
4. **The zip matches the source.** It builds `dv-coop.zip` (everything, for development) and `dv-coop-release.zip`
   (dev-only code left out, see below) from `src/` and prints both SHA-256s. The build is reproducible, so a zip you
   download from anywhere should hash the same as the one built from the matching commit.

The mod is a handful of GDScript files in `src/dv-coop/` if you'd rather just read it; step 2 of the report prints how many and how long.

What the checks can't tell you: whether the code is *good*, and that the friends you play with are trustworthy.
Lobbies are friends-only, and peers can send each other ship data, so play with people you know.

After an intended change to any file, run `python tools/verify.py --update` and commit the new `MANIFEST.sha256`.

## Build and install

```
python tools/build.py              # development zip: dev flags, test bots, diagnostics
python tools/build.py --release    # the zip for playing: dev-only code left out
```

Copies the zip into the game's `mods/` folder as `dv-coop.zip`, removing any other `dv-coop*.zip` there (the game
loads every zip in `mods/`). Add `--no-install` to only build. The release build leaves out dev-only files and blanks
code between `# coop:dev{` and `# coop:dev}` (line numbers stay the same); `--strict` fails if a dev flag is left
outside those markers. The game folder is `DV_GAME` if set, otherwise the
first one found of:

- Windows: `C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn`
- Linux, Flatpak Steam: `~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/dV Rings of Saturn`
- Linux, native Steam: `~/.local/share/Steam/steamapps/common/dV Rings of Saturn`

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
launch the second with a different `APPDATA` on Windows (user data lives in `%APPDATA%\dV\`), or a different
`XDG_DATA_HOME` on Linux (user data lives in `$XDG_DATA_HOME/dV/`).

Add `--coop-selftest` to any launch to log a PASS/FAIL that the ship extension is active.

Dev flags:

```
--coop-autodive            skip menus: host loads its save and dives; guest dives into the host's world when told
--coop-slot=savegame-b.dv  use another save slot (so host and guest fly different ships)
```

Both dev scripts run on Windows (Git Bash) and Linux. They read `DV_GAME`, `DV_DATA` (the folder holding the main
instance's `dV/`) and `DV_INST` (where the extra instances' data goes) and otherwise find them, see `tools/dvenv.sh`.
With Flatpak Steam each instance is started inside the Steam sandbox (`flatpak run --command=<game binary>`) so it
can reach the Steam client; this path has not yet been run against the real game.

`tools/dev2.sh [guest-save]` does the whole two-instance loop: build, seed the guest data dir, launch both.
`tools/dev3.sh [offset_c] [slot_b] [slot_c]` launches three: A (server), B 5,000 px away (in range), C `offset_c`
px away (default 60,000, out of range). Note `savegame-c.dv` holds a stranded ship the game immediately rescues
to Enceladus, so C defaults to the main save.

## Sandbox (Linux, no Steam)

`tools/sandbox.sh [count]` runs 2 to 5 instances in a private headless display (`:99`, an Xvnc on a 0600 Unix socket,
no TCP port) from a hard-linked copy of the game with its own `mods/`. Each instance has its own `HOME` and
`XDG_DATA_HOME`, so SteamAPI finds no client: no Steam Cloud sync, no effect on a running Steam, and saves stay in
`~/.local/share/dvcoop-sandbox/data/<k>/`. Instance 1 is the ENet server; instance k dives (k-1) x 5,000 px off.
`tools/sandbox.sh stop` ends them. Screenshot with
`ffmpeg -loglevel error -y -f x11grab -video_size 1600x900 -i :99 -frames:v 1 shot.png`.
Without a GPU the game renders on the CPU (llvmpipe, about 10 fps), which is enough for the net code.

## Troubleshooting

Start with the newest log (see [Logs](#logs)) and search it for `COOP`.

| What you see | Why | What to do |
| --- | --- | --- |
| No `COOP:` lines at all in the log | The game didn't load mods. | Add `--enable-mods` to the launch options. Check that `<game>/mods/dv-coop.zip` exists and that the log has `ModLoader: dv-coop.zip loaded.` |
| `COOP: REFUSED, dv-coop is switched off: this is game build X; dv-coop was made for Y` (also shown on the title screen) | The game updated (or this is the demo), and the mod only runs on the build it was made for. The game plays normally without it. | Get the dv-coop release made for your game build. Until there is one, play without co-op. Maintainers: [docs/UPDATING.md](docs/UPDATING.md). |
| `ModLoader: dv-coop.zip failed to load.` | The zip is damaged or isn't a zip built by `tools/build.py`. | Rebuild it with `python tools/build.py --release` and compare the SHA-256 with the one published for the release. |
| Two copies of the mod in the log (every `COOP:` line twice) | More than one dv-coop zip in `mods/`. | Leave only `dv-coop.zip`. `tools/build.py` does this for you. |
| `COOP: no session requested, CoopNet idle` | The game started without a host or join option. | Launch with `--coop-host` or `--coop-join=<lobby id>` (or `--coop-enet-*` on a LAN). |
| `COOP: waiting for Steam` and nothing after it | Steam isn't running or isn't logged in. | Start Steam and log in, then start the game. |
| `COOP: Steam singleton missing` | The game was started without its Steam module, for example a non-Steam copy. | Steam lobbies need the Steam release. On a LAN, `--coop-enet-host` / `--coop-enet-join` work without Steam. |
| `lobby_joined ... response=` anything but 1 | The lobby is full (5 players), gone, or friends-only and you aren't on the host's friends list. | Ask the host for a fresh lobby id or an invite. |
| Friend shows as "no signal" | No beacon from them for 6 s. They crashed, lost their connection, or are sitting in a loading screen. | Wait a few seconds. If it stays that way, have them restart and rejoin. |
| You never see a friend's ship, but their marker is close | Puppets appear under 40,000 px (about 40 km) and only while both of you are in the rings. | Fly closer. Check the log for `entered range` and `puppet ... spawned`. |
| Time won't slow down (no bullet time) | In a shared area (a *cell*) time is pinned to normal speed for everyone. | Expected. It comes back once you fly apart (`CELL ... time scale released`). |
| The pause menu doesn't stop the game in a cell | Pausing would freeze everyone. | Expected. You're still in space, so find a quiet spot first. Alone, pause works as normal. |
| Script errors | A bug. | Look in `engine_log.txt` next to the logs, and report the error with your `dv_log_N.txt` and the dv-coop commit or release zip SHA-256. |

Before reporting a problem: `python tools/verify.py` must say `PASS` on the copy you built from, and say which game
build you have (title screen, bottom right).

### Known limits

- The game build is pinned (1.90.12). The mod switches itself off on any other build until a matching release is out.
- Up to five players per lobby. Each plays their own save: money, cargo and story stay yours.
- Bullet time and pause only work when you're alone.
- Lobbies are friends-only and peers trust each other's ship data. Play with people you know.
- Not yet proven: Steam P2P between different accounts and networks, long four-player sessions, and HiDPI screens
  or Windows display scaling above 100 %. These are the M6 human gates ([docs/M6.md](docs/M6.md)).

## Logs

`%APPDATA%\dV\logs\dv_log_N.txt` on Windows, `$XDG_DATA_HOME/dV/logs/dv_log_N.txt` on Linux (newest by mtime). All mod lines are prefixed `COOP:`.
Engine-level script errors go to `engine_log.txt` in the same folder.

## Regenerating the reference source

```
gdre_tools.exe --headless --recover="C:\Program Files (x86)\Steam\steamapps\common\dV Rings of Saturn\Delta-V.pck" --output=reference
```

On Linux: `./gdre_tools.x86_64 --headless --recover=<path to Delta-V.pck> --output=reference`.

GDRE Tools 2.7.1 recovers all 489 scripts in about five seconds. Re-run after every game update
and diff against the previous recovery to see whether a hooked function changed.
