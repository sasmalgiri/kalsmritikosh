#!/usr/bin/env python3
"""Copy the shard results a bundled CaseBenchRunner run attached to its .xcresult into RESULTS.

usage: unpack_results.py XCRESULT RESULTS_DIR

Each attachment named `<shard>.jsonl` becomes RESULTS_DIR/<shard>.jsonl, so ccsscore.py and
adjudication_pack.py read it exactly as they read a Terminal run's results.
"""
import json, os, shutil, subprocess, sys, tempfile

if len(sys.argv) != 3:
    print(__doc__); sys.exit(2)
xcresult, results = sys.argv[1], sys.argv[2]
os.makedirs(results, exist_ok=True)


def shard_name(path):
    """The shard a result file belongs to (its summary line), or None when it is not a result file."""
    name = None
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try: d = json.loads(line)
                except ValueError: return None
                if "summary" in d: name = d["summary"].get("shard")
    except (OSError, UnicodeDecodeError):
        return None
    return name


def recover_from_data_store():
    """A run longer than Xcode's result writer tolerates ends "with unknown outcome": the bundle has
    no Info.plist, but its Data store still holds every attachment as a Zstandard object."""
    data = os.path.join(xcresult, "Data")
    zstd = shutil.which("zstd") or "/opt/homebrew/bin/zstd"
    n = 0
    for f in sorted(os.listdir(data)):
        if not f.startswith("data."): continue
        tmp = os.path.join(tempfile.gettempdir(), "xcattach-" + f[-12:])
        if subprocess.run([zstd, "-dqc", os.path.join(data, f)], stdout=open(tmp, "wb"), stderr=subprocess.DEVNULL).returncode != 0:
            continue
        name = shard_name(tmp)
        if name:
            shutil.copy(tmp, os.path.join(results, name + ".jsonl")); n += 1
        else:
            try:
                head = open(tmp, encoding="utf-8").read(200)
                if head.startswith("set:"): shutil.copy(tmp, os.path.join(results, "MEASUREMENT-pack.txt"))
            except UnicodeDecodeError:
                pass
        os.remove(tmp)
    return n


if not os.path.exists(os.path.join(xcresult, "Info.plist")):
    print(f"{recover_from_data_store()} shard result(s) recovered from the unfinished bundle's Data store → {results}")
    sys.exit(0)

tmp = tempfile.mkdtemp(prefix="xcattach-")
subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", xcresult, "--output-path", tmp], check=True)
copied = 0
# The exporter writes a manifest.json naming each attachment's suggested file name.
manifest = os.path.join(tmp, "manifest.json")
names = {}
if os.path.exists(manifest):
    for test in json.load(open(manifest)):
        for a in test.get("attachments", []):
            names[a["exportedFileName"]] = a.get("suggestedHumanReadableName") or a["exportedFileName"]
for f in os.listdir(tmp):
    human = names.get(f, f)
    if not human.endswith(".jsonl"): continue
    shutil.copy(os.path.join(tmp, f), os.path.join(results, human))
    copied += 1
shutil.rmtree(tmp, ignore_errors=True)
print(f"{copied} shard result(s) → {results}")
