#!/usr/bin/env bash
# Case bench orchestrator: spread every shard under CASES across WORKERS parallel test hosts.
# Each worker is its own `xcodebuild test-without-building` running CaseBenchRunner over a folder
# of symlinked shards; results land in OUT (one .jsonl per shard). Finished shards are skipped,
# so re-running continues a stopped run.
#
#   scripts/casebench/run.sh CASES OUT [WORKERS=4] [NOAI=1]
#
# Needs a prior unsigned build-for-testing into build/dd (the signed, sandboxed host cannot read
# folders outside its container):
#   xcodebuild -scheme Kalsmritikosh -destination 'platform=macOS' -derivedDataPath build/dd \
#     build-for-testing CODE_SIGNING_ALLOWED=NO
set -uo pipefail
CASES=${1:?cases root}; OUT=${2:?results dir}; WORKERS=${3:-4}; NOAI=${4:-1}
WORK="$OUT/.workers"; mkdir -p "$OUT" "$WORK"
rm -rf "$WORK"/w*
i=0
while IFS= read -r truth; do
  shard=$(dirname "$truth"); src=$(basename "$(dirname "$shard")")
  name="$src-$(basename "$shard")"
  [ -f "$OUT/$name.jsonl" ] && continue
  w=$((i % WORKERS)); mkdir -p "$WORK/w$w/$src"
  ln -s "$shard" "$WORK/w$w/$src/$(basename "$shard")"
  i=$((i + 1))
done < <(find -L "$CASES" -name truth.jsonl -not -path "*/.workers/*" | sort)
echo "$i shards to run on $WORKERS workers"
pids=()
for d in "$WORK"/w*; do
  [ -d "$d" ] || continue
  n=$(basename "$d")
  TEST_RUNNER_CASEBENCH_NOAI=$NOAI TEST_RUNNER_CASEBENCH_DIR="$d" TEST_RUNNER_CASEBENCH_OUT="$OUT" \
    xcodebuild test-without-building -scheme Kalsmritikosh -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "${DD:-build/dd}" -resultBundlePath "$WORK/$n.xcresult" \
      -only-testing:KalsmritikoshTests/CaseBenchRunner > "$WORK/$n.log" 2>&1 &
  pids+=($!)
  sleep 5
done
fail=0
for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || fail=1; done
echo "done (worker failure: $fail); $(ls "$OUT"/*.jsonl 2>/dev/null | wc -l) shard results in $OUT"
exit $fail
