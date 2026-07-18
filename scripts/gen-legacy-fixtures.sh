#!/bin/bash
# gen-legacy-fixtures.sh — regenerate the legacy Office (.doc/.xls) regression
# fixtures for the LegacyOfficeParserTests. DEV-TIME ONLY: the app never runs
# Python or textutil; these produce committed binary fixtures the Swift parsers
# are tested against.
#
#   .doc — macOS `textutil` writes a real Word 97 OLE2 binary.
#   .xls — Python `xlwt` writes a real BIFF8 workbook (pip3 install --user xlwt).
#
# Output: KalsmritikoshTests/Fixtures/LegacyOffice/{sample.doc,sample.xls}
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/KalsmritikoshTests/Fixtures/LegacyOffice"
mkdir -p "$out"
tmp="$(mktemp -d)"

# --- .doc via textutil (macOS built-in) ---
cat > "$tmp/sample.txt" <<'TXT'
Project Delta Status Report

Vendor: Supplier ABC
Total contract value: USD 1,800,000.
The first lot of 8 turbine blade assemblies is due 2024-04-15.
Granted on 2024-11-29 after the hearing.
TXT
textutil -convert doc "$tmp/sample.txt" -output "$out/sample.doc"
echo "wrote $out/sample.doc ($(wc -c < "$out/sample.doc") bytes)"

# --- .xls via xlwt ---
python3 - "$out/sample.xls" <<'PY'
import sys, xlwt
wb = xlwt.Workbook()
ws = wb.add_sheet('Delivery')
rows = [
 ["Item","Qty","UnitPrice","Total"],
 ["Turbine blade assembly", 24, 75000, 1800000],
 ["First lot", 8, 0, 540000],
 ["Vendor","Supplier ABC","",""],
]
for r,row in enumerate(rows):
    for c,val in enumerate(row):
        ws.write(r,c,val)
ws2 = wb.add_sheet('Notes')
ws2.write(0,0,"Granted 2024-11-29")
wb.save(sys.argv[1])
print("wrote", sys.argv[1])
PY

rm -rf "$tmp"
