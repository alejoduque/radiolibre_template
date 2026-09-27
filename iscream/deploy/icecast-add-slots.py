#!/usr/bin/env python3
"""
Give iScream its broadcast slots in Icecast: clone the <mount> block of
/reporta.mp3 into /reporta2.mp3 … /reportaN.mp3 (same password and settings),
so every slot accepts the source password in /etc/iscream/iscream.env.

Run on the server as root, from the Mac:
    ssh -p 8888 root@altred.xyz 'python3 - 8 --no-recording' < iscream/deploy/icecast-add-slots.py

--no-recording removes <dump-file> and <on-disconnect> from the /reporta.mp3
block first. The 2021 setup had Icecast write every broadcast to
/tmp/reporta.mp3 and, on disconnect, upload it to archive.org; the page
promises nothing is recorded. Without the flag the script refuses to go on
while those are present.

Idempotent (existing mounts are left alone). Backs up icecast.xml, validates
the result before writing, reloads Icecast with SIGHUP (nobody is cut off),
and never prints a password.
"""
import re, shutil, subprocess, sys, time
import xml.etree.ElementTree as ET

XML = '/etc/icecast2/icecast.xml'
FIRST = '/reporta.mp3'
args = [a for a in sys.argv[1:] if not a.startswith('--')]
slots = int(args[0]) if args else 8
strip = '--no-recording' in sys.argv

src = open(XML, encoding='utf-8').read()

# The live (uncommented) <mount> block for FIRST.
blocks = [m for m in re.finditer(r'[ \t]*<mount\b[^>]*>(?:(?!</mount>).)*?</mount>', src, re.S)
          if re.search(r'<mount-name>\s*%s\s*</mount-name>' % re.escape(FIRST), m.group(0))]
comments = [(c.start(), c.end()) for c in re.finditer(r'<!--.*?-->', src, re.S)]
blocks = [m for m in blocks if not any(a <= m.start() < b for a, b in comments)]
if len(blocks) != 1:
    sys.exit('expected exactly one live <mount> block for %s, found %d; nothing changed' % (FIRST, len(blocks)))
block = blocks[0]

print('the %s block (passwords masked):' % FIRST)
print(re.sub(r'(<password>)[^<]*', r'\1***', block.group(0)))

RECORDING = re.compile(r'[ \t]*<(dump-file|on-disconnect|on-connect)>[^<]*</\1>[ \t]*\n?')
found = [m.group(1) for m in RECORDING.finditer(block.group(0))]
stripped = []
if found:
    if not strip:
        sys.exit('\n%s has %s: Icecast records it and/or runs the old archive.org upload, which '
                 'contradicts the page ("no grabamos nada"). Re-run with --no-recording; nothing changed.'
                 % (FIRST, ', '.join('<%s>' % f for f in found)))
    clean = RECORDING.sub('', block.group(0))
    src = src[:block.start()] + clean + src[block.end():]
    stripped = found
    block = re.search(re.escape(clean), src)

existing = {(m.findtext('mount-name') or '').strip() for m in ET.fromstring(src).iter('mount')}
stem, ext = re.match(r'^(.*?)(\.[a-z0-9]+)?$', FIRST, re.I).groups()
wanted = ['%s%d%s' % (stem, i, ext or '') for i in range(2, slots + 1)]
add = [m for m in wanted if m not in existing]
if not add and not stripped:
    print('\nall %d slots already exist; nothing to do' % slots)
    sys.exit(0)

clones = ''.join('\n' + re.sub(r'<mount-name>\s*%s\s*</mount-name>' % re.escape(FIRST),
                               '<mount-name>%s</mount-name>' % m, block.group(0)) for m in add)
out = src[:block.end()] + clones + src[block.end():]

try:
    names = [(m.findtext('mount-name') or '').strip() for m in ET.fromstring(out).iter('mount')]
except ET.ParseError as e:
    sys.exit('edited icecast.xml does not parse (%s); nothing changed' % e)

bak = XML + '.bak-' + time.strftime('%Y%m%d-%H%M%S')
shutil.copy2(XML, bak)
with open(XML, 'w', encoding='utf-8') as f:
    f.write(out)

print('\nremoved from %s: %s' % (FIRST, ', '.join('<%s>' % f for f in stripped) or '(nothing)'))
print('added:', ', '.join(add) or '(none)')
print('mounts now:', ', '.join(n for n in names if n))
print('backup:', bak)
r = subprocess.run(['systemctl', 'reload', 'icecast2'])
print('icecast2 reload (SIGHUP):', 'ok' if r.returncode == 0 else 'FAILED %d' % r.returncode)
