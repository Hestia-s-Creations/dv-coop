"""Steam loopback gate: scores the log of a tools/steamloop.sh run (one instance, --coop-host --coop-dev-steam-loop).

Usage: python tools/gate_steam.py <dv log> [<dv log> ...]      (several logs of one instance are joined)

  1  steam     Steam was ready and the lobby was created (lobby_created result=1, LOBBY ID)
  2  send      the test sent its packets over the Steam transport (COOP-STEAMLOOP: sent N)
  3  recv      every packet came back through readP2PPacket: got == sent, each seq exactly once, the padding sizes
               read back match the sizes sent (0, 50, ... 950 B), and the sender key resolved to our own id
  4  clean     no packet was dropped as forged or bad (the sender key would be wrong), no "unknown packet type",
               and zero SCRIPT ERROR lines in the logs and in engine_log.txt beside them

Exit 1 if any gate fails. What this does not cover: two accounts on two networks (lobby join, p2p_session_request
from a stranger, NAT relay); it proves the send/receive code on this game's GodotSteam with one account.
"""
import sys, re, os, glob


def main():
    logs = sys.argv[1:]
    if not logs:
        sys.exit(__doc__)
    lines = []
    for p in sorted(logs, key=os.path.getmtime):
        lines += open(p, encoding="utf-8", errors="replace").read().splitlines()
    ok = True

    def gate(name, passed, detail):
        nonlocal ok
        ok = ok and passed
        print(f"{'PASS' if passed else 'FAIL'}  {name}")
        print(f"      {detail}")

    me = re.search(r"COOP: Steam ready, I am (\d+)", "\n".join(lines))
    created = [l for l in lines if "lobby_created result=1" in l]
    lobby = [l for l in lines if "COOP: LOBBY ID" in l]
    gate("1 steam", bool(me and created and lobby),
         f"steam id {me.group(1) if me else 'none'}; lobby_created ok={len(created)}; LOBBY ID lines={len(lobby)}")

    sent = re.search(r"COOP-STEAMLOOP: sent (\d+) packets", "\n".join(lines))
    n = int(sent.group(1)) if sent else 0
    gate("2 send", n > 0, f"sent {n}" if sent else "no COOP-STEAMLOOP sent line (lobby never created, or test not armed)")

    got = [re.search(r"got seq=(\d+) from=(\d+) pad=(\d+) B age=(\d+) ms", l) for l in lines if "COOP-STEAMLOOP: got" in l]
    got = [g for g in got if g]
    seqs = sorted(int(g.group(1)) for g in got)
    froms = {g.group(2) for g in got}
    pads_ok = all(int(g.group(3)) == int(g.group(1)) * 50 for g in got)
    result = [l for l in lines if "COOP-STEAMLOOP: RESULT" in l]
    ages = [int(g.group(4)) for g in got]
    gate("3 recv", n > 0 and seqs == list(range(n)) and froms == ({me.group(1)} if me else set()) and pads_ok,
         f"got {len(got)}/{n}; seqs {'complete, each once' if seqs == list(range(n)) else seqs}; "
         f"from {sorted(froms) or 'nobody'}; padding {'matches' if pads_ok else 'MISMATCH'}; "
         f"age {min(ages) if ages else '-'}..{max(ages) if ages else '-'} ms; result: {result[-1].split('RESULT')[-1].strip() if result else 'none'}")

    bad = [l for l in lines if re.search(r"COOP: (packet on link .* claims sender|bad packet on link|unknown packet type)", l)]
    errs = [l for l in lines if "SCRIPT ERROR" in l]
    for p in {os.path.dirname(p) for p in logs}:
        for e in glob.glob(os.path.join(p, "engine_log*.txt")):
            errs += [l for l in open(e, encoding="utf-8", errors="replace").read().splitlines() if "SCRIPT ERROR" in l]
    gate("4 clean", not bad and not errs,
         f"dropped/unknown packets {len(bad)}, script errors {len(errs)}" + ("".join("\n      " + l[:160] for l in (bad + errs)[:6])))

    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
