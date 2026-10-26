"""Dev-only: read and restock a ΔV dev save slot (the copies under ~/dvcoop-data, never %APPDATA%\\dV).

A save is the stock game state as one JSON line inside a Godot 3 encrypted file (File.open_encrypted_with_pass):
"GDEC", u32 mode, md5 of the plaintext, u64 plaintext length, then AES-256 ECB blocks (zero padded) whose key is the
md5 hex of the password. The password is the stock one; it is read from the decompiled reference at run time
(DV_REF, default C:/Users/Tim/dv-coop/reference/CurrentGame.gd) so no game source lives in this repo.

Usage: python tools/dvsave.py show <slot.dv> [json.path ...]       print values (default: the ship's consumables)
       python tools/dvsave.py set <slot.dv> <json.path>=<number> ... write a copy back in place (keeps <slot>.orig once)
Only files under ~/dvcoop-data are accepted for `set`.
"""
import hashlib, json, os, re, shutil, struct, sys

REF = os.environ.get("DV_REF", "C:/Users/Tim/dv-coop/reference/CurrentGame.gd")
DEV = os.path.realpath(os.path.expanduser("~/dvcoop-data"))

# ---------------------------------------------------------------- AES-256 (ECB blocks), pure Python

def _xt(a):
    return ((a << 1) ^ 0x1B) & 0xFF if a & 0x80 else a << 1

def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xt(a)
        b >>= 1
    return r

SBOX = [0] * 256
INV = [0] * 256
p = q = 1
while True:
    p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
    q ^= q << 1
    q ^= q << 2
    q ^= q << 4
    q &= 0xFF
    if q & 0x80:
        q ^= 0x09
    x = q ^ ((q << 1) | (q >> 7)) & 0xFF ^ ((q << 2) | (q >> 6)) & 0xFF ^ ((q << 3) | (q >> 5)) & 0xFF \
        ^ ((q << 4) | (q >> 4)) & 0xFF ^ 0x63
    SBOX[p] = x & 0xFF
    if p == 1:
        break
SBOX[0] = 0x63
for i, v in enumerate(SBOX):
    INV[v] = i


def _expand(key):
    w = [list(key[i:i + 4]) for i in range(0, 32, 4)]
    rcon = 1
    for i in range(8, 60):
        t = list(w[i - 1])
        if i % 8 == 0:
            t = [SBOX[b] for b in t[1:] + t[:1]]
            t[0] ^= rcon
            rcon = _xt(rcon)
        elif i % 8 == 4:
            t = [SBOX[b] for b in t]
        w.append([a ^ b for a, b in zip(w[i - 8], t)])
    return [sum(w[r * 4:r * 4 + 4], []) for r in range(15)]


def _encrypt(rk, b):
    s = [x ^ k for x, k in zip(b, rk[0])]
    for r in range(1, 15):
        s = [SBOX[x] for x in s]
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if r < 14:
            s = sum(([_mul(c[0], 2) ^ _mul(c[1], 3) ^ c[2] ^ c[3], c[0] ^ _mul(c[1], 2) ^ _mul(c[2], 3) ^ c[3],
                      c[0] ^ c[1] ^ _mul(c[2], 2) ^ _mul(c[3], 3), _mul(c[0], 3) ^ c[1] ^ c[2] ^ _mul(c[3], 2)]
                     for c in (s[j:j + 4] for j in range(0, 16, 4))), [])
        s = [x ^ k for x, k in zip(s, rk[r])]
    return bytes(s)


def _decrypt(rk, b):
    s = [x ^ k for x, k in zip(b, rk[14])]
    for r in range(13, -1, -1):
        s = [s[(i - 4 * (i % 4)) % 16] for i in range(16)]
        s = [INV[x] for x in s]
        s = [x ^ k for x, k in zip(s, rk[r])]
        if r > 0:
            s = sum(([_mul(c[0], 14) ^ _mul(c[1], 11) ^ _mul(c[2], 13) ^ _mul(c[3], 9),
                      _mul(c[0], 9) ^ _mul(c[1], 14) ^ _mul(c[2], 11) ^ _mul(c[3], 13),
                      _mul(c[0], 13) ^ _mul(c[1], 9) ^ _mul(c[2], 14) ^ _mul(c[3], 11),
                      _mul(c[0], 11) ^ _mul(c[1], 13) ^ _mul(c[2], 9) ^ _mul(c[3], 14)]
                     for c in (s[j:j + 4] for j in range(0, 16, 4))), [])
    return bytes(s)

# ---------------------------------------------------------------- Godot 3 encrypted file

def _key():
    m = re.search(r'var password = "([^"]*)"', open(REF, encoding="utf-8").read())
    if not m:
        sys.exit("no password in %s (set DV_REF)" % REF)
    return _expand(hashlib.md5(m.group(1).encode()).hexdigest().encode())


def load(path):
    raw = open(path, "rb").read()
    if raw[:4] != b"GDEC":
        sys.exit("%s: not a Godot encrypted file" % path)
    md5, n = raw[8:24], struct.unpack("<Q", raw[24:32])[0]
    rk = _key()
    body = raw[32:]
    plain = b"".join(_decrypt(rk, body[i:i + 16]) for i in range(0, len(body), 16))[:n]
    if hashlib.md5(plain).digest() != md5:
        sys.exit("%s: md5 mismatch after decrypt (wrong password or format)" % path)
    return json.loads(plain.decode("utf-8").splitlines()[0])


def store(path, state):
    plain = (json.dumps(state, separators=(",", ":")) + "\n").encode("utf-8")
    pad = plain + b"\0" * (-len(plain) % 16)
    rk = _key()
    body = b"".join(_encrypt(rk, pad[i:i + 16]) for i in range(0, len(pad), 16))
    out = b"GDEC" + struct.pack("<I", 1) + hashlib.md5(plain).digest() + struct.pack("<Q", len(plain)) + body
    tmp = path + ".tmp"
    open(tmp, "wb").write(out)
    if load(tmp) != state:
        os.remove(tmp)
        sys.exit("round trip failed; nothing written")
    os.replace(tmp, path)

# ---------------------------------------------------------------- CLI

def _get(state, dotted):
    v = state
    for k in dotted.split("."):
        v = v[int(k)] if isinstance(v, list) else v[k]
    return v


def _set(state, dotted, value):
    keys = dotted.split(".")
    v = _get(state, ".".join(keys[:-1])) if len(keys) > 1 else state
    if keys[-1] not in v:
        sys.exit("no key %s (refusing to add one)" % dotted)
    v[keys[-1]] = value


def main(argv):
    if len(argv) < 2 or argv[0] not in ("show", "set"):
        sys.exit(__doc__)
    path = os.path.expanduser(argv[1])
    if argv[0] == "set" and not os.path.realpath(path).startswith(DEV + os.sep):
        sys.exit("set only writes dev copies under %s" % DEV)
    state = load(path)
    if argv[0] == "show":
        paths = argv[2:] or [k for k in ("ship.config.drones", "ship.config.fuel", "ship.config.capacitor")]
        for p in paths:
            try:
                print("%s = %s" % (p, json.dumps(_get(state, p))))
            except (KeyError, IndexError, ValueError, TypeError):
                print("%s: missing" % p)
        return 0
    for a in argv[2:]:
        k, v = a.split("=", 1)
        before = _get(state, k)
        _set(state, k, json.loads(v))
        print("%s: %s -> %s" % (k, json.dumps(before), v))
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
    store(path, state)
    print("wrote %s (original kept as %s.orig)" % (path, os.path.basename(path)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
