# Convert `otool -ov` output into compact per-class pseudo headers.
import re, sys, os
src, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
classes = {}   # name -> dict(super, ivars, imethods, cmethods, protocols)
cur = None; meta = False; section = None; pending_super = None; pending_meta = False
for line in open(src, errors='replace'):
    s = line.strip()
    m = re.match(r'superclass 0x[0-9a-f]+ ?(\S*)', s)
    if m:
        pending_super = m.group(1).replace('_OBJC_CLASS_$_', '').replace('_OBJC_METACLASS_$_', '')
        continue
    if s.startswith('Meta Class'):
        pending_meta = True; continue
    m = re.match(r'name\s+0x[0-9a-f]+ (\S+)$', s)
    if m and line.startswith('        name '):   # class name line (8 spaces)
        name = m.group(1); meta = pending_meta; pending_meta = False
        cur = classes.setdefault(name, dict(sup='', ivars=[], im=[], cm=[], props=[]))
        if not meta and pending_super is not None: cur['sup'] = pending_super
        section = None; continue
    if cur is None: continue
    if s.startswith('baseMethods'): section = 'cm' if meta else 'im'; continue
    if s.startswith('ivars'): section = 'ivars'; continue
    if s.startswith('baseProperties'): section = 'props'; continue
    if s.startswith('baseProtocols') or s.startswith('weakIvarLayout'): section = None; continue
    if section in ('im', 'cm'):
        m = re.match(r'name\s+0x[0-9a-f]+ (.+)$', s)
        if m: cur[section].append([m.group(1), '']); continue
        m = re.match(r'types\s+0x[0-9a-f]+ (.+)$', s)
        if m and cur[section]: cur[section][-1][1] = m.group(1)
    elif section == 'ivars':
        m = re.match(r'name\s+0x[0-9a-f]+ (.+)$', s)
        if m: cur['ivars'].append([m.group(1), '']); continue
        m = re.match(r'type\s+0x[0-9a-f]+ (.+)$', s)
        if m and cur['ivars']: cur['ivars'][-1][1] = m.group(1)
    elif section == 'props':
        m = re.match(r'name\s+0x[0-9a-f]+ (.+)$', s)
        if m: cur['props'].append([m.group(1), '']); continue
        m = re.match(r'attributes\s+0x[0-9a-f]+ (.+)$', s)
        if m and cur['props']: cur['props'][-1][1] = m.group(1)
for n, c in classes.items():
    with open(os.path.join(outdir, n + '.h'), 'w') as f:
        f.write(f"@interface {n} : {c['sup']}\n")
        for i, t in c['ivars']: f.write(f"  ivar {i}  {t}\n")
        for i, t in c['props']: f.write(f"  @property {i}  {t}\n")
        for i, t in c['cm']: f.write(f"+ {i}  {t}\n")
        for i, t in c['im']: f.write(f"- {i}  {t}\n")
        f.write("@end\n")
print(len(classes), "classes")
