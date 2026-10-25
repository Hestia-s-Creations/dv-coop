# M4 groundwork: spawn-site audit

Goal: find every place in the game that creates a ship or world body outside the stock rock streaming, and decide how
each behaves inside a cell. SPEC rule (*Decisions*, NPCs and story): in a cell, only the authority runs story events and
NPC spawns; members suppress theirs and see the authority's NPCs as puppets. This is the measurement for the SPEC risk
"Story suppression misses a spawn site". No code changes yet.

Source: decompiled 1.90.12 under `reference/` (not in the repo). Line numbers below are `reference/` paths and lines;
a sample of them was re-checked by hand. Read-only audit, 2026-10-25.

## Headline

- **52 sites** in 30 scripts (SPEC guessed about 40). Excluded on purpose: the stock rock streaming in
  `AsteroidSpawner.gd`, `enceladus/**` (station, single player), UI, `tests/`.
- **32 are already suppressed on members by M3.** Almost all story content reaches the world through one funnel:
  `AsteroidSpawner._physics_process` → `spawnProperThings` (only `if spawnThings`) → `TheRing.getOddityAt` →
  event node `makeAt(pos)` → `spawnByBlueprint`. Cell sets `spawnThings = false` on members, so every story event,
  NPC, pirate, rescue, race, minefield and derelict (including the timer-driven follow-ups that queue through
  `TheRing.spawnNow`) only ever runs on the authority.
- **8 need a gate** (they bypass the funnel). All 8 only fire on a member if the member *creates the body locally*.
  In M3 members only mirror plain rocks, so none fire today. They matter in M4, when members start mirroring the
  authority's NPCs and oddities: fracture shards, NPC lifepods on death, and four scenes whose `_ready` spawns
  children (HugeRock crystals + pirate, DestroyedHabitat bodies, the spelunker's PhageTheta station, the Pistacja
  station's debris). Also the ring-storm damage rays.
- **12 leave alone**: own player ship, shop/garage UI instances, the title screen, the background parallax rocks,
  cosmetic FX, one dead script, and `Game.sendHelp` (the player's own game-over rescue cutscene, stays local).
- **3 M3-relevant findings** in the player-owned audit (below, *Findings for M3*): puppets spawn real drone ships, puppet
  exhaust plumes are physical bodies that damage rocks, and mineral chunk contents are rolled with `randf()` in `_ready`.

## The two M4 rules this suggests

1. **Mirror bodies are built inert.** Anything a member instantiates to mirror an authority body (NPC ship, oddity,
   station, wreck) must skip its spawning `_ready` side effects, never fracture or drop lifepods, and never write the
   member's save. One flag on the mirrored instance (set before `add_child`) checked at the 8 gate sites, plus the
   puppet ship path (`ClaimOwner`, see below). The authority replicates whatever those side effects produce.
2. **Story state stays with the authority's save.** Event choice reads the authority's money, story flags, POIs and
   difficulty, and consumes the authority's ephemeral POIs. A member's own POIs (from its dialogs, claim beacons,
   quests) do not spawn while it is a member. Accept for M4, or later let members forward "event near me" requests
   to the authority.

## Story and NPC spawn sites

Gate key: **covered** = already suppressed on members by the spawner funnel; **authority-only** = must not run on a
member's mirror, the authority replicates the result; **leave alone** = local by design or not a world body.

| # | file:line | spawns | trigger | relative to player ship | gate |
| --- | --- | --- | --- | --- | --- |
| 1 | AsteroidSpawner.gd:479 → 525/539 | any oddity (single or array) | `spawnProperThings` (only `if spawnThings`) | focus ship + 24,000-38,000 px | covered (the funnel itself) |
| 2 | CurrentGame.gd:908 | the player ship | `setupPlayerShip` / `recreatePlayerShip` | is the player | leave alone |
| 3 | CurrentGame.gd:2054 | dealer ship instance | shop UI cache | not in world | leave alone |
| 4 | CurrentGame.gd:2068, 2071 | dealer ship instance | `createShipInstanceWithCache` | not in world | leave alone |
| 5 | CurrentGame.gd:2221, 2230 | garage ship instances | `getOwnedShips` | not in world | leave alone |
| 6 | Game.gd:165 (via 138, 168) | player ship into the field | `_ready`, `teleport` signal | is the player | leave alone |
| 7 | Game.gd:197, 204 | MADCERF rescue helper (`spawnByBlueprint`) | `sendHelp`, from the "helpless" animation (Game.tscn:608) after 5 s helpless | player + 1,000 px | leave alone: the player's own game-over cutscene; don't replicate |
| 8 | TheRing.gd:106 | TRTL / PROSPECTOR digger | `getOddityAt` | oddity point | covered |
| 9 | TheRing.gd:134 `requestOdditySpawn` | queues a body in `spawnNow` | timers in FlightForRescue, Vilcy | next oddity point | covered; **clear `spawnNow` on demotion** (see notes) |
| 10 | TheRing.gd:245 | POI event `makeAt` | `getOddityAt` | oddity point | covered |
| 11 | TheRing.gd:303 | random playlist event `makeAt` | `getOddityAt` | oddity point | covered |
| 12 | asteroids/asteroid.gd:215 | fracture shards (`spawnAsteroidByClass`) | damage past `splitEnergyThreshold` | at the rock | **authority-only** (RockSync's ext already keeps members from fracturing; keep it so) |
| 13 | asteroids/asteroid.gd:256, 280 | dust / jet particles | damage FX | at the rock | leave alone (cosmetic) |
| 14 | comms/ConversationPlayer.gd:684, 686 | POI that later spawns via #10 | dialog `execute()` | dialog position | covered (spawn); the POI lands in the talker's save |
| 15 | ships/ship-ctrl.gd:910-924 | lifepod (`LifepodPirate` for pirates) | `vanish()` on ship death | at the dead ship | **authority-only** for NPCs (replicate the pod); owner-only for a player ship (identity hand-off) |
| 16 | story/AgendaSpecificDerelict.gd:48 (+76 dialog) | derelict with agenda conversation | `makeAt` | oddity point; targets `getPlayerShip()` (:68) | covered; uses the authority's crew agenda |
| 17 | story/AimingAsteroid.gd:42 | class-1x rocks aimed at the player | `makeAt` | aimed at the authority's ship (:45-49) | covered; only ever aims at the authority |
| 18 | story/AimingAsteroidShower.gd:40 | 20 class-5x rocks aimed at the player | `makeAt` | aimed at the authority's ship | covered; same |
| 19 | story/ClaimBeacon-1.gd:38, 40 | dummy or player claim beacon | `makeAt` | transponder from `getPlayerShip()` (:29-34) | covered; builds the authority's beacon |
| 20 | story/ClaimBeaconForeign.gd:40, 51 | miner ship + foreign beacon | `makeAt` | oddity point | covered |
| 21 | story/DeadBody.gd:56, 64 | talking beacon + 2-10 bodies | `makeAt` | oddity point | covered |
| 22 | story/FlightForRescue.gd:58 | MADCERF helper | `makeAt` | oddity point | covered |
| 23 | story/FlightForRescue.gd:32, 51 | TRTL wreck with dialog | 180 s timer from `makeAt` → `requestOdditySpawn` | next oddity point | covered (via `spawnNow`) |
| 24 | story/habitat/DestoryedHabitat.gd:48-53 | up to 20 dead bodies (`parent.add_child`) | habitat `_ready` if `getStory(story)==0` | around the habitat | **authority-only** on mirrors |
| 25 | story/HugeRock.gd:75-79 | 5-25 uranium crystals (`field.add_child`) | rock `_ready` (Moonlet, BigMoonlet, HugeHollowRock) | `$SpawnLocation` | **authority-only** on mirrors; count reads the save |
| 26 | story/HugeRock.gd:80-85 (+117) | g4a pirate TRTL | rock `_ready`, `randf() < pirateChance`, difficulty > 0 | `$PirateTrapSpot` | **authority-only** on mirrors; writes `setStory` at spawn |
| 27 | story/HumongousHollowRock.gd:32 | HugeHollowRock | `makeAt` | oddity point | covered (its `_ready` children: #25, #26) |
| 28 | story/HybridHunter.gd:22 | HYBRID hunter ship | `makeAt` | oddity point | covered; `canBeAt` reads the authority's money |
| 29 | story/InRingRefuellingEvent.gd:16 | rock | `makeAt` | — | leave alone (looks unreferenced; not confirmed) |
| 30 | story/InstanceWithChance.gd:46, 48 | storm/xaser beacons, habitats, SpaceBar, PhageTransit, stations, Thrusteroid, moonlets, loot (with embedded NPCs) | `makeAt` | oddity point | covered |
| 31 | story/InterCrewBanter.gd:23 | tightbeam beacon | `makeAt` | oddity point | covered |
| 32 | story/LifepodIsFloating.gd:18 | lifepod (cargo filled on `tree_entered`) | `makeAt` | oddity point | covered |
| 33 | story/LocustSwarm.gd:26 | 10 locusts | `makeAt` | oddity point | covered |
| 34 | story/Minefield.gd:36 | 10-20 drone mines | `makeAt` | oddity point | covered |
| 35 | story/MinerMining.gd:40 | miner ship | `makeAt` | oddity point | covered |
| 36 | story/PirateCombat.gd:89, 124, 131 | pirate TRTL, civilian TRTL, 0-20 mineral loot | `makeAt` | oddity point | covered |
| 37 | story/PirateTrap.gd:43, 49, 53 | lifepod bait + pirate playing dead | `makeAt` | oddity point | covered |
| 38 | story/pirates/BigExplosion.gd:52-53 | Pistacja explosion FX | all station reactors fried | at the station | leave alone (cosmetic); its `setStory("g4a.destroyed")` (:57) is authority-only |
| 39 | story/pirates/BigExplosion.gd:75-82 | up to 128 class-4x/5x debris rocks | same, after vanish | at the station | **authority-only** (physics bodies) |
| 40 | story/RescueOperation.gd:68, 91, 119, 128, 134 | wreck, helper, 33-rock cluster, storm beacon, abductor | `makeAt` | oddity point | covered |
| 41 | story/RingRace.gd:27, 33 | racers + race drones | `makeAt` | oddity point | covered |
| 42 | story/RingStormManager.gd:95-98 | no body: random EMP/energy damage rays | StormBeacon child `_physics_process` | around the beacon | **authority-only** on mirrors (else each machine damages its own copies with its own `randf`) |
| 43 | story/RingStormDischarge.gd:17 | no body: light-lag visual | `discharge()` | — | leave alone |
| 44 | story/Singularity.gd:40, 48 | singularity core + 2-10 Fe minerals | `makeAt` | oddity point | covered |
| 45 | story/TeslaIsFloating.gd:24 | Tesla easter egg | `makeAt` | oddity point | covered; `caught` writes `setStory` |
| 46 | story/TimedEvent.gd:39 | dated rock (Halloween) | `makeAt` | oddity point | covered |
| 47 | story/Vilcy.gd:77, 121, 150, 217, 261, 290, 326 | pirates, g4a, abductor, lone wolf, Vilcy patrols | `makeAt` (:232-341) | oddity point | covered |
| 48 | story/Vilcy.gd:183, 190 | Pistacja pirate station | 600 s timer per pirate → `requestOdditySpawn` | next oddity point | covered (via `spawnNow`) |
| 49 | story/Vilcy.gd:351, 353 | later pirates / lone-wolf support | 60 s timer → `requestOdditySpawn` | next oddity point | covered (via `spawnNow`) |
| 50 | tools/DetachAsSiblingPreservingPins.gd:45-46 | reparents embedded bodies into the field (PhageTheta station from BiggerMoonletSpelunker) | spelunker rock `_ready` | relative to the rock | **authority-only** on mirrors |
| 51 | TitleScreenAsteroidMap.gd:30 | civilian ship | title screen | — | leave alone |
| 52 | LoadsOfAsteroits.gd:56 | parallax background rocks | visual streaming | — | leave alone (not physics bodies) |

Spawn nothing (checked): `oddities/`, `easters/`, `Factions.gd`, `BiggerMoonlet.gd`, `Locust.gd`, `UraniumCrystal.gd`,
`XaserBurn.gd`, `XaserScan.gd`, `SingularityCore.gd`, `body.gd`, `EventTriggerCoordinator.gd`. Comms spawns only through POIs.

### Notes

- **`spawnNow` survives demotion.** Timers armed by `makeAt` (FlightForRescue 180 s, Vilcy 60 s / 600 s) keep pushing into
  that machine's `TheRing.spawnNow` after it stops being authority, and the queue drains the next time its spawner runs
  (when it is solo or authority again), at a spot near *its* ship. Clear `spawnNow` (and drop `unspawnedOddities`) when a
  machine joins a cell as a member, or accept stale late spawns.
- **Event choice is the authority's.** `canBeAt` / `makeAt` read the authority's money (HybridHunter:12, Minefield:20,
  PirateCombat:77, PirateTrap:32, RescueOperation:35, Vilcy:53), story flags, POIs, crew agenda, and its own
  `Settings.getDifficulty()`. Aimed events (#17, #18) and derelicts (#16) target the authority's ship only.
- **Mirrored NPCs need their transponder in the config.** `Shipyard.createShipByConfig` calls
  `CurrentGame.getTransponder` (Shipyard.gd:2047) for any NPC without one, which writes `state.transponders` in the
  *member's* save. Mirrors must be built with the authority's transponder set.

## Player-owned things to replicate in M4

Each player's machine owns these; today a puppet only reproduces thrusters and weapon fire from the intent stream.

| Thing | Where | What it does to the world | Proposal |
| --- | --- | --- | --- |
| Mass driver / minirail / railgun bullets | weapons/massdriver.gd:244-255 (`ship.get_parent().add_child`) | RigidBody2D bullets in the field; damage comes from contact physics (asteroid.gd:331-356, ship-ctrl.gd:2037-2074). Mass-driver bullets have `maxLifetime = 0` and can linger; collectible (`specialPrice` 100) | shooter sends a spawn event (pos, vel, lingeringImpulse, shooter); the authority creates and owns the bullet |
| Laser / EMP / synchrotron | laser.gd:257-275, emp.gd:239-249, synchrotron.gd:113-139 | raycast damage (`applyEnergyDamage`, `applyKineticDamage`, `applyEmpDamage`) and `applyHostility` | owner raycasts, sends a damage event (target net id, kind, amount, point) to the body's owner; beam drawn locally from `fired` |
| Synchrotron storm | synchrotron.gd:149-156 | adds a storm discharge node to the field | replicate as an event; damage on the authority |
| Turrets (PDT / ACT) | ships/modules/PDT.gd:241-300 | choose their own target and pivot, then fire the wrapped weapon | stream pivot + fire state, or send turret shots as owner events (not in `fired` today) |
| Thruster exhaust plumes | sfx/thruster.gd:578-616, 658-681 | short-lived **physical** RigidBody2D plumes (mass 0.1, 0.25 s) that do real kinetic damage to rocks; count depends on the `plumes` graphics setting | authority spawns them for every ship in the cell from the replicated schedule; elsewhere cosmetic with collision off |
| Iron-thrower blobs | weapons/iron-thrower.tscn via thruster.gd:589/610/681 | physical blobs (projectile.gd, 1 s); consumes Fe/ammo | as exhaust; consumption stays with the owner |
| Particle drones (tug / haul / repair) | weapons/drone-plant.gd:419-539 | swarm is cosmetic particles; effect is `apply_impulse` on the target rock (505, 517) or `changeSystemDamage` on a ship (532) | owner sends "drone impulse (net id, vector)" / repair events to the body's owner |
| Physical drones (cargo scoop, claim beacon, storage pod, hunk) | ships/modules/ClaimOwner.gd:50-96 (`field.add_child` 56/75) | full AI ships (or a plain RigidBody2D) added to the field from the dock | owner streams them like ships; **puppets must skip ClaimOwner** (see below) |
| Docking arm / claw | ships/modules/DockingArm.gd: soft lock 604/646 + impulse servo 751; hard lock `PinJoint2D` 664-667; forced position 521-534; release 472/511/630/654/671/678 | body never reparented; it stays in the field, gets `docked = ship` and joins `temporaryCargo` (ship-ctrl.gd:2288); energy, cargo and remass transfers (554, 803, 815, 832) | ownership to the holder on lock, back to the authority on release (a pin joint cannot hold a remote body) |
| Grinder / beak / excavator claws | Grinder.gd:109-141, Beak.gd:209-231 | ship parts on spring joints; move rocks by contact | claw open/close must be in the replicated `fired` dict so the puppet's claws push rocks on the authority |
| Cargo bay entry | ship-ctrl.gd:5189-5195 → 5242-5291 (`inCargoHold += 1` 5279, `cargoLut` 5284); exit 5197-5240 | body stays a free RigidBody2D inside the hull; no reparent; no dump function exists | ownership to the holder after the 0.2 s grace; MPU consumption (MineralProcessingUnit.gd:168-232, `Tool.remove` 229) is a despawn event |
| Lifepod / EVA | ship-ctrl.gd:894-926 (lifepod), 205-217 (EVA sprite) | player lifepod becomes the player's ship; EVA is cosmetic | lifepod: identity hand-off from ship to pod; EVA: cosmetic or skip |
| Reactor / fusion reactor explosion | Reactor.gd:205-267 (128 blast bodies, 266), FusionReactor.gd:158-220 | blast RigidBody2Ds (mass 2, 2 s) shove and damage rocks | "ship exploded" event; authority simulates the blasts |

Damage entry points on rocks: `asteroid.gd` `applyEnergyDamage` 289, `applyKineticDamage` 298, contact energy in
`_integrate_forces` 331-356, fracture 196-231 (shards at 215). Callers: laser, synchrotron, emp, thruster heat beam
(thruster.gd:637), projectile (projectile.gd:72), MPU ice melting, ring storms, Locust.gd:75, ConversationPlayer.gd:781.

## Findings for M3 (now)

1. **Puppets spawn real drone ships.** `ClaimOwner._ready` (ships/modules/ClaimOwner.gd:32-96) does not check
   `dummy` / `netControlled`, so a puppet built from a ship config with a drone dock adds that player's drones to
   the remote field as AI ships. Fix: skip ClaimOwner spawning on `netControlled` ships (CoopNet puppet path / ship-ctrl ext).
2. **Puppet exhaust is physical.** A puppet firing thrusters spawns exhaust plumes that do kinetic damage to the local
   rocks (thruster.gd:658-681, asteroid.gd:343-353). On the authority that is roughly right (the real ship would
   have done it); on a member it is damage to tracked rocks, which must stay non-fracturing (RockSync rule).
3. **Mineral contents are random per machine.** `asteroids/mineral.gd:75-80` rolls `mineralContent`, `composition` and
   `mass` with `randf()` in `_ready`, so a mirrored mineral chunk is worth a different amount on each machine unless
   the recipe carries those fields.

## Save and economy touches (stay per player)

- Authority's save: ephemeral POIs consumed by `CurrentGame.getEventNear(pos, true)` (CurrentGame.gd:1916-1924, via
  TheRing.gd:239); NPC transponders (`getTransponder`, Shipyard.gd:2047); ship names (`setShipName`, ship-ctrl.gd:619);
  story flags at spawn (HugeRock:85, BigExplosion:57); `Discovery.gd` writes undiscovered POIs in `_ready` (:30), XP on
  discovery (:73, CurrentGame.gd:1841) and an achievement (:77).
- Owner's save: cargo (`cargoLut`, `estimatedCargoValue`, `processedCargo`, `shipConfig.currentCargo*`, ship-ctrl.gd:1266-1345),
  supplies (`droneParts`, `massDriverAmmo`, `reactiveMass`, saved at ship-ctrl.gd:295-300), `vanish` (garage, transponder,
  ship-ctrl.gd:896-902), `applyHostility` / faction disposition from every weapon hit, `logEvent`, achievements.
- Dialog (comms/ConversationPlayer.gd): POIs (679-690), `addShip` (738), `setStory` (809, 818), money and insurance (822, 828),
  crew (834-873). Runs on whichever machine owns the NPC being talked to; the economy effects belong to the talking player.
- Not traced: whether fracture shards (`spawned = false`) change the persisted density map (`state.density`).

## NPCs a member already has when it joins a cell (M4)

The joining member frees its own NPCs quietly (the field's `kill()`, the stock despawn path: no `vanish()`, so no
`forgetTransponser` and no lifepod) except those bound to its save or story, which it keeps and streams to the cell as
member-owned NPCs (Npc.gd `_onCellJoined`). What marks an NPC as save- or story-bound, checked in the 1.90.12 source:

| Candidate | Keyed per NPC ship? | Use |
| --- | --- | --- |
| `state.transponders.lookup/hashes` | per transponder, but **every** new NPC is registered (`getTransponder`, CurrentGame.gd :1040-1080) | can't distinguish; not used |
| `state.shipNames` | per transponder, but written for every NPC whose name is ever shown (`getShipName`, :1030-1036) | not used |
| `state.agendaStory` | per **crew member** `fullName` (crew agenda quest flags stored/restored, :230-246) | not per ship; not used |
| `state.encounteredShips` | per ship id/transponder, written when an NPC talks to the player (`recordEncounter`, :553-567, ship-ctrl.gd :3915) | keep if present |
| `state.dispositions` | per transponder (`getDispositionReferenceOfTransponder`, :535-539; creates an empty entry on read) | keep if non-empty; read with `.get`, never through the accessor |
| `essential` | ship-ctrl export, also true while `talkingWith != null` (ship-ctrl.gd :77-81) | keep |
| faction `"player"`, docked / held by my ship | my drones and fleet, temporary cargo | keep |

