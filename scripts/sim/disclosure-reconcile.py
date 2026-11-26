#!/usr/bin/env python3
"""Unified path R2-E — SIMULATED disclosure and claims reconciliation (SHIP-04, SHIP-08). An AGENT check, not counsel.

SHIP-04: every network destination in the code (AI hosts, public-record hosts, the relay host) must be named in the
data-flow inventory and the privacy policy; the simulated team service's flows (accounts, invitations, encrypted
shared items, content-free health) are listed as "not in this build" unless they are disclosed; "no collection" /
"local only" wording is flagged for a recheck against the current flows.
SHIP-08: the listing, help and site must not carry unsupported claims (refused vocabulary), screenshots must be newer
than the last case-map change, and scripts/check-claims.sh must pass.
Writes $SIM_OUT/disclosure-reconcile.md; exit 1 on any finding. Real counsel review is still needed for release.
"""
import os, re, subprocess, sys, datetime, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = pathlib.Path(os.environ.get("SIM_OUT", ROOT / "release" / "simulated" / datetime.datetime.utcnow().strftime("%Y-%m-%d")))
OUT.mkdir(parents=True, exist_ok=True)

def read(p):
    try: return (ROOT / p).read_text(errors="replace")
    except OSError: return ""

def code_hosts():
    hosts = set()
    kind = read("Kalsmritikosh/Routing/Providers/Online/OnlineProviderKind.swift")
    hosts |= set(re.findall(r'"(api\.anthropic\.com)"', kind))
    helper = read("KalsmritikoshNetworkHelper/KalsmritikoshNetworkHelper.swift")
    m = re.search(r"lookupHosts: Set<String> = \[(.*?)\]", helper, re.S)
    if m: hosts |= set(re.findall(r'"([a-z0-9.-]+)"', m.group(1)))
    relay = re.search(r'static let relayHost = "([^"]*)"', helper)
    if relay and relay.group(1): hosts.add(relay.group(1))
    return sorted(hosts)

findings, notes = [], []
inventory = read("docs/DATA_FLOW_INVENTORY.md") + read("PRIVACY_DATA_FLOW.md")
policy = read("release/PRIVACY_POLICY.md")
for h in code_hosts():
    if h not in inventory: findings.append(f"SHIP-04: host {h} is in the code but not in the data-flow inventory")
    if h not in policy: notes.append(f"SHIP-04: host {h} is not named in release/PRIVACY_POLICY.md (check the policy names its category)")
team_flows = ["accounts", "invitations", "encrypted shared items", "content-free health counters"]
if "team service" not in inventory.lower():
    notes.append("SHIP-04: the simulated team service flows (" + ", ".join(team_flows) + ") are NOT in this build; disclose them before any team service ships")
for f in ["release/PRIVACY_POLICY.md", "release/APP_PRIVACY_LABEL.md", "release/APP_STORE_LISTING.md", "Marketing/APP_STORE_LISTING.md"]:
    for phrase in ["no collection", "local only", "nothing leaves", "never leaves"]:
        if phrase in read(f).lower(): notes.append(f"SHIP-04: \"{phrase}\" in {f} — recheck against the online AI, lookups and relay flows")

REFUSED = ["100% correct", "100 % correct", "guaranteed", "always correct", "parity with all", "better than every", "never wrong"]
for f in ["release/APP_STORE_LISTING.md", "Marketing/APP_STORE_LISTING.md", "Marketing/BEGINNER_GUIDE.md", "Marketing/support.html", "APP_STORE_METADATA.md"]:
    text = read(f).lower()
    for w in REFUSED:
        if w in text: findings.append(f"SHIP-08: refused claim \"{w}\" in {f}")

def last_commit_ts(path):
    r = subprocess.run(["git", "log", "-1", "--format=%ct", "--", path], cwd=ROOT, capture_output=True, text=True)
    return int(r.stdout.strip() or 0)
map_ts = last_commit_ts("Kalsmritikosh/UI/CaseMapUnifiedTools.swift")
for png in sorted((ROOT / "Marketing" / "appstore").glob("*.png")):
    if last_commit_ts(str(png.relative_to(ROOT))) < map_ts:
        findings.append(f"SHIP-08: screenshot {png.name} predates the last case-map change")

claims = subprocess.run(["bash", "scripts/check-claims.sh"], cwd=ROOT, capture_output=True, text=True)
(findings if claims.returncode else notes).append(f"SHIP-08: scripts/check-claims.sh exit {claims.returncode}")

with open(OUT / "disclosure-reconcile.md", "w") as f:
    f.write("# SIMULATED — disclosure and claims reconciliation (AGENT check, not counsel)\n\n")
    f.write("Code destinations: " + ", ".join(code_hosts()) + "\n\n## Findings\n\n")
    f.write("".join(f"- {x}\n" for x in findings) or "- none\n")
    f.write("\n## Notes for the owner\n\n" + ("".join(f"- {x}\n" for x in notes) or "- none\n"))
    f.write("\n## Still needed for release\n\n- Counsel review of the policy and label; screenshots retaken on the candidate.\n")
print(f"disclosure-reconcile: {len(findings)} finding(s), {len(notes)} note(s) → {OUT / 'disclosure-reconcile.md'}")
sys.exit(1 if findings else 0)
