#!/usr/bin/env bash
# W2-7 guard (owner decision 2026-10-15): the ledger is encrypted at rest with SQLCipher.
#  1. No product code imports the system SQLite module. In one process, a call bound to
#     Darwin's libsqlite3 ignores `PRAGMA key` silently — the ledger would be written in
#     plaintext — and a handle from one library used with the other corrupts memory. Tests may
#     import SQLite3 to build plaintext fixtures; product targets may not.
#  2. SQLCipher stays pinned to one exact, reviewed version (a binary target, checksum-pinned
#     by its manifest); moving it is a deliberate change to this guard.
#  3. Its BSD licence notice ships in both notices files (the licence requires it).
#  4. Boot opens the ledger only through LedgerOpener (keyed), never a bare Database(url:).
#  5. The unit-test host never boots the person's ledger.
set -uo pipefail
FAIL=0
PBX="Kalsmritikosh.xcodeproj/project.pbxproj"
PINNED="4.19.0"

HITS=$(grep -rnE '^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+SQLite3\b' \
  Kalsmritikosh KalsmritikoshViewer KalsmritikoshShare KalsmritikoshNetworkHelper 2>/dev/null || true)
if [ -n "$HITS" ]; then
  echo "::error::Ledger-encryption guard: product code imports the system SQLite3 module (use SQLCipher):"
  echo "$HITS"
  FAIL=1
fi

if ! awk '/repositoryURL = "https:\/\/github.com\/sqlcipher\/SQLCipher.swift";/,/};/' "$PBX" | grep -q "kind = exactVersion;"; then
  echo "::error::Ledger-encryption guard: SQLCipher must be pinned with exactVersion in $PBX"
  FAIL=1
fi
if ! awk '/repositoryURL = "https:\/\/github.com\/sqlcipher\/SQLCipher.swift";/,/};/' "$PBX" | grep -q "version = $PINNED;"; then
  echo "::error::Ledger-encryption guard: SQLCipher is not pinned to the reviewed version $PINNED"
  FAIL=1
fi

for f in THIRD_PARTY_NOTICES.md Kalsmritikosh/Resources/THIRD_PARTY_NOTICES.txt; do
  if ! grep -q "SQLCipher" "$f" || ! grep -q "ZETETIC" "$f"; then
    echo "::error::Ledger-encryption guard: $f must carry the SQLCipher (Zetetic LLC) licence notice"
    FAIL=1
  fi
done

if grep -nE 'Database\(url: resolvedDBURL\)' Kalsmritikosh/App/AppState.swift >/dev/null; then
  echo "::error::Ledger-encryption guard: AppState.boot opens the ledger without its key (use LedgerOpener)"
  FAIL=1
fi
if ! grep -q 'LedgerOpener.open(at: resolvedDBURL' Kalsmritikosh/App/AppState.swift; then
  echo "::error::Ledger-encryption guard: AppState.boot no longer opens the ledger through LedgerOpener"
  FAIL=1
fi

# 5. The unit-test host must never boot the person's ledger (it would convert it with the TEST
#    key — this happened once, 2026-10-16, and was repaired by hand).
if ! grep -q 'environment\["XCTestConfigurationFilePath"\] != nil { return }' Kalsmritikosh/KalsmritikoshApp.swift; then
  echo "::error::Ledger-encryption guard: KalsmritikoshApp must skip booting the real ledger under the unit-test host"
  FAIL=1
fi

[ "$FAIL" -ne 0 ] && exit 1
echo "Ledger-encryption guard clean (no system SQLite in product code, SQLCipher $PINNED pinned, notice present, keyed boot)."
