# M4 design: rock ownership (draft)

Status: design draft for review, no code yet. Builds on M3 (cells, `RockSync`, net ids). Scope: who may move,
damage, fracture, hold, process and remove a rock; how that right moves between machines; how ore is accounted so a
rock is never in two holds or in none. Out of scope: NPC and story spawn sites (tim-06's audit,
`docs/M4-SPAWN-AUDIT.md`), and the moving-rock lag fix (M3.md "Known issues", independent of this).

Line numbers below are from the decompiled game build 1.90.12.

## Principles

1. **One owner per net id at any time**, decided by the cell authority. The owner's simulation is the truth for
   that body. Everybody else holds a tracked copy under the M3 rules: corrected toward the owner's stream, no local
   fracture, no local despawn, damage forwarded.
2. **The cell authority is the default owner.** Ownership moves to a player only by **touch**: the claw locks on, a
   haul drone pushes it, it enters the cargo hold, or it enters the processing unit (MPU). It returns to the authority
   on release (claw unlock, leaving the hold).
3. **The authority arbitrates.** Claims are granted in arrival order. Every ownership change bumps the body's
   **epoch**. Every ownership-sensitive message carries the epoch it was based on, and a message with a stale epoch
   is dropped.
4. **Only the owner does irreversible things**: fracture, process in the MPU, carry out of the ring, despawn. The
   owner announces each one and the authority confirms it, keeping a tombstone so it happens once.
5. **When in doubt, duplicate rather than lose.** A rock that might be both in a hold and in space is better than
   ore that disappears. Every ambiguous case below resolves that way, and logs it.
6. **An owner change never frees or rebuilds the node.** The tracked copy becomes the simulated body in place (the
   `dvnet_tracked` meta flips). The many references the game keeps to a body (below) therefore survive.

## State

On every machine, per net id (extends the M3 registry):

| Field | Meaning |
| --- | --- |
| `owner` | peer id of the current owner (the authority by default) |
| `epoch` | int, +1 on every owner change, set by the authority |
| `pending` | local only: this machine has an outstanding claim (`o.req` sent, no answer yet) |

On the authority only: `tomb` is the set of net ids that were processed, carried away or fractured. Each entry is
kept for 30 s, so a late claim, release or stream for that body is refused rather than resurrecting it.

## Packets

All packets go over CoopNet like M3 (`net.on`). All positions are origin-relative and carry the M3 `g` (origin
generation) tag.

| Type | Who → who | Reliable | Body | Meaning |
| --- | --- | --- | --- | --- |
| `o.req` | claimant → authority | yes | `id`, `epoch` seen, `why` (claw / drone / hold / mpu), claimant's view `p r v w` | "I touched it, give it to me" |
| `o.ok` | authority → claimant | yes | `id`, new `epoch`, authoritative `p r v w` at grant | claim granted |
| `o.no` | authority → claimant | yes | `id`, current `owner`, `epoch`, reason (held / fracturing / tomb / stale) | claim denied; the claimant lets go |
| `o.chg` | authority → all members | yes | `id`, `owner`, `epoch` | everybody re-points (stops or starts correcting toward the new owner) |
| `o.u` | owner → all members incl. authority | no | list of `[id, epoch, p, r, v, w]` (+ `mass` while the MPU shrinks it), 20 Hz | state of a player-owned body, same shape as `r.u` |
| `o.rel` | owner → authority | yes | `id`, `epoch`, final `p r v w`, damage state (`totalEnergy`) | handing it back |
| `o.eat` | owner → authority | yes | `id`, `epoch`, composition taken | gone: processed by the owner's MPU, or carried out of the ring |
| `o.new` | owner → authority | yes | recipes minted by the owner (`"<owner>:<n>"` ids) | bodies a player created: fracture shards of a rock it owns |
| `d.ev` | shooter → owner | yes | list of `[id, epoch, kind, amount, point (rock-local), delta]`, batched per physics tick | weapon damage to a body the shooter doesn't own |
| `o.list` | member → new authority | yes | ids this member owns, with `epoch` and state | rebuild the ownership table after a handoff |
| `b.new` | shooter → all members | yes | bullet / blob id, `p`, `v`, `lingeringImpulse`, shooter | every machine runs a ballistic copy; its damage counts only on the hit rock's owner |
| `s.die` | ship owner → all members | yes | ship (peer id), final `p r v w` | the owner's ship exploded; others play it and remove the puppet |

The authority keeps streaming `r.u` for bodies it owns. A player-owned body is streamed by its owner with `o.u` to
every member, including the authority. The authority stops sending `r.u` for that body while a player owns it. It
keeps interest management (`r.s` / `r.d` per member), so members far from the holder still get it spawned and
despawned.

## Claim flow

1. **Touch.** A seam (see "Game-side seams") reports "my claw / drone / hold / MPU touched net id X". If X is
   already mine, there is nothing to do. If X is tracked, send `o.req` and set `pending`.
2. **Optimistic hold.** While `pending`, the claimant's claw may lock onto its own tracked copy, so the grab feels
   latency-free. Correction of X is **suspended** for up to `CLAIM_TIMEOUT` (500 ms). Damage and fracture stay
   suppressed. The hold and the MPU do **not** count or process a pending body: counting cargo is visible, and
   processing is irreversible, so both wait for `o.ok`.
3. **Arbitration on the authority**, in arrival order:
   - X in `tomb` → `o.no(tomb)`.
   - X fracturing (`fracturing == true`) → `o.no(fracturing)`. This covers the SPEC risk of a claw grabbing a rock
     mid-fracture.
   - X owned by a player other than the claimant → `o.no(held)`.
   - Request `epoch` older than the current one: still grant if X is authority-owned. The claimant just saw an older
     stream, and the grant carries the new epoch.
   - Otherwise grant: `owner = claimant`, `epoch += 1`, reply `o.ok` with the authority's current state, broadcast
     `o.chg`.
4. **Grant.** If X is more than `SNAP_DISTANCE` from the granted state, the claimant snaps it there. Normally it is
   within a few px; see the M3 lag numbers. The claimant then clears `dvnet_tracked` and starts streaming `o.u`. From
   here X is simulated on the claimant with the stock code: claw impulses and joints, hold counting, MPU, damage,
   fracture.
5. **Deny or timeout.** The claimant releases through the stock path (DockingArm dequeue, `removeTemporaryCargo`) and
   resumes correction toward the owner. A timeout (no answer within `CLAIM_TIMEOUT`) counts as a deny. A late `o.ok`
   after a timeout gets an immediate `o.rel`, so the body is never orphaned.

The authority player claims through the same function without a packet: it decides locally, bumps the epoch and
broadcasts `o.chg`. A member trying to take a rock the authority player holds gets `o.no(held)`, like anyone else.

## Release flow

A release happens when the claw unlocks, the drone drops the rock, or it leaves the hold. The owner sends `o.rel`
with the final state and its damage state, stops streaming, re-marks X `dvnet_tracked` and starts correcting toward
the authority. The authority then:

- sets `owner = authority` and `epoch += 1`;
- restores the body to the released state (snap past `SNAP_DISTANCE`, else blend);
- copies `totalEnergy`, so damage done while held is not lost;
- broadcasts `o.chg` and resumes `r.u`.

If a player-owned body drifts out of every member's interest, its owner releases it first. The authority never
despawns a body it doesn't own (see "Despawn" in the seams).

## Damage

Rocks take damage through `applyEnergyDamage`, `applyKineticDamage`, `addIntegratedDamage` and `applyEmpDamage`
(asteroid.gd :289 / :298 / :310 / :358). In mineral.gd these only play effects (:103-108), so ore rocks can't be
destroyed by damage at all. The rule that avoids double counting is that **every hit is evaluated on exactly one
machine**.

- **The shooter evaluates beam hits.** These are instant weapons: laser.gd :266-269 (raycast), emp.gd :244-247,
  synchrotron.gd :128-133, and the thruster heat beam in sfx/thruster.gd :622-640. On the shooter's machine:
  - if the shooter owns the rock, the damage is applied;
  - otherwise only the effects play locally, and the hit is queued as `[id, epoch, kind, amount, point, delta]`.
    The queue is flushed once per physics tick as one `d.ev` per owner.

  The owner applies each event through the same stock function, so hardness, reflectivity and the `delta` scaling
  stay the game's.
- **Bullets and iron-thrower blobs are replicated bodies, not forwarded hits.** A bullet's kinetic damage and its
  push both come from contact (asteroid.gd `_integrate_forces`). projectile.gd :71 is only the thermal part, so
  forwarding :71 would lose the kinetic share and the push.
  - The shooter broadcasts each bullet's spawn: position, velocity, `lingeringImpulse`, shooter. Every machine runs a
    ballistic copy.
  - All of a bullet's damage on a rock (contact kinetic and :71 thermal) counts only on that rock's owner's machine.
    Other machines play effects only.
  - Iron-thrower blobs (sfx/thruster.gd :589 / :610 / :681) work the same way.
- **Damage to a ship carries hostility.** When the target is a ship (a puppet on the shooter's machine), the `d.ev`
  carries the stock hostility flag. The owner applies it, so faction reactions happen once, on the machine that owns
  the target. Call sites: laser.gd :271, projectile.gd :83, synchrotron.gd :135, thruster.gd :639.
- **A puppet's weapons do no damage locally.** Puppets replay the shooter's `fired` dict (M1), so the owner's copy
  of the shooter's laser would hit the same rock a second time. Each weapon caller above gets a guard: if the
  weapon's ship is `netControlled`, play effects only. The same guard covers the synchrotron's storm-node spawn
  (synchrotron.gd :149-156) and the thruster heat beam (:622-640).
- **Contact damage stays local to the owner.** The rock's own `_integrate_forces` (asteroid.gd :331) calls
  `addIntegratedDamage` for ship hulls, claws, grinder blades and bullets touching it. It also covers the physical
  thruster plumes, which sfx/thruster.gd :658-681 spawns as short-lived RigidBody2Ds (tim-06's audit). The owner
  computes this from contacts with the puppets in its world. Non-owners already suppress it (M3 `ext/asteroid.gd`).
  It is never forwarded, so it is never counted twice. The cost: a graze that happens on the toucher's screen but
  not against the owner's puppet does no damage.
- An event with a stale epoch is re-sent once to the new owner (learned from `o.chg`), then dropped.
- Fracture stays owner-only. If the owner is a player (a rock in the claw under that player's laser), the player
  fractures it with the stock code and the shards are born there; see "Shards".
- MPU processing of an H2O asteroid is `applyEnergyDamage` (MineralProcessingUnit.gd :217). It acts on a rock the
  processing player owns, because the MPU touch claimed it, so it is applied locally, not forwarded.

## Puppet systems

A puppet is a full stock ship running on another player's machine. Every system that acts on the world has to be
inert or effects-only there; otherwise the puppet would grab, push, repair or aim on its own, and the same action
would happen twice. (The M3 ship-ctrl extension already makes puppets immune to kinetic, energy and EMP damage, holds
`initialShockSupress` at 1.0, and blocks `vanish()`.)

| System | Where | On a puppet |
| --- | --- | --- |
| Drone plant (haul / tug impulses on rocks, repair drones' `changeSystemDamage`) | weapons/drone-plant.gd :494-539 | No drone hits, no impulses, no repairs. The owner's drones are replicated bodies. |
| Claw arm: queue, lock, pin joint | ships/modules/DockingArm.gd :645-667, :882 | No queueing, no lock, no joint. The arm's open/close state travels in `fired`, so its geometry matches the owner's. |
| PDT / ACT turrets | ships/modules/PDT.gd :241-300 (self-aim) | No self-aim. The owner streams pivot angle and fire state instead. |
| Cargo hold, MPU | see "Ore accounting" | Never counts or processes. |
| Weapons | see "Damage" | Effects only. |

**Target filter.** DockingArm.isValidTarget (:850-870) must exclude puppets and other players' drone ships, so a
claw never locks onto another player.

## Ship death

Puppets can't `vanish()` locally any more, so a ship's death is an event from its owner: the owner sends "ship
exploded" when its stock `vanish()` runs, and every other machine plays the explosion and removes the puppet. The
reactor blast spawns about 128 physical bodies (Reactor.gd :256-267). They are simulated on the machine that owns the
rocks they hit, the cell authority by default, so their push on rocks happens once.

## Mirrors beyond rocks

Bodies other than rocks and minerals (HugeRock and moonlets, DestroyedHabitat, PhageTheta, NPC ships) get the same
mirror treatment through one inert flag, set before `add_child` and checked at the 8 sites in tim-06's audit. Mirrors
carry the authority's transponder (Shipyard.gd :2047). See `docs/M4-SPAWN-AUDIT.md`; this document covers rocks and
minerals only.

## Shards

Stock fracture spawns shards through `field.spawnAsteroidByClass` on whichever machine fractures the rock
(asteroid.gd :215). When the owner is the authority this is plain M3: the shards are spawns, streamed with `r.s`.
When the owner is a player:

1. The player's field mints `"<player>:<n>"` ids for the shards as usual (M3 `_onChildEntered`).
2. The player sends `o.new` with their recipes to the authority. The parent's id goes into the authority's `tomb`
   (reason `fractured`).
3. The authority builds the shards (simulated, authority-owned, epoch 0) and streams them with `r.s` to members in
   range. The player turns its local shards into tracked copies as soon as `o.new` is sent, so the authority's
   simulation takes over within one round trip. A shard inside the player's claw at that moment is simply re-claimed
   through the normal claim flow.

## Ore accounting

The survey changed this section's premise: **entering the cargo hold is not consumption.** A rock in the hold stays a
live RigidBody2D child of the field. `processEnteringCargoBay` (ship-ctrl.gd :5242) only appends it to `cargo`,
increments its `inCargoHold` refcount and adds to `cargoMass` / `estimatedCargoValue`. Leaving the hold undoes all
of that (:5206). A rock is freed and turned into ship-state numbers in exactly two places:

1. **MPU processing** (MineralProcessingUnit.gd :168-232). A mineral shrinks tick by tick (`mass`, `fillerContent`)
   and feeds `reactiveMass`. Then `ship.addProcessedCargo(mineral, kg)` (:199) runs and the rock is `Tool.remove`d
   (:232). H2O asteroids are damaged into remass and fracture.
2. **Leaving the ring with cargo.** `claimCargo` (ship-ctrl.gd :1266, called from `escapeTheRing` :1310,
   `moveCargoToRemote` :312 and Game.gd :227) writes `shipConfig.currentCargo` / `currentCargoComposition` via
   `appendToCargo` and `Tool.remove`s every body in `cargo`.

Rules:

- **Being in my hold means I own it.** Entering my hold is a touch (`why = hold`). While a rock is in my hold I own
  it, so my `inCargoHold` count, `cargoMass` and value are computed on the copy that is the truth. Leaving the hold
  releases it. A tracked rock that drifts in while my claim is pending is not counted until `o.ok`.
- **Only the owner consumes.** On a non-owner, the MPU treats a tracked rock as a claim trigger (`why = mpu`) and
  does not process it until the claim is granted.
  - When either path above frees the rock, the owner sends `o.eat(id, epoch, composition)`.
  - The authority tombstones the id, broadcasts `r.d` and logs the composition.
  - While the MPU shrinks a mineral, the owner adds `mass` to that body's `o.u` entries so the others see it lose
    mass (cosmetic).
- **Puppets never run cargo or MPU logic.** A puppet ship (`netControlled`) has a cargo area and an MPU too. On a
  member's machine those would count other players' rocks into a phantom hold. The ship-ctrl extension skips
  `processCargoBodyEntry` for puppets, and the MPU skips its `processing` for them.
- **Two ships, one rock.** The stock game lets several holds count the same rock (it is a refcount). Ownership
  forbids that: the second ship's hold claim gets `o.no(held)`, and its hold does not count the rock.
- **Drone ships with cargo areas** (scoop, storage pod, claim beacon). Hold entry is a touch for the drone's owner,
  the same as the player's own hold, and `claimCargo` (ship-ctrl.gd :312) on the drone sends `o.eat` the same way.
- **Leaving the ring** (dive exit, helpless rescue, remote cargo move). Before `claimCargo` runs, the owner sends
  `o.eat` for every body in `cargo`, then leaves the cell. The authority tombstones them before the leave arrives,
  since both go over the same reliable channel.
- **Conservation check** (dev log, every 30 s on the authority). Composition of live rocks + all `o.eat`
  compositions + composition lost to stock despawns should change only by spawns. Mismatches are logged with ids.
  This is the ore audit for the M4 gate.
- **Disconnect while holding.** The authority re-owns every body the departed peer owned, at its last `o.u` state
  (SPEC: "re-owned by the authority if it holds them"). If the peer had already freed a rock and its `o.eat` never
  arrived, the rock reappears in space while the peer's save has the ore. That is a duplicate, and it is logged;
  it is never a loss.
- **Authority handoff while a member holds.** The new authority has no ownership table. On promotion it asks every
  member for `o.list` (piggybacked on `c.join`), sets `owner` / `epoch` from the replies, and only then resumes
  arbitration. Claims that arrive before that get `o.no(stale)`, and the claimant's timeout logic retries them.

## Claim races (SPEC risk "Ownership races")

| Race | Resolution |
| --- | --- |
| Two players grab the same rock in the same tick | Both send `o.req`. The authority grants the first to arrive and sends `o.no(held)` to the second, which releases its optimistic hold. Exactly one owner after one round trip (the SPEC test). |
| Claw grabs a rock mid-fracture | `o.no(fracturing)`. If a rock starts fracturing while a claim is pending, the authority denies it when it sees the claim, and the deny ends the claimant's optimistic hold. |
| Claim arrives after the rock was processed, carried away or fractured elsewhere | It is in `tomb`, so the reply is `o.no(tomb)`. The claimant frees its tracked copy when the `r.d` arrives. |
| Release and re-grab inside one RTT | The re-grab carries the pre-release epoch. The authority sees the release first (same reliable channel, same sender), so the body is authority-owned again and the claim is granted with a fresh epoch. |
| Owner's `o.u` arrives after `o.chg` moved ownership away | Dropped: its epoch is stale. |
| Damage event addressed to an old owner | Re-sent once to the new owner, then dropped. |
| Grant arrives after the claimant timed out | The claimant answers with `o.rel` at once, and the rock goes back to the authority. |
| Authority player and a member grab together | Same arbitration. The authority's own claim counts as first in arrival order if it touched the rock first in its tick. |
| Two holds count one rock (stock refcount) | The second hold's claim gets `o.no(held)` and that hold does not count the rock. |
| Origin shift (`gen`) while held | `o.u` and `o.rel` carry `g`. A packet from another generation is held if reliable, or dropped if it is `o.u`, the same way M3 handles `r.*`. |
| Authority handoff mid-claim | Pending claims time out on the claimant and are retried against the new authority after its `o.list` round. |
| Holder disconnects | The authority re-owns the body at the last `o.u` state (see "Ore accounting"). |

## Game-side seams

| Seam | Where | Hook |
| --- | --- | --- |
| Claw lock | ships/modules/DockingArm.gd :645-662 (`locked = true`, `ship.addTemporaryCargo(target)`); queueing :872-896; target validity :850-859 | Touch `why = claw` at lock. While pending, the arm may hold: impulses (:751 / :780) act on the local copy, with correction suspended. On deny, the stock release path runs. The hard-lock pin joint binds by node path (:666), and the node is never rebuilt on an owner change, so the path stays valid. |
| Haul / tug drones | weapons/drone-plant.gd `scanForTarget` :221, `_on_DroneLaunchManager_droneHit` :494 (`apply_impulse` only; drones never put rocks into the hold themselves) | Touch `why = drone` on the first hit. Until the claim is granted, the drone's impulse lands on a corrected copy and is lost (acceptable for about one RTT). Release when the drone drops its target. |
| Cargo hold | ship-ctrl.gd `_on_CargoHoldArea_body_entered` :5189 → `processCargoBodyEntry` :5109 → `processEnteringCargoBay` :5242; exit `processExitingCargoBay` :5206 | Touch `why = hold` at entry; count only owned bodies; release at exit. Skipped entirely on puppets. |
| MPU | ships/modules/MineralProcessingUnit.gd area enter :248, per tick :168-232, free :232 | Touch `why = mpu`; process only owned bodies; `o.eat` at free. Skipped on puppets. |
| Carry out of the ring | ship-ctrl.gd `claimCargo` :1266 (callers :1310, :312, Game.gd :227) | `o.eat` for every body in `cargo` before the stock loop frees them. |
| Beam damage | laser.gd :266-269, emp.gd :244-247, synchrotron.gd :128-133, sfx/thruster.gd :622-640 (heat beam) | Puppet-fired: effects only (also the synchrotron storm-node spawn, :149-156). Fired locally at a body we don't own: queue a `d.ev`. Ship targets carry the hostility flag (laser.gd :271, projectile.gd :83, synchrotron.gd :135, thruster.gd :639). |
| Bullets and iron-thrower blobs | projectile.gd (contact kinetic + :71 thermal); sfx/thruster.gd :589 / :610 / :681 | The shooter broadcasts the spawn; every machine runs a ballistic copy; damage counts only on the rock owner. |
| Puppet systems | drone-plant.gd :494-539; DockingArm.gd :645-667, :882, isValidTarget :850-870; PDT.gd :241-300 | Inert or effects-only (see "Puppet systems"). |
| Ship death | ship-ctrl `vanish()` :894; Reactor.gd blast bodies :256-267 | The owner sends "ship exploded"; blast bodies are simulated where the rocks are owned. |
| Contact damage | asteroid.gd `_integrate_forces` :331 → `addIntegratedDamage` :310 | Unchanged on the owner; already suppressed on tracked copies (M3). |
| Despawn | AsteroidSpawner.gd `despawnFarAway` :575 (exempts `essential` and `inCargoHold`) | M3 `ext/AsteroidSpawner.gd` additionally never despawns a body owned by someone else. |
| Other references to a body | ship-ctrl `cargoLut`, `identifiedObjects`, `systemTargets` (keyed by `hash(node)`); `cargo[]`, `temporaryCargo[]`, `droneQueue[]`, autopilot and AI targets; DockingArm `target`; drone-plant `target(s)`; PDT `queue`; MPU `processing[]`; HUD MineralMark and AutopilotOverlay; story hooks that connect `inCargoHold` (HugeRock :78, PirateTrap :92, Tutorial :106) | An owner change never frees or rebuilds the node, so all of these survive it. They only see a body go away when M3 frees a tracked copy (`r.d`), which the stock code already handles through `tree_exiting`. |

The survey found no equipment that reparents or `remove_child`s a rock. It also found no direct rock → ammo path:
mass driver ammo is printed by the MPU from `processedCargo`, so it is ship state, not a body.

## Testing (M4 gate, proposed)

- **Scripted race:** two dev instances claim the same id in the same physics tick, 100 times. Each time there is
  exactly one owner after one RTT, with zero bodies that have two owners and zero orphaned (unowned and unstreamed)
  bodies.
- **Mid-fracture grab:** laser a rock to the threshold on the authority while a member's claw closes on it. The
  claim is denied, the shards appear on both machines, and the parent is not duplicated.
- **Ore audit:** two players mine the same patch for 5 minutes, using claw, hold and MPU, with one exit to Enceladus.
  The conservation log shows no unexplained change, every `o.eat` id appears exactly once, and no rock is counted in
  two holds.
- **Holder hard-kill:** the rock in the dead holder's claw reappears in space on the other machines within 2 s, at
  the holder's last state.
- **Handoff while holding:** the authority quits while a member holds a rock. The member keeps it, and the new
  authority's table shows it after `o.list`.
- **Puppet weapons:** player A lasers a rock owned by the authority B while B watches A's puppet. The rock takes the
  damage once, matching a solo run with the same laser time.
- **Bullets:** A fires the mass driver at a rock B owns. The rock takes kinetic and thermal damage once, and its push
  matches on both machines within the M3 drift tolerance.
- **Puppet inertness:** a puppet's claw, drones and turrets never lock, push or fire on their own over a 5-minute
  session (log any attempt).
