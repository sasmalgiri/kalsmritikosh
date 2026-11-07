#!/usr/bin/env python3
"""Pack bench shards into ONE JSON resource the sandboxed Xcode test host can read.

usage: pack_local.py CASES OUT.json [--shard NAME ...] [--env K=V ...]

The agent session cannot launch `xcodebuild test` (Pseudo Terminal Setup Error) and Xcode's own
test runner is a sandboxed host that cannot read ~/CaseBench, nor take TEST_RUNNER_* variables.
So the shards (truth.jsonl + each case's documents, base64) and the run settings are packed into
`KalsmritikoshTests/Fixtures/CaseBenchLocal/casebench-pack.json`; `CaseBenchRunner` materialises
the pack in its temporary folder, runs it exactly as an environment-driven run, and records every
shard result as a test attachment, which `unpack_results.py` reads back out of the .xcresult.
The pack is never committed (gitignored): it is a measurement input, recorded in MEASUREMENT.txt.
"""
import base64, glob, json, os, sys

args = sys.argv[1:]
if len(args) < 2:
    print(__doc__); sys.exit(2)
cases, out = args[0], args[1]
shards_wanted, env = [], {}
i = 2
while i < len(args):
    if args[i] == "--shard": shards_wanted.append(args[i + 1]); i += 2
    elif args[i] == "--env": k, v = args[i + 1].split("=", 1); env[k] = v; i += 2
    else: print("unknown option", args[i]); sys.exit(2)

shards = []
for truth in sorted(glob.glob(os.path.join(cases, "**", "truth.jsonl"), recursive=True)):
    shard_dir = os.path.dirname(truth)
    name = os.path.relpath(shard_dir, cases)
    if shards_wanted and os.path.basename(shard_dir) not in shards_wanted and name not in shards_wanted:
        continue
    entries = []
    for case in sorted(os.listdir(shard_dir)):
        folder = os.path.join(shard_dir, case)
        if not os.path.isdir(folder) or case.startswith("."): continue
        files = []
        for f in sorted(os.listdir(folder)):
            if f.startswith("."): continue
            with open(os.path.join(folder, f), "rb") as fh:
                files.append({"name": f, "b64": base64.b64encode(fh.read()).decode("ascii")})
        entries.append({"case": case, "files": files})
    shards.append({"name": name, "truth": open(truth, encoding="utf-8").read(), "cases": entries})

pack = {"set": os.path.basename(os.path.dirname(os.path.abspath(cases))), "env": env, "shards": shards}
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(out, "w", encoding="utf-8") as fh:
    json.dump(pack, fh)
print(f"packed {len(shards)} shard(s), {sum(len(s['cases']) for s in shards)} case(s) → {out} ({os.path.getsize(out) // 1024} KiB)")
