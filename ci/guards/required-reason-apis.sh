#!/usr/bin/env bash
# RC-1 guard: every required-reason API family the app's code USES must be
# DECLARED in PrivacyInfo.xcprivacy. Static and direction-correct (code →
# declaration); over-declaration is allowed, silent new use is not.
set -uo pipefail
MANIFEST="Kalsmritikosh/PrivacyInfo.xcprivacy"
SRC="Kalsmritikosh"
FAIL=0

if [ ! -f "$MANIFEST" ]; then
  echo "::error::Required-reason guard: $MANIFEST not found"
  exit 1
fi

check_family () {
  local family="$1"; local pattern="$2"
  local uses
  uses=$(grep -rln "$pattern" "$SRC" --include="*.swift" 2>/dev/null | head -3 || true)
  if [ -n "$uses" ] && ! grep -q "$family" "$MANIFEST"; then
    echo "::error::Required-reason API family $family is USED but not declared in PrivacyInfo.xcprivacy. Uses:"
    echo "$uses"
    FAIL=1
  fi
}

# NSPrivacyAccessedAPICategoryFileTimestamp
check_family "NSPrivacyAccessedAPICategoryFileTimestamp" "creationDateKey\|contentModificationDateKey\|\.creationDate\|attributesOfItem"
# NSPrivacyAccessedAPICategorySystemBootTime
check_family "NSPrivacyAccessedAPICategorySystemBootTime" "systemUptime\|mach_absolute_time"
# NSPrivacyAccessedAPICategoryDiskSpace
check_family "NSPrivacyAccessedAPICategoryDiskSpace" "volumeAvailableCapacity\|systemFreeSize\|statfs"
# NSPrivacyAccessedAPICategoryUserDefaults
check_family "NSPrivacyAccessedAPICategoryUserDefaults" "UserDefaults\."

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "Required-reason APIs: every used family is declared."
