"""M4 gate: read the dev3 logs of every instance and print PASS / FAIL per gate, so the final run is mechanical.

Usage: python tools/gate_m4.py [--gates 7,8,9] <log glob> [<log glob> ...]
       e.g. python tools/gate_m4.py ~/dvcoop-data/dV/logs/dv_log_*.txt "$TEMP/dvcoop_inst*/dV/logs/dv_log_*.txt"

Each log file is one instance (identified by its peer id). Every gate is a function in GATES taking the list of
instances and returning (passed: bool, evidence: [str]); add a gate by writing one and registering it.
Gates 7-9 (Ships track, tim-06) read the COOP: NPC / SHIPS / puppet lines; gates 1-6 and 10 (Own track) are tim-58's.
Save files are checked separately by tools/savecheck.sh (before/after hashes), which every gate run should include.
Exit 1 if any selected gate fails.
"""
import sys, re, glob, os


class Instance:
    def __init__(self, path):
        self.path = path
        self.lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        # the transport's peer id: ENet's when the run used ENet (a Steam client also logs its Steam id, which
        # other lines never use), else Steam's
        self.peer = None
        for rx in (r"COOP: ENet connected to server, I am (\d+)", r"Steam ready, I am (\d+)"):
            m = next((m for m in (re.search(rx, l) for l in self.lines) if m), None)
            if m:
                self.peer = m.group(1)
                break

    def grep(self, pattern):
        rx = re.compile(pattern)
        return [m for m in (rx.search(line) for line in self.lines) if m]

    def count(self, pattern):
        return len(self.grep(pattern))

    def total(self, key):
        # sum of a counter from the Npc 5 s summary, e.g. "ships 5 s: {replayed:170, fxOnly:3}"
        return sum(int(m.group(1)) for m in self.grep(r"COOP: NPC ships 5 s: \{[^}]*\b%s:(\d+)" % re.escape(key)))

    def name(self):
        return "%s (%s)" % (self.peer, os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(self.path)))) or self.path)


# ---------------------------------------------------------------- Ships track (gates 7-9)

def gate7(insts):
    """Puppet inertness: puppets replay their owner's systems, never vanish or drop a pod of their own, and their
    weapon hits are effects only (ships: fxOnly; rocks: rockFxOnly once ext/asteroid.gd reports it)."""
    ev = []
    replayed = {i.name(): i.total("replayed") for i in insts}
    ev.append("puppet system-fires replayed: %s" % replayed)
    ok = sum(replayed.values()) > 0
    for i in insts:
        own_death = i.count(r"COOP: NPC s\.die sent") > 0
        pods = i.count(r"Exploded \[.*\] with lifepod")
        if pods and not own_death:
            ok = False
            ev.append("FAIL %s: %d lifepod(s) without its own ship dying" % (i.name(), pods))
        if i.count(r"COOP: blocked vanish\(\) on puppet"):
            ev.append("note %s: %d vanish() calls on puppets blocked" % (i.name(), i.count(r"COOP: blocked vanish\(\) on puppet")))
    ev.append("hits made effects-only: ships %s, rocks %s" % (
        {i.name(): i.total("fxOnly") for i in insts}, {i.name(): i.total("rockFxOnly") for i in insts}))
    if not ok and sum(replayed.values()) == 0:
        ev.append("FAIL: no puppet replayed anything (was --coop-dev-fireall on?)")
    return ok, ev


def gate8(insts):
    """Ship death: the dying owner sends s.die; every other machine with its puppet plays the explosion; the lifepod
    exists once, on the owner; blast particles are physical on exactly one machine (the rocks' simulator)."""
    ev = []
    dead = [i for i in insts if i.count(r"COOP: NPC s\.die sent")]
    if not dead:
        return False, ["FAIL: nobody's ship died (was --coop-dev-explode[-member] on?)"]
    ok = True
    for d in dead:
        ev.append("%s exploded" % d.name())
        seen = [i for i in insts if i is not d and i.count(r"COOP: NPC s\.die from %s: puppet .* exploding" % d.peer)]
        shown = [i for i in seen if i.count(r"COOP: puppet '.*' exploded")]
        ev.append("  puppet explosion played on %s, finished on %s" % ([i.name() for i in seen], [i.name() for i in shown]))
        others = [i for i in insts if i is not d and i.count(r"COOP: NPC s\.die from %s" % d.peer)]
        if not seen or len(shown) < len(seen):
            ok = False
            ev.append("  FAIL: s.die received by %s but not every one exploded the puppet" % [i.name() for i in others])
    pods = {i.name(): i.count(r"Exploded \[.*\] with lifepod") for i in insts}
    ev.append("lifepods: %s" % pods)
    if any(n and i not in dead for i, n in ((i, pods[i.name()]) for i in insts)):
        ok = False
        ev.append("FAIL: a lifepod on a machine whose ship didn't die")
    blasts = {i.name(): ("physical" if i.count(r"blast of .* particles physical") else "ghosted") for i in insts
              if i.count(r"COOP: SHIPS blast of")}
    ev.append("blast particles: %s" % blasts)
    if list(blasts.values()).count("physical") != 1:
        ok = False
        ev.append("FAIL: the blast must be physical on exactly one machine")
    return ok, ev


def gate9(insts):
    """NPC mirror: an authority NPC appears on members as a mirror, a member's hits reach it with hostility, and the
    sub-check: a member joining with a story NPC keeps it (freed the rest) and the others mirror it."""
    ev = []
    ok = True
    mirrors = {i.name(): i.count(r"COOP: NPC mirror \S+: ") for i in insts}
    ev.append("mirrors built: %s" % mirrors)
    if sum(mirrors.values()) == 0:
        ok = False
        ev.append("FAIL: no NPC mirror anywhere")
    best = 0.0
    for i in insts:
        hs = [float(m.group(2)) for m in i.grep(r"COOP: NPC d\.ship from \d+: .* on (\S+); its hostility to player = (-?[\d.]+)")]
        if hs:
            ev.append("%s applied forwarded hits, hostility to player %.3f -> %.3f" % (i.name(), hs[0], hs[-1]))
            best = max(best, hs[-1])
    if best < 0.5:
        ok = False
        ev.append("FAIL: no NPC turned hostile through d.ship (max hostility %.3f)" % best)
    joins = [(i, m) for i in insts for m in i.grep(r"COOP: NPC joined (\d+)'s cell: freed (\d+) NPCs of mine \[(.*)\], kept (\d+) as mine \[(.*)\]")]
    sub = [(i, m) for i, m in joins if int(m.group(4)) > 0]
    if sub:
        for i, m in sub:
            kept_ok = [o.name() for o in insts if o is not i and o.count(r"COOP: NPC mirror %s:n\d+: " % i.peer)]
            ev.append("sub-check: %s freed %s [%s], kept %s [%s]; mirrored by %s" % (
                i.name(), m.group(2), m.group(3), m.group(4), m.group(5), kept_ok))
            if not kept_ok:
                ok = False
                ev.append("FAIL: the kept NPC was not mirrored by anyone")
    else:
        ev.append("sub-check not staged (no member joined with a kept NPC; use --coop-dev-story-npc)")
    for i in insts:
        watch = [m.group(1) for m in i.grep(r"COOP: NPC save watch: (.*)")]
        joined = i.grep(r"COOP: (?:NPC joined|CELL JOINED|CELL FORMED)")
        if watch and joined:
            ev.append("%s save tables (last): %s" % (i.name(), watch[-1]))
    return ok, ev


def gate9b(insts):
    """NPC death: an NPC the authority runs dies there (one lifepod, on the runner) and its mirrors play the explosion
    as a picture (no lifepod, no vanish write on members)."""
    ev = []
    killed = [(i, m) for i in insts for m in i.grep(r"COOP: NPC dev: blowing up NPC (\S+) (\S+)")]
    if not killed:
        return False, ["FAIL: no NPC was blown up (use --coop-dev-pirate with --coop-dev-kill-npc)"]
    ok = True
    for i, m in killed:
        nid = m.group(1)
        pods = {o.name(): o.count(r"Exploded \[.*\] with lifepod") - (1 if o.count(r"COOP: NPC s\.die sent") else 0) for o in insts}
        boom = [o.name() for o in insts if o is not i and o.count(r"COOP: NPC mirror %s exploding" % re.escape(nid))]
        ev.append("%s blew up %s; mirrors exploding on %s; NPC lifepods per machine %s" % (i.name(), nid, boom, pods))
        if not boom:
            ok = False
            ev.append("FAIL: no member played the NPC's explosion")
        if pods.get(i.name(), 0) != 1 or any(n for k, n in pods.items() if k != i.name()):
            ok = False
            ev.append("FAIL: the NPC's lifepod must exist exactly once, on its runner")
    return ok, ev


def gate9c(insts):
    """Pre-join oddities: a member's own oddity (a moonlet from a POI) is freed when it joins a cell, and comes back
    from its POI once the member is solo near it again (check savecheck.sh too: no save file changes)."""
    ev = []
    staged = False
    ok = True
    for i in insts:
        lines = i.lines
        poi = [n for n, l in enumerate(lines) if "COOP: NPC dev: test POI" in l]
        if not poi:
            continue
        staged = True
        ev_name = re.search(r"\(event (\S+)\)", lines[poi[0]]).group(1)
        spawns = [n for n, l in enumerate(lines) if re.search(r"(Location-based oddity|Re-spawning) %s\b" % re.escape(ev_name), l)]
        freed = [(n, re.search(r"freed (\d+) oddities of mine (\[.*?\]), kept (\d+) (\[.*\])", l)) for n, l in enumerate(lines)
                 if "joined: freed" in l and "oddities" in l]
        back = [n for n, l in enumerate(lines) if "COOP: NPC dev: returned to" in l]
        first = [n for n in spawns if n > poi[0]]
        ev.append("%s: POI for %s; oddity spawned %d time(s)" % (i.name(), ev_name, len(spawns)))
        if not first or not freed:
            ok = False
            ev.append("FAIL: the oddity never spawned before joining, or the member never joined")
            continue
        fn, fm = freed[0]
        ev.append("  joined: freed %s %s, kept %s %s" % (fm.group(1), fm.group(2), fm.group(3), fm.group(4)))
        if fn < first[0] or int(fm.group(1)) < 1:
            ok = False
            ev.append("FAIL: nothing freed after the oddity spawned")
        if not back:
            ok = False
            ev.append("FAIL: the member never returned to the POI (--coop-dev-return)")
            continue
        again = [n for n in spawns if n > back[0]]
        ev.append("  returned to the POI; oddity back from its POI: %s" % bool(again))
        if not again:
            ok = False
            ev.append("FAIL: the oddity did not come back after leaving the cell")
    if not staged:
        return False, ["FAIL: not staged (use --coop-dev-poi=<event> and --coop-dev-return=<s> on the joining member)"]
    return ok, ev


# ---------------------------------------------------------------- Own track (gates 1-6, 10; tim-58)

import datetime


def _ts(line):
    m = re.search(r"\[(\d+/\d+/\d+ \d+:\d+:\d+)\]", line)
    return datetime.datetime.strptime(m.group(1), "%Y/%m/%d %H:%M:%S").timestamp() if m else None


def gate1(insts):
    """Claim race: every DevBot race trial ends with exactly one owner, and the rock back with the authority."""
    trials = {}
    for i in insts:
        for m in i.grep(r"COOP: BOT race trial=(\d+) id=\S+ result=(\S+)"):
            t = trials.setdefault(int(m.group(1)), {"granted": 0, "denied": 0, "missing": 0})
            r = m.group(2)
            t["granted" if r == "granted" else "denied" if r.startswith("denied") else "missing"] += 1
        for m in i.grep(r"COOP: BOT race trial=(\d+) id=\S+ after (claims|release) owner=(\d+)"):
            t = trials.setdefault(int(m.group(1)), {"granted": 0, "denied": 0, "missing": 0})
            t[m.group(2)] = m.group(3)
            t["auth"] = i.peer
    if not trials:
        return False, ["FAIL: no race trials (run with --coop-bot=race,N on every instance)"]
    bad = [n for n, t in trials.items()
           if t["granted"] != 1 or t["missing"] or "claims" not in t or t.get("release") != t.get("auth")]
    ev = ["%d trials, %d with exactly one owner and the rock returned" % (len(trials), len(trials) - len(bad))]
    ev += ["FAIL trial %d: %s" % (n, trials[n]) for n in bad[:10]]
    return not bad, ev


def gate2(insts, arm=False):
    """Mid-fracture grab: the claw ends with the rock or with shards, never both, never neither."""
    res = [(i.name(), m.group(1), m.group(2), m.group(3)) for i in insts
           for m in i.grep(r"COOP: BOT frac trial=(\d+) .*result=(\S+)(.*)")
           if not arm or not re.search(r"\((jitter|no )", m.group(3))]   # noarm lines end "(jitter ..)" / "(no ..)"
    if not res:
        return False, ["FAIL: no fracture-race trials (run with --coop-bot=frac,N%s)" % ("" if arm else "[,noarm]")]
    # shards the authority's fracture actually spawned (the stock fracture can spawn none: each shard gets one
    # placement try); "neither" is only a failure when shards existed
    spawned = {}
    for i in insts:
        for m in i.grep(r"COOP: BOT frac trial=(\d+) id=\S+ shards spawned=(\d+)"):
            spawned[m.group(1)] = int(m.group(2))
    counts = {}
    bad = []
    for r in res:
        key = r[2]
        # a real arm's chase notes "[n shards seen, m this arm takes]": a salvage arm only locks rocks the ship's
        # mineral filter passes, so shards it can't take leave nothing to grab, like a fracture with no shards
        takes = re.search(r"\[\d+ shards seen, (\d+) this arm takes\]", r[3])
        if key == "neither" and spawned.get(r[1]) == 0:
            key = "neither (fracture spawned no shards: stock)"
        elif key == "neither" and takes and int(takes.group(1)) == 0:
            key = "neither (no shard this arm takes: stock mineral filter)"
        elif key not in ("rock", "shards"):
            bad.append(r)
        counts[key] = counts.get(key, 0) + 1
    grabbed = counts.get("rock", 0) + counts.get("shards", 0)
    ev = ["%d trials: %s" % (len(res), counts)]
    ev += ["FAIL %s trial %s: %s%s (shards spawned: %s)" % (r + (spawned.get(r[1], "?"),)) for r in bad[:10]]
    if arm and not grabbed:
        ev.append("FAIL: the arm took nothing in any trial")
    return not bad and (grabbed > 0 or not arm), ev


def gate3(insts):
    """Holder hard-kill: the held rock is re-owned by the authority within 2 s of the holder's last log line."""
    ev = []
    ok = False
    for i in insts:
        for line in i.lines:
            m = re.search(r"COOP: OWN reown (\S+) from lost (\d+)", line)
            if not m:
                continue
            holder = [h for h in insts if h.peer == m.group(2)]
            last = _ts(holder[0].lines[-1]) if holder and holder[0].lines else None
            dt = _ts(line) - last if last else None
            # a claw run must have held it in the arm, not through some other local claim (haul drones, the hold)
            claw = holder and holder[0].count(r"COOP: BOT claw ")
            inArm = not claw or holder[0].count(r"BOT claw holding id=%s .*locked=True" % re.escape(m.group(1))) > 0
            good = dt is not None and dt <= 2.0 and inArm
            ok = ok or good
            ev.append("%s re-owned %s from %s, %s s after the holder's last log line%s%s" % (
                i.name(), m.group(1), m.group(2), "?" if dt is None else "%.0f" % dt, "" if dt is not None and dt <= 2.0 else "  FAIL (>2 s)",
                "" if inArm else "  FAIL (the holder's arm never locked it)"))
    if not ev:
        ev.append("FAIL: no re-own (hard-kill a member holding a rock: --coop-bot=claw,1,hold)")
    return ok, ev


def gate4(insts):
    """Handoff while holding: the new authority adopts the member's held rock and the member keeps holding it."""
    ev = []
    ok = False
    for i in insts:
        if not i.count(r"COOP: CELL PROMOTED"):
            continue
        for line in i.lines:
            m = re.search(r"COOP: OWN o\.list adopts (\S+) owned by (\d+)", line)
            if not m:
                continue
            t = _ts(line)
            holder = [h for h in insts if h.peer == m.group(2)]
            rx = re.compile(r"BOT claw holding id=%s .*locked=True mine=True" % re.escape(m.group(1)))
            held = [l for l in (holder[0].lines if holder else []) if rx.search(l) and _ts(l) and _ts(l) >= t]
            good = len(held) > 0
            ok = ok or good
            ev.append("%s adopted %s held by %s; holder's 'mine=True' lines after that: %d%s" % (
                i.name(), m.group(1), m.group(2), len(held), "" if good else "  FAIL"))
    if not ev:
        ev.append("FAIL: no o.list adoption after a promotion (quit the authority while a member holds a rock)")
    return ok, ev


def _dmg(insts):
    rows = []
    rx = r"COOP: OWN dmg (\S+) owner=(\d+) here=(\w+) fwd=(\d+)/([\d.]+) applied=(\d+)/([\d.]+) bullet applied=(\d+) fx=(\d+)"
    for i in insts:
        for m in i.grep(rx):
            rows.append((i.name(),) + m.groups())
    return rows


def gate5(insts):
    """Beams: every beam hit a shooter forwards is applied once, on the rock's owner, and never on a copy."""
    fwd = {}
    app = {}
    copy_applied = []
    for r in _dmg(insts):
        _, rid, owner, here, fn, fe, an, ae = r[:8]
        f = fwd.setdefault(rid, [0, 0.0])
        a = app.setdefault(rid, [0, 0.0])
        f[0] += int(fn)
        f[1] += float(fe)
        a[0] += int(an)
        a[1] += float(ae)
        if here == "copy" and int(an):
            copy_applied.append(r)
    ids = sorted(k for k in fwd if fwd[k][0] or app[k][0])
    if not ids:
        return False, ["FAIL: no forwarded beam hits (run with --coop-bot=laser,N)"]
    bad = [k for k in ids if fwd[k][0] != app[k][0] or abs(fwd[k][1] - app[k][1]) > 1.0]
    ev = ["%d rocks hit; forwarded = applied on %d" % (len(ids), len(ids) - len(bad))]
    ev += ["%s: forwarded %d/%.0f, applied %d/%.0f%s" % (k, fwd[k][0], fwd[k][1], app[k][0], app[k][1], "  FAIL" if k in bad else "")
           for k in ids[:12]]
    ev += ["FAIL applied on a copy: %s" % (r,) for r in copy_applied[:5]]
    return not bad and not copy_applied, ev


def gate6(insts):
    """Bullets: bullet contacts damage a rock only on its owner; every other machine's copy takes effects only."""
    rows = _dmg(insts)
    applied_owned = sum(int(r[8]) for r in rows if r[3] == "owned")
    applied_copy = [r for r in rows if r[3] == "copy" and int(r[8])]
    fx = sum(int(r[9]) for r in rows)
    shots = sum(i.count(r"COOP: BOT massdriver trial=\d+ id=\S+ firing") for i in insts)
    ev = ["mass driver trials %d; bullet contacts applied on owners %d, suppressed on copies %d" % (shots, applied_owned, fx)]
    ev += ["FAIL applied on a copy: %s" % (r,) for r in applied_copy[:5]]
    if applied_owned == 0:
        ev.append("FAIL: no bullet contact applied anywhere (run with --coop-bot=massdriver,N)")
    return applied_owned > 0 and not applied_copy, ev


def gate10(insts):
    """Ore audit: conservation balances (born - gone = live), every member eat reaches the authority exactly once,
    and each eat's composition = what the authority handed out minus filler the MPU stripped (minerals unchanged)."""
    lines = [(i.name(), m.group(0)) for i in insts for m in i.grep(r"COOP: OWN conserve .*")]
    if not lines:
        return False, ["FAIL: no conservation lines (the authority logs one every 30 s)"]
    bad = [l for l in lines if "MISMATCH" in l[1]]
    eaten = {}
    for i in insts:
        for m in i.grep(r"COOP: OWN eaten (\S+)"):
            eaten[m.group(1)] = eaten.get(m.group(1), 0) + 1
    twice = [k for k, n in eaten.items() if n > 1]
    sent = [(i.name(), m.group(1)) for i in insts for m in i.grep(r"COOP: OWN eat (\S+) \((\w+)\)")]
    lost = [s for s in sent if s[1] not in eaten]
    audits = [(i.name(), m.group(1), m.group(2)) for i in insts for m in i.grep(r"COOP: OWN eat-audit (\S+) .* (OK|BAD)$")]
    noaudit = [i.name() + " " + m.group(0) for i in insts for m in i.grep(r"COOP: OWN eat-audit \S+ in=\?.*")]
    badaudit = [a for a in audits if a[2] != "OK"]
    stripped = sum(1 for i in insts for m in i.grep(r"COOP: OWN eat-audit \S+ .* processed=\{.+\} OK$"))
    ev = ["%d conservation lines, %d mismatched; last: %s" % (len(lines), len(bad), lines[-1][1][:170])]
    ev.append("rocks eaten: %d, none twice: %s" % (len(eaten), not twice))
    ev.append("member eats sent %d, reached the authority %d; audited %d (%d with filler stripped), %d bad, %d unaudited" % (
        len(sent), len(sent) - len(lost), len(audits), stripped, len(badaudit), len(noaudit)))
    ev += ["FAIL %s: %s" % l for l in bad[:5]] + ["FAIL eaten twice: %s" % k for k in twice[:5]]
    ev += ["FAIL eat never reached the authority: %s %s" % s for s in lost[:5]]
    ev += ["FAIL audit %s %s %s" % a for a in badaudit[:5]] + ["FAIL unaudited: %s" % a for a in noaudit[:5]]
    if not sent:
        ev.append("FAIL: no member eats (run --coop-bot=eat,N on a member)")
    if not stripped:
        ev.append("FAIL: no eat had anything processed before it (in = out only proves the trivial case)")
    return bool(sent) and stripped > 0 and not bad and not twice and not lost and not badaudit and not noaudit, ev


def gate2r(insts):
    """Mid-fracture grab with a real salvage arm (dev slot savegame-arm.dv): gate 2 counting arm trials only."""
    return gate2(insts, arm=True)


def gate10r(insts):
    """Ore audit with a real MPU: gate 10, fed only by the stock MPU (--coop-bot=mpu,N), with at least one rock eaten."""
    ok, ev = gate10(insts)
    eaten = sum(i.count(r"COOP: BOT mpu trial=\d+ id=\S+ result=eaten") for i in insts)
    other = {}
    for i in insts:
        for m in i.grep(r"COOP: BOT mpu trial=\d+ id=\S+ result=(\S+)"):
            other[m.group(1)] = other.get(m.group(1), 0) + 1
    simulated = sum(i.count(r"COOP: BOT eat trial=") for i in insts)
    nompu = sum(i.count(r"COOP: BOT mpu: no MPU") for i in insts)
    ev.append("MPU trials: %s" % (other or "none"))
    if not eaten:
        ev.append("FAIL: the stock MPU ate no rock" + (" (no MPU on the bot's ship)" if nompu else ""))
    if simulated:
        ev.append("FAIL: %d simulated eat-bot lines; gate 10r is the real MPU only" % simulated)
    dup = _mpuDuplicates(insts)
    ev += ["FAIL processed by %s's MPU but %s" % d for d in dup[:5]]
    return ok and eaten > 0 and not simulated and not dup, ev


def _mpuDuplicates(insts):
    """Every rock the stock MPU ate on a member must reach the authority as an o.eat (tombstoned there), never as a
    release: a release hands the authority back a rock the member already turned into cargo (duplicated ore)."""
    out = []
    tomb = {m.group(1) for i in insts for m in i.grep(r"COOP: OWN eaten (\S+)")}
    released = {m.group(1) for i in insts for m in i.grep(r"COOP: OWN released (\S+) by")}
    for i in insts:
        for m in i.grep(r"COOP: BOT (?:mpu|haul) trial=\d+ id=(\S+) result=eaten"):
            rid = m.group(1)
            if not i.grep(r"COOP: OWN eat %s \(" % re.escape(rid)):
                out.append((i.name(), "%s sent no o.eat%s" % (rid, " (released to the authority)" if rid in released else "")))
            elif rid not in tomb:
                out.append((i.name(), "the authority never tombstoned %s" % rid))
    return out


def gatehaul(insts):
    """Haul drones: a member's haul drones claim the rock they push (touch-to-own) and move it to their excavator (or
    the MPU eats it); no trial hauls a rock it never owned; conservation and the ore audit hold (gate 10)."""
    rows = [(i.name(),) + m.groups() for i in insts
            for m in i.grep(r"COOP: BOT haul trial=(\d+) id=(\S+) result=(\S+) owned=(\w+) d0=(-?\d+) d1=(-?\d+)")]
    if not rows:
        none = sum(i.count(r"COOP: BOT haul: no haul drones") for i in insts)
        return False, ["FAIL: no haul trials%s (run --coop-bot=haul,N on a member with SYSTEM_DND_HAUL)" % (
            " (no haul drones on the bot's ship)" if none else "")]
    good = [r for r in rows if r[3] in ("eaten", "closer") and r[4] == "True"]
    unowned = [r for r in rows if r[3] in ("eaten", "closer") and r[4] != "True"]
    ok10, ev10 = gate10(insts) if any(i.grep(r"COOP: OWN eat ") for i in insts) else (True, ["no eats (ore audit not needed)"])
    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    ev = ["%d haul trials: %s; moved or eaten while owned: %d" % (len(rows), counts, len(good))]
    ev += ["%s trial %s %s: %s owned=%s %s -> %s px" % r for r in rows[:10]]
    ev += ["FAIL moved a rock it never owned: %s trial %s" % (r[0], r[1]) for r in unowned[:5]]
    ev += ["gate 10: " + e for e in ev10]
    if not good:
        ev.append("FAIL: no rock was hauled while owned")
    return bool(good) and not unowned and ok10, ev


def _secs(line):
    m = re.search(r"\[\d+/\d+/\d+ (\d+):(\d+):(\d+)\]", line)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else None


def gate11(insts):
    """Pause in a cell: focus loss, the Steam overlay and the pause key open the menu on one member without pausing
    its game; the cell keeps that player (no silence, handoff or leave) and its ship keeps moving."""
    ev = []
    ok = True
    staged = [i for i in insts if i.count(r"COOP: NPC dev pause step")]
    if not staged:
        return False, ["FAIL: not staged (use --coop-dev-pause=<s> on a member)"]
    for i in staged:
        steps = [l for l in i.lines if "COOP: NPC dev pause step" in l]
        t0, t1 = _secs(steps[0]), _secs(steps[-1]) + 4
        paused = [l for l in steps if "tree paused=True" in l]
        opened = i.count(r"COOP: SHIPS pause menu open in a cell")
        closed = i.count(r"COOP: SHIPS pause menu closed in a cell")
        where = [re.search(r"ship at \((-?[\d.]+), (-?[\d.]+)\)", l) for l in steps]
        moved = len({(round(float(m.group(1))), round(float(m.group(2)))) for m in where if m}) > 1
        ev.append("%s: %d steps, menu opened %d / closed %d in a cell, tree paused at a step: %d, ship moving: %s" % (
            i.name(), len(steps), opened, closed, len(paused), moved))
        if len(steps) < 6 or opened < 3 or closed < 2 or paused or not moved:
            ok = False
            ev.append("FAIL: the menu must open and close without pausing, and the ship must keep moving")
        for o in insts:
            bad = [l for l in o.lines if (t0 or 0) <= (_secs(l) or -1) <= (t1 or 0)
                   and re.search(r"COOP: CELL (authority \d+ silent|PROMOTED|LEFT cell|authority \d+ resigned)", l)]
            if bad:
                ok = False
                ev.append("FAIL %s during the pause steps: %s" % (o.name(), bad[0][-120:]))
    return ok, ev


def gate11b(insts):
    """Menu to title in a cell: a member and the authority leave through the pause menu; the others drop the member,
    or hand authority off, within 1 s, without waiting for the silence timeout."""
    ev = []
    ok = True
    quits = [(i, l) for i in insts for l in i.lines if "COOP: NPC dev: menu quit to title as" in l]
    if not quits:
        return False, ["FAIL: not staged (use --coop-dev-menu-quit=<s>,member and <s>,auth)"]
    roles = set()
    for i, l in quits:
        role = re.search(r"as (\w+)", l).group(1)
        roles.add(role)
        t = _secs(l)
        pat = r"COOP: CELL (member %s left|authority %s resigned|authority %s -> )" % (i.peer, i.peer, i.peer)
        seen = []
        for o in insts:
            if o is i:
                continue
            hits = [_secs(x) for x in o.lines if re.search(pat, x) and _secs(x) is not None and 0 <= _secs(x) - t <= 1]
            silent = [x for x in o.lines if re.search(r"COOP: CELL authority %s silent" % i.peer, x) and 0 <= (_secs(x) or -9) - t <= 10]
            if hits:
                seen.append("%s +%ds" % (o.name(), hits[0] - t))
            if silent:
                ok = False
                ev.append("FAIL %s: waited for the silence timeout on %s" % (o.name(), i.name()))
        ev.append("%s left as %s; noticed by %s" % (i.name(), role, seen))
        if not seen:
            ok = False
            ev.append("FAIL: nobody saw %s leave within 1 s" % i.name())
    if roles != {"member", "auth"}:
        ev.append("note: only %s staged" % sorted(roles))
    return ok, ev


def gate12(insts):
    """Friend labels: with friends flying together on one screen, no two friend labels overlap (needs
    --coop-dev-view on every player and the formation close, e.g. OFF_B=1200 WARP_C_DIST=300)."""
    ev = []
    ok = True
    seen = 0
    for i in insts:
        rows = [(int(m.group(1)), int(m.group(2))) for m in i.grep(r"COOP: OVERLAY .* labels=(\d+) overlap=(\d+)")]
        crowded = [r for r in rows if r[0] >= 2]
        bad = [r for r in crowded if r[1] > 0]
        seen += len(crowded)
        if rows:
            ev.append("%s: %d view lines, %d with 2+ labels, %d with overlap" % (i.name(), len(rows), len(crowded), len(bad)))
        if bad:
            ok = False
    if seen == 0:
        return False, ev + ["FAIL: not staged (no view line with 2+ friend labels; use --coop-dev-view and a close formation)"]
    return ok, ev


GATES = {
    1: gate1,
    2: gate2,
    "2r": gate2r,
    3: gate3,
    4: gate4,
    5: gate5,
    6: gate6,
    10: gate10,
    "10r": gate10r,
    "haul": gatehaul,
    7: gate7,
    8: gate8,
    9: gate9,
    "9b": gate9b,
    "9c": gate9c,
    11: gate11,
    "11b": gate11b,
    12: gate12,
}


def main(argv):
    want = list(GATES)
    if argv and argv[0] == "--gates":
        want = [int(g) if g.isdigit() else g for g in argv[1].split(",")]
        argv = argv[2:]
    files = sorted({f for g in argv for f in glob.glob(os.path.expanduser(g))})
    if not files:
        print(__doc__)
        return 1
    insts = [Instance(f) for f in files]
    print("instances: %s" % ", ".join(i.name() for i in insts))
    errors = [(i.name(), i.count(r"SCRIPT ERROR")) for i in insts if i.count(r"SCRIPT ERROR")]
    failed = False
    for g in want:
        if g not in GATES:
            print("gate %s: not implemented here" % g)
            continue
        ok, ev = GATES[g](insts)
        failed = failed or not ok
        print("gate %s: %s  %s" % (g, "PASS" if ok else "FAIL", GATES[g].__doc__.strip().split(":")[0]))
        for e in ev:
            print("    " + e)
    if errors:
        print("SCRIPT ERROR lines in dv logs: %s (check engine_log.txt too)" % errors)
        failed = True
    print("RESULT: %s" % ("FAIL" if failed else "PASS"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
