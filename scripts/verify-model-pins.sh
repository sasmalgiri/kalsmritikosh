#!/usr/bin/env bash
# verify-model-pins.sh — prove the BGE models on disk (and in an archived app)
# are exactly the pinned builds. (Sixteenth review: existence checks prove
# nothing — every recorded hash is RECOMPUTED; missing, changed, or UNLISTED
# artifact files fail. D-5: the compiled record is bound to the source pins.)
#
# Modes:
#   scripts/verify-model-pins.sh
#       Verify Kalsmritikosh/Resources/{BGESmallEmbedder,BGEReranker}: every
#       artifact hash in MODEL_PIN.json must match a recomputed sha256, and no
#       unlisted file may exist among the pinned artifacts.
#
#   scripts/verify-model-pins.sh --record-compiled <path/to/Kalsmritikosh.app>
#       Runs the source-pin verification FIRST and aborts on any failure, then
#       records sha256 of every file inside the app's compiled
#       BGESmallEmbedder.mlmodelc / BGEReranker.mlmodelc into
#       release/COMPILED_MODEL_HASHES.json, together with "source_pins"
#       (per model dir: repo, revision, and sha256 of MODEL_PIN.json) so the
#       compiled record is provably bound to the pinned sources. Run once
#       against the archive's .app at archive time — compiled .mlmodelc bytes
#       cannot be derived from the pre-compilation .mlpackage hashes.
#
#   scripts/verify-model-pins.sh --verify-compiled <path/to/Kalsmritikosh.app>
#       Recompute the compiled hashes against another copy (e.g. the exported/
#       installed app) and fail on any difference. When the source model dirs
#       exist on this Mac, the recorded source-pin sha256s are recomputed too;
#       otherwise it prints "source pins not present on this Mac — compiled
#       hashes only".
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
MODEL_DIRS = ["Kalsmritikosh/Resources/BGESmallEmbedder",
              "Kalsmritikosh/Resources/BGEReranker"]
RECORD_PATH = "release/COMPILED_MODEL_HASHES.json"

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

def verify_source():
    """Recompute every recorded artifact hash for both model dirs.
    Returns (failed, source_pins) — source_pins binds repo/revision +
    sha256(MODEL_PIN.json) per model dir for the compiled record."""
    failed = False
    source_pins = {}
    for model_dir in MODEL_DIRS:
        pin_path = os.path.join(model_dir, os.path.basename(model_dir) + ".MODEL_PIN.json")
        if not os.path.isfile(pin_path):
            print(f"::error::{model_dir}: {os.path.basename(pin_path)} missing — rebuild with the pinned script")
            failed = True
            continue
        pin = json.load(open(pin_path))
        source_pins[model_dir] = {"repo": pin.get("repo"), "revision": pin.get("revision"),
                                  "pin_sha256": sha256(pin_path)}
        recorded = pin.get("artifacts", {})
        if not recorded:
            print(f"::error::{pin_path}: empty artifact list")
            failed = True
            continue
        roots = sorted({rel.split("/", 1)[0] for rel in recorded})
        actual = {}
        for root in roots:
            p = os.path.join(model_dir, root)
            if not os.path.exists(p):
                print(f"::error::{model_dir}: pinned artifact '{root}' is MISSING")
                failed = True
                continue
            actual.update(hash_tree(p, model_dir))
        dir_failed = False
        for rel, want in sorted(recorded.items()):
            got = actual.pop(rel, None)
            if got is None:
                print(f"::error::{model_dir}: recorded artifact file '{rel}' is MISSING")
                dir_failed = True
            elif got != want:
                print(f"::error::{model_dir}: '{rel}' hash CHANGED (want {want[:12]}…, got {got[:12]}…)")
                dir_failed = True
        for rel in sorted(actual):
            print(f"::error::{model_dir}: UNLISTED file among pinned artifacts: '{rel}'")
            dir_failed = True
        if dir_failed:
            failed = True
        else:
            print(f"OK {model_dir}: {len(recorded)} artifact hashes match "
                  f"(repo {pin.get('repo')} @ {str(pin.get('revision'))[:12]}…)")
    return failed, source_pins

def compiled_hashes(app_path):
    res = os.path.join(app_path, "Contents", "Resources")
    failed = False
    hashes = {}
    for name in ["BGESmallEmbedder.mlmodelc", "BGEReranker.mlmodelc"]:
        p = os.path.join(res, name)
        if not os.path.isdir(p):
            print(f"::error::{app_path}: compiled model '{name}' missing from Contents/Resources")
            failed = True
            continue
        hashes.update(hash_tree(p, res))
    return failed, hashes

fail = False
if mode == "verify-source":
    fail, _ = verify_source()
elif mode == "record-compiled":
    # D-5 — the compiled record is only meaningful for models that PASS the
    # source-pin verification; abort otherwise.
    src_fail, source_pins = verify_source()
    if src_fail:
        print("::error::source-pin verification FAILED — not recording compiled hashes")
        fail = True
    else:
        c_fail, hashes = compiled_hashes(app)
        if c_fail:
            fail = True
        else:
            json.dump({"app": os.path.basename(app), "source_pins": source_pins,
                       "compiled": hashes},
                      open(RECORD_PATH, "w"), indent=2, sort_keys=True)
            print(f"recorded {len(hashes)} compiled-model file hashes + source pins → {RECORD_PATH}")
elif mode == "verify-compiled":
    if not os.path.isfile(RECORD_PATH):
        print(f"::error::{RECORD_PATH} missing — run --record-compiled against the archive first")
        fail = True
    else:
        record = json.load(open(RECORD_PATH))
        want = record.get("compiled", {})
        c_fail, hashes = compiled_hashes(app)
        if c_fail:
            fail = True
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
        # Bind back to the sources when they are present on this Mac.
        pins = record.get("source_pins", {})
        if pins and all(os.path.isfile(os.path.join(d, os.path.basename(d) + ".MODEL_PIN.json")) for d in pins):
            for d, p in sorted(pins.items()):
                got = sha256(os.path.join(d, os.path.basename(d) + ".MODEL_PIN.json"))
                if got != p.get("pin_sha256"):
                    print(f"::error::{d}: its MODEL_PIN differs from the one the compiled record was made from")
                    fail = True
            if not fail:
                print("source pins recomputed and matched.")
        else:
            print("source pins not present on this Mac — compiled hashes only")
        if not fail:
            print(f"OK: {len(want)} compiled-model hashes match {app}")

sys.exit(1 if fail else 0)
PY
