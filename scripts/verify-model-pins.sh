#!/usr/bin/env bash
# verify-model-pins.sh — prove the BGE models on disk (and in an archived app)
# are exactly the pinned builds. (Sixteenth review: existence checks prove
# nothing — every recorded hash is RECOMPUTED; missing, changed, or UNLISTED
# artifact files fail.)
#
# Modes:
#   scripts/verify-model-pins.sh
#       Verify Kalsmritikosh/Resources/{BGESmallEmbedder,BGEReranker}: every
#       artifact hash in MODEL_PIN.json must match a recomputed sha256, and no
#       unlisted file may exist among the pinned artifacts.
#
#   scripts/verify-model-pins.sh --record-compiled <path/to/Kalsmritikosh.app>
#       Record sha256 of every file inside the app's compiled
#       BGESmallEmbedder.mlmodelc / BGEReranker.mlmodelc into
#       release/COMPILED_MODEL_HASHES.json (run once against the archive's
#       .app at archive time — compiled .mlmodelc bytes cannot be derived from
#       the pre-compilation .mlpackage hashes).
#
#   scripts/verify-model-pins.sh --verify-compiled <path/to/Kalsmritikosh.app>
#       Recompute those compiled hashes against another copy (e.g. the
#       exported/installed app) and fail on any difference.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE="verify-source"
APP=""
case "${1:-}" in
  --record-compiled) MODE="record-compiled"; APP="${2:?usage: --record-compiled <app>}" ;;
  --verify-compiled) MODE="verify-compiled"; APP="${2:?usage: --verify-compiled <app>}" ;;
  "") ;;
  *) echo "usage: $0 [--record-compiled <app> | --verify-compiled <app>]"; exit 2 ;;
esac

python3 - "$MODE" "$APP" <<'PY'
import hashlib, json, os, sys

mode, app = sys.argv[1], sys.argv[2]
fail = False

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def hash_tree(root, rel_to):
    out = {}
    if os.path.isfile(root):
        out[os.path.relpath(root, rel_to)] = sha256(root)
        return out
    for r, _, files in os.walk(root):
        for fn in sorted(files):
            fp = os.path.join(r, fn)
            out[os.path.relpath(fp, rel_to)] = sha256(fp)
    return out

if mode == "verify-source":
    for model_dir in ["Kalsmritikosh/Resources/BGESmallEmbedder",
                      "Kalsmritikosh/Resources/BGEReranker"]:
        pin_path = os.path.join(model_dir, "MODEL_PIN.json")
        if not os.path.isfile(pin_path):
            print(f"::error::{model_dir}: MODEL_PIN.json missing — rebuild with the pinned script")
            fail = True
            continue
        pin = json.load(open(pin_path))
        recorded = pin.get("artifacts", {})
        if not recorded:
            print(f"::error::{pin_path}: empty artifact list")
            fail = True
            continue
        # Recompute every recorded hash; collect actual files among the pinned
        # artifact roots so UNLISTED files are also caught.
        roots = sorted({rel.split("/", 1)[0] for rel in recorded})
        actual = {}
        for root in roots:
            p = os.path.join(model_dir, root)
            if not os.path.exists(p):
                print(f"::error::{model_dir}: pinned artifact '{root}' is MISSING")
                fail = True
                continue
            actual.update(hash_tree(p, model_dir))
        for rel, want in sorted(recorded.items()):
            got = actual.pop(rel, None)
            if got is None:
                print(f"::error::{model_dir}: recorded artifact file '{rel}' is MISSING")
                fail = True
            elif got != want:
                print(f"::error::{model_dir}: '{rel}' hash CHANGED (want {want[:12]}…, got {got[:12]}…)")
                fail = True
        for rel in sorted(actual):
            print(f"::error::{model_dir}: UNLISTED file among pinned artifacts: '{rel}'")
            fail = True
        if not fail:
            print(f"OK {model_dir}: {len(recorded)} artifact hashes match "
                  f"(repo {pin.get('repo')} @ {str(pin.get('revision'))[:12]}…)")
else:
    res = os.path.join(app, "Contents", "Resources")
    record_path = "release/COMPILED_MODEL_HASHES.json"
    hashes = {}
    for name in ["BGESmallEmbedder.mlmodelc", "BGEReranker.mlmodelc"]:
        p = os.path.join(res, name)
        if not os.path.isdir(p):
            print(f"::error::{app}: compiled model '{name}' missing from Contents/Resources")
            fail = True
            continue
        hashes.update({f"{name}/{k}" if not k.startswith(name) else k: v
                       for k, v in hash_tree(p, res).items()})
    if mode == "record-compiled" and not fail:
        json.dump({"app": os.path.basename(app), "compiled": hashes},
                  open(record_path, "w"), indent=2, sort_keys=True)
        print(f"recorded {len(hashes)} compiled-model file hashes → {record_path}")
    elif mode == "verify-compiled":
        if not os.path.isfile(record_path):
            print(f"::error::{record_path} missing — run --record-compiled against the archive first")
            fail = True
        else:
            want = json.load(open(record_path)).get("compiled", {})
            for rel, w in sorted(want.items()):
                got = hashes.pop(rel, None)
                if got is None:
                    print(f"::error::compiled '{rel}' MISSING from {app}")
                    fail = True
                elif got != w:
                    print(f"::error::compiled '{rel}' hash CHANGED")
                    fail = True
            for rel in sorted(hashes):
                print(f"::error::UNLISTED compiled file: '{rel}'")
                fail = True
            if not fail:
                print(f"OK: {len(want)} compiled-model hashes match {app}")

sys.exit(1 if fail else 0)
PY
