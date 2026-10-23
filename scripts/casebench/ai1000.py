#!/usr/bin/env python3
"""Case bench — the AI-1000 set: 1,000 real cases spread across subjects, each delivered in the
document types an investigation actually receives, for a run with Apple's on-device model.

Subjects (strata):
  NTSB  300 — decade × fatal/non-fatal × airplane/rotorcraft/other
  OSHA  300 — the accident's first keyword (fall, amputation, electrocution, …) × fatal
  Court 400 — persona (lawyer, compliance, forensic, SIU, genealogist) × reporter (federal
              appellate, district, state courts) × decade

Document types (profiles, rotated within each stratum so every subject meets every type):
  txt, pdf (text), scan (image-only PDF: OCR), docx, doc (legacy Word), rtf, html,
  xlsx (tabular records only), eml (cover email with the report attached as PDF),
  png (photo of a page: OCR), zip (a bundle), mbox (an email thread), mixed (scanned report +
  spreadsheet record + cover email)

Usage: ai1000.py --ntsb-osha SRC --cap CASES --out OUT [--render BIN]
Every case keeps its truth questions; a value that the chosen type cannot carry (a page photo
holds only page 1) is re-marked in_docs=false, so refusing it is the right answer.
"""
import argparse, csv, email.message, email.utils, glob, io, json, mailbox, os, random, re, shutil, subprocess, sys, zipfile
from collections import defaultdict
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import value_in  # noqa: E402

PROFILES = ["txt", "pdf", "scan", "docx", "doc", "rtf", "html", "xlsx", "eml", "png", "zip", "mbox", "mixed"]
TABULAR = ("injury-record.txt", "report-page-1.txt")

def truth_lines(root):
    for t in sorted(glob.glob(os.path.join(root, "**", "truth.jsonl"), recursive=True)):
        shard = os.path.dirname(t)
        for line in open(t):
            r = json.loads(line)
            folder = os.path.join(shard, r["case"])
            if os.path.isdir(folder):
                yield r, folder

def read_docs(folder):
    return {f: open(os.path.join(folder, f), encoding="utf-8", errors="replace").read()
            for f in sorted(os.listdir(folder)) if not f.startswith(".")}

def year_of(r):
    for q in r["questions"]:
        if "date" in q.get("expect", {}): return int(q["expect"]["date"][:4])
    return 0

def stratum(source, r, docs):
    text = "\n".join(docs.values())
    decade = f"{year_of(r) // 10 * 10}s"
    if source == "ntsb":
        fatal = any(q["id"] == "fatal" for q in r["questions"])
        kind = "rotorcraft" if re.search(r"(?i)helicopter|rotorcraft|gyro", text) else \
               ("other" if re.search(r"(?i)balloon|glider|ultralight|gyroplane", text) else "airplane")
        return f"ntsb/{decade}/{'fatal' if fatal else 'nonfatal'}/{kind}"
    if source == "osha":
        m = re.search(r"Keywords: ([^,\n]+)", text)
        fatal = any(q["id"] == "fatal" for q in r["questions"])
        return f"osha/{(m.group(1).strip().lower() if m else 'none')}/{'fatal' if fatal else 'nonfatal'}"
    reporter = r["case"].rsplit("-", 2)[0]
    return f"court/{r.get('persona', '?')}/{reporter}/{decade}"

def sample(pool, n, rng):
    """Round-robin over strata so the rarest subjects are taken first."""
    by = defaultdict(list)
    for item in pool: by[item[0]].append(item)
    for v in by.values(): rng.shuffle(v)
    keys = sorted(by, key=lambda k: len(by[k]))
    out = []
    while len(out) < n and any(by.values()):
        for k in keys:
            if by[k] and len(out) < n: out.append(by[k].pop())
    return out

def render(bin_, mode, text, path):
    src = path + ".src.txt"
    open(src, "w").write(text)
    subprocess.run([bin_, mode, src, path], check=True)
    os.remove(src)

def textutil(fmt, text, path):
    src = path + ".src.txt"
    open(src, "w").write(text)
    subprocess.run(["textutil", "-convert", fmt, "-encoding", "UTF-8", src, "-output", path], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.remove(src)

def xml_safe(text):
    """Word and Excel files are XML: the control characters some agency exports carry can't go in."""
    return re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f]", " ", text)

def xlsx(text, path):
    from openpyxl import Workbook
    text = xml_safe(text)
    wb = Workbook(); ws = wb.active; ws.title = "Record"
    for line in text.splitlines():
        if ":" in line:
            k, v = line.split(":", 1); ws.append([k.strip(), v.strip()])
        elif line.strip():
            ws.append([line.strip()])
    wb.save(path)

def docx(text, path):
    import docx as d
    text = xml_safe(text)
    doc = d.Document()
    for para in text.split("\n"):
        doc.add_paragraph(para)
    doc.save(path)

def eml(subject, body, attachments):
    m = email.message.EmailMessage()
    m["From"] = "Case Records <records@agency.example>"; m["To"] = "Investigator <investigator@firm.example>"
    m["Subject"] = subject; m["Date"] = email.utils.formatdate(localtime=False)
    m["Message-ID"] = email.utils.make_msgid(domain="agency.example")
    m.set_content(body)
    for name, data, maintype, subtype in attachments:
        m.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
    return m

def write_case(profile, case_id, docs, out_dir, bin_):
    """Write the case's documents as `profile`; returns the text each file can carry (for in_docs)."""
    os.makedirs(out_dir, exist_ok=True)
    carried = []
    title = next(iter(docs.values())).splitlines()[0] if docs else case_id
    for name, text in docs.items():
        stem = os.path.splitext(name)[0]
        p = profile
        if p == "xlsx" and name not in TABULAR: p = "docx"
        if p == "png" and len(text) > 2500: p = "scan"   # a page photo holds one page
        if p == "txt": open(os.path.join(out_dir, name), "w").write(text)
        elif p == "pdf": render(bin_, "pdf", text, os.path.join(out_dir, stem + ".pdf"))
        elif p == "scan": render(bin_, "scan", text, os.path.join(out_dir, stem + ".pdf"))
        elif p == "png": render(bin_, "png", text, os.path.join(out_dir, stem + ".png"))
        elif p == "docx": docx(text, os.path.join(out_dir, stem + ".docx"))
        elif p == "doc": textutil("doc", text, os.path.join(out_dir, stem + ".doc"))
        elif p == "rtf": textutil("rtf", text, os.path.join(out_dir, stem + ".rtf"))
        elif p == "html": textutil("html", text, os.path.join(out_dir, stem + ".html"))
        elif p == "xlsx": xlsx(text, os.path.join(out_dir, stem + ".xlsx"))
        carried.append(text)
    if profile == "eml":
        atts = []
        for name, text in docs.items():
            pdf = os.path.join(out_dir, "_att.pdf"); render(bin_, "pdf", text, pdf)
            atts.append((os.path.splitext(name)[0] + ".pdf", open(pdf, "rb").read(), "application", "pdf")); os.remove(pdf)
        m = eml(f"Records: {title}", f"Please find attached the records for {title}.\n\nRegards,\nRecords Office", atts)
        open(os.path.join(out_dir, "records.eml"), "wb").write(bytes(m))
        carried = list(docs.values())
    elif profile == "zip":
        with zipfile.ZipFile(os.path.join(out_dir, "case-bundle.zip"), "w", zipfile.ZIP_DEFLATED) as z:
            for name, text in docs.items():
                pdf = os.path.join(out_dir, "_z.pdf"); render(bin_, "pdf", text, pdf)
                z.write(pdf, os.path.splitext(name)[0] + ".pdf"); os.remove(pdf)
        carried = list(docs.values())
    elif profile == "mbox":
        box = mailbox.mbox(os.path.join(out_dir, "thread.mbox"))
        first = eml(f"Case {title}", "Sending the case material in the next message.", [])
        box.add(first)
        for name, text in docs.items():
            box.add(eml(f"Re: Case {title} — {os.path.splitext(name)[0]}", text, []))
        box.flush(); box.close()
        carried = list(docs.values())
    elif profile == "mixed":
        names = list(docs)
        for i, name in enumerate(names):
            stem, text = os.path.splitext(name)[0], docs[name]
            if name in TABULAR: xlsx(text, os.path.join(out_dir, stem + ".xlsx"))
            elif i == 0: render(bin_, "scan", text, os.path.join(out_dir, stem + ".pdf"))
            else: docx(text, os.path.join(out_dir, stem + ".docx"))
        m = eml(f"Case file: {title}", f"Attached is the case file for {title}. Originals follow by courier.", [])
        open(os.path.join(out_dir, "cover-email.eml"), "wb").write(bytes(m))
        carried = list(docs.values())
    if profile in ("eml", "zip", "mbox", "mixed", "txt", "pdf", "scan", "docx", "doc", "rtf", "html", "xlsx"):
        return "\n".join(carried)
    # png: only what fits on the first page
    return "\n".join(t if len(t) <= 2500 else t[:2500] for t in docs.values())

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ntsb-osha", required=True); ap.add_argument("--cap", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--render", required=True)
    ap.add_argument("--seed", type=int, default=20261020); ap.add_argument("--shard-size", type=int, default=50)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    pools = {"ntsb": [], "osha": [], "court": []}
    for r, folder in truth_lines(os.path.join(a.ntsb_osha, "ntsb")):
        pools["ntsb"].append((stratum("ntsb", r, read_docs(folder)), r, folder))
    for r, folder in truth_lines(os.path.join(a.ntsb_osha, "osha-compliance")):
        pools["osha"].append((stratum("osha", r, read_docs(folder)), r, folder))
    for src in glob.glob(os.path.join(a.cap, "cap-*")):
        for r, folder in truth_lines(src):
            pools["court"].append((stratum("court", r, read_docs(folder)), r, folder))
    chosen = {"ntsb": sample(pools["ntsb"], 300, rng), "osha": sample(pools["osha"], 300, rng),
              "court": sample(pools["court"], 400, rng)}
    shutil.rmtree(a.out, ignore_errors=True)
    for source, items in chosen.items():
        counter = defaultdict(int)
        for i, (st, r, folder) in enumerate(items):
            # Rotate profiles within the stratum so every subject meets every document type.
            k = counter[st] + sum(map(ord, st)) % len(PROFILES); counter[st] += 1   # stable across runs
            profile = PROFILES[k % len(PROFILES)]
            if source == "court" and profile == "xlsx": profile = "pdf"
            shard = os.path.join(a.out, source, f"shard-{i // a.shard_size:05d}")
            carried = write_case(profile, r["case"], read_docs(folder), os.path.join(shard, r["case"]), a.render)
            for q in r["questions"]:
                if q.get("in_docs", True) and "overlap" not in q["expect"]:
                    q["in_docs"] = value_in(q["expect"], carried)[0]
            r["profile"], r["stratum"] = profile, st
            with open(os.path.join(shard, "truth.jsonl"), "a") as f: f.write(json.dumps(r) + "\n")
        print(source, len(items), "cases,", len({s for s, _, _ in items}), "strata")

if __name__ == "__main__":
    main()
