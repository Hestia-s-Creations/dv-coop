"""Check that this repo contains exactly what it says it does, and nothing else.

Usage: python tools/verify.py            check, print a report, exit 1 on any failure
       python tools/verify.py --update   rewrite MANIFEST.sha256 after an intended change

Python 3.8+ standard library only, no game install needed. It works on a git clone or on GitHub's
"Download ZIP". The checks:

  1. Every file in the repo is listed in MANIFEST.sha256 with a matching SHA-256, and every listed file exists.
  2. Nothing from the game is here: every file is plain UTF-8 text (the one exception is docs/SPEC.pdf, a
     rendering of docs/SPEC.md), src/ holds only .gd scripts, and every script in src/dv-coop/ext/ is a
     subclass of a game script ("extends \"res://...\"") rather than a copy of one.
  3. The mod's scripts call nothing that runs programs, opens web pages, reads or writes files, or opens any
     connection other than the Steam lobby and the ENet dev transport. Everything the mod does reach outside
     the game for is printed so you can read it.
  4. The mod zip built from src/ by tools/build.py, and its SHA-256, so a downloaded dv-coop.zip can be compared.
"""
import sys, re, hashlib, pathlib, tempfile, subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "MANIFEST.sha256"
BINARY_OK = {"docs/SPEC.pdf"}

# Calls that would let the mod do something beyond talking to its lobby. None may appear in src/.
FORBIDDEN = [
    (r"\bOS\.(execute|shell_open|create_process|kill|set_environment)\b", "runs programs or opens URLs"),
    (r"\b(HTTPRequest|HTTPClient)\b", "web requests"),
    (r"\b(StreamPeerTCP|StreamPeerSSL|TCP_Server|PacketPeerUDP|UDPServer|WebSocketClient|WebSocketServer|WebRTC\w*)\b", "raw sockets"),
    (r"\b(File|Directory|ConfigFile)\.new\b", "file access"),
    (r"\bResourceSaver\b", "writes resources to disk"),
    (r"\bJavaScript\b", "browser scripting"),
    (r"\bbytes2var\([^)]*,\s*true", "decoding objects from the network"),
    (r"\bExpression\.new\b", "evaluating code"),
]
# Things the mod is allowed to reach outside the game for. Each use is listed in the report.
DECLARED = [
    (r"\bSteam\.\w+", "Steam lobby, invites and P2P packets"),
    (r"\bNetworkedMultiplayerENet\b", "ENet transport for LAN / same-PC testing (--coop-enet-* flags only)"),
    (r"\bOS\.get_environment\(\"?\w*\"?\)", "reads an environment variable"),
    (r"\bOS\.get_cmdline_args\b", "reads the game's launch options"),
    (r"\"user://[^\"]*", "the game's own save folder"),
    (r"\b(pre)?load\(\"[^\"]+\"", "loads a script or resource from the game or the mod"),
]

def repo_files():
    """Every file that is, or could be, published: on a clone, git's tracked plus untracked-but-not-ignored files
    (so a file force-added under a gitignored folder still counts); on a downloaded zip, every file."""
    if (ROOT / ".git").exists():
        listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                                capture_output=True, check=True).stdout.decode("utf-8").split("\0")
        return sorted({f for f in listed if f and (ROOT / f).is_file()})
    return sorted(p.relative_to(ROOT).as_posix() for p in ROOT.rglob("*")
                  if p.is_file() and ".git" not in p.relative_to(ROOT).parts)

def file_hash(rel):
    data = (ROOT / rel).read_bytes()
    if rel not in BINARY_OK:
        data = data.replace(b"\r\n", b"\n")   # same hash on a Windows checkout
    return hashlib.sha256(data).hexdigest()

def read_manifest():
    entries = {}
    for line in MANIFEST.read_text(encoding="utf-8").splitlines():
        if line.strip() and not line.startswith("#"):
            digest, rel = line.split(None, 1)
            entries[rel.strip()] = digest
    return entries

def update():
    files = [f for f in repo_files() if f != "MANIFEST.sha256"]
    lines = ["# Every file in this repo and its SHA-256 (CRLF read as LF). Checked by tools/verify.py."]
    lines += [f"{file_hash(f)}  {f}" for f in files]
    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {MANIFEST.name} ({len(files)} files)")

def main():
    if "--update" in sys.argv:
        return update()
    fails = []

    print("1. Files match MANIFEST.sha256")
    listed = read_manifest()
    present = [f for f in repo_files() if f != "MANIFEST.sha256"]
    for f in present:
        if f not in listed:
            fails.append(f"not in manifest: {f}")
        elif file_hash(f) != listed[f]:
            fails.append(f"hash differs from manifest: {f}")
    for f in listed:
        if f not in present:
            fails.append(f"in manifest but missing: {f}")
    print(f"   {len(present)} files checked")

    print("2. Nothing from the game")
    for f in present:
        if f in BINARY_OK:
            continue
        data = (ROOT / f).read_bytes()
        try:
            data.decode("utf-8")
            if b"\0" in data:
                raise UnicodeDecodeError("utf-8", data, 0, 1, "NUL byte")
        except UnicodeDecodeError:
            fails.append(f"not a text file: {f}")
    scripts = [f for f in present if f.startswith("src/")]
    for f in scripts:
        if not f.endswith(".gd"):
            fails.append(f"src/ may hold only .gd scripts: {f}")
    for f in scripts:
        if f.startswith("src/dv-coop/ext/"):
            first = next((l for l in (ROOT / f).read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")), "")
            if not re.match(r'extends\s+"res://', first):
                fails.append(f"ext/ script is not a subclass of a game script: {f}")
    print(f"   {len(scripts)} mod scripts, {sum(len((ROOT / f).read_text(encoding='utf-8').splitlines()) for f in scripts)} lines in all")

    print("3. What the mod reaches outside the game for")
    gd = {f: (ROOT / f).read_text(encoding="utf-8") for f in scripts if f.endswith(".gd")}
    for f, text in gd.items():
        for n, line in enumerate(text.splitlines(), 1):
            code = line.split("#", 1)[0]
            for pat, why in FORBIDDEN:
                if re.search(pat, code):
                    fails.append(f"forbidden call ({why}): {f}:{n}: {line.strip()}")
    for pat, why in DECLARED:
        hits = sorted({m.group(0) for text in gd.values() for line in text.splitlines()
                       for m in re.finditer(pat, line.split("#", 1)[0])})
        if hits:
            print(f"   {why}:")
            print("     " + ", ".join(hits))

    print("4. Mod zip")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / "tools"))
    import build
    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "dv-coop.zip"
        count = build.build(out)
        print(f"   dv-coop.zip from src/: {count} files, sha256 {hashlib.sha256(out.read_bytes()).hexdigest()}")

    print()
    if fails:
        print("FAIL")
        for f in fails:
            print("  " + f)
        sys.exit(1)
    print("PASS: the repo holds exactly the files in MANIFEST.sha256, no game files, and no undeclared outside access.")

if __name__ == "__main__":
    main()
