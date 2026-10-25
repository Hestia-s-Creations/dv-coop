# setres.py <settings.cfg> <W>x<H>|full <uiscale>: per-instance window size and UI scale for dev runs
import os, re, sys
p, res, ui = sys.argv[1], sys.argv[2], sys.argv[3]
# dev data only: never the player's real %APPDATA%/dV
real = os.path.realpath(os.path.join(os.environ.get('APPDATA', '/nonexistent'), 'dV')).lower()
target = os.path.realpath(p).lower()
if target.startswith(real + os.sep) or 'dvcoop' not in target:
    sys.exit('setres: refusing %s (not a dvcoop dev data dir)' % p)
s = open(p, encoding='utf-8').read()
def setkey(sec, key, val):
    global s
    m = re.search(r'(?ms)^\[%s\]\n(.*?)(?=^\[|\Z)' % sec, s)
    body = m.group(1)
    if re.search(r'(?m)^%s=' % key, body):
        body2 = re.sub(r'(?m)^%s=.*$' % key, '%s=%s' % (key, val), body)
    else:
        body2 = body.rstrip('\n') + '\n%s=%s\n\n' % (key, val)
    s = s[:m.start(1)] + body2 + s[m.end(1):]
if res == 'full':
    setkey('display', 'windowed', 'false'); setkey('display', 'fullscreen', 'false')
else:
    w, h = res.split('x')
    setkey('display', 'windowed', 'true'); setkey('display', 'fullscreen', 'false')
    setkey('display', 'windowSize', 'Vector2( %s, %s )' % (w, h))
setkey('ui', 'scale', ui)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print(p, res, ui)
