#!/usr/bin/env python3
# usage: mark.py <commit> <ID> [<ID> ...] -- "<remaining note>"
import json,sys,subprocess
args=sys.argv[1:]; sha=args[0]; rest=args[1:]
note=""
if "--" in rest: i=rest.index("--"); note=" ".join(rest[i+1:]); rest=rest[:i]
p='docs/SMART_MAP_COMPLETION_MATRIX.json'; rows=json.load(open(p))
ids=set(rest); hit=set()
for r in rows:
    if r['id'] in ids:
        r['status']='IMPLEMENTED'; r['commit_sha']=sha; hit.add(r['id'])
        r['remaining_limit']=("Not tested (owner 2026-11-22: implement now, test later). "+note).strip()
        r['next_action']="Write and run its tests; then a GUI walk where it has a screen."
        r['status_note']="Unified-path program 2026-11-22: implemented, NOT tested."
missing=ids-hit
if missing: sys.exit("unknown ids: %s"%missing)
open(p,'w').write(json.dumps(rows,indent=2)+"\n")
subprocess.run(["python3","scripts/smart-map-matrix.py"],check=True)
