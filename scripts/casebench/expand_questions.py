#!/usr/bin/env python3
"""Case bench — the WIDE question set: every question an investigator could ask of a case, not
only the 3–4 fixed ones the converters write.

For each case folder under CASES (a copy is written to OUT with an extended truth.jsonl):
  1. field questions — every "Label: value" line the case's own documents state ("Product quantity:
     730,476 bottles", "Model years: 2003, 2004, 2005", "Keywords: …"), asked in plain words;
  2. rephrasings — each original question asked two other ways;
  3. yes/no checks — a true statement (expect yes) and the same statement with another case's value
     (expect no);
  4. absence traps — a field this kind of record never carries (expect an honest "not stated").
Answer keys come from the documents' own labeled lines or the original key, never from the app.

Usage: expand_questions.py CASES OUT
"""
import email, glob, json, os, random, re, shutil, subprocess, sys, tempfile, zipfile
from email import policy

random.seed(20261025)
SKIP_LABELS = {"subject", "from", "to", "date", "message-id", "mime-version", "content-type", "content-transfer-encoding",
               "content-disposition", "cc", "bcc", "sent", "regards", "note", "abstract", "summary", "findings"}
PDF_SWIFT = 'import PDFKit\nprint(PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))?.string ?? "")\n'

def file_text(path):
    low = path.lower()
    try:
        if low.endswith((".txt", ".md", ".csv")):
            return open(path, errors="ignore").read()
        if low.endswith(".pdf"):
            with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f: f.write(PDF_SWIFT)
            return subprocess.run(["swift", f.name, path], capture_output=True, text=True, timeout=120).stdout
        if low.endswith((".docx", ".doc", ".rtf", ".html", ".htm", ".odt")):
            return subprocess.run(["textutil", "-convert", "txt", "-stdout", path], capture_output=True, text=True, timeout=120).stdout
        if low.endswith(".zip"):
            out = []
            with tempfile.TemporaryDirectory() as d:
                zipfile.ZipFile(path).extractall(d)
                for root, _, names in os.walk(d):
                    for n in sorted(names): out.append(file_text(os.path.join(root, n)))
            return "\n".join(out)
        if low.endswith((".eml", ".mbox")):
            raw = open(path, "rb").read()
            msgs = [raw] if low.endswith(".eml") else [m for m in re.split(rb"\n(?=From )", raw) if m.strip()]
            out = []
            for m in msgs:
                msg = email.message_from_bytes(re.sub(rb"^From [^\n]*\n", b"", m), policy=policy.default)
                for part in msg.walk():
                    if part.is_multipart(): continue
                    name = part.get_filename()
                    payload = part.get_payload(decode=True) or b""
                    if name:
                        with tempfile.TemporaryDirectory() as d:
                            p = os.path.join(d, os.path.basename(name)); open(p, "wb").write(payload)
                            out.append(file_text(p))
                    elif part.get_content_type() == "text/plain":
                        out.append(payload.decode(errors="ignore"))
            return "\n".join(out)
    except Exception as e:
        print("  skip", path, e, file=sys.stderr)
    return ""

def case_text(folder):
    return "\n".join(file_text(os.path.join(folder, n)) for n in sorted(os.listdir(folder)))

def labeled_fields(text):
    """'Label: value' lines (and 'Label:' with the value on the next line)."""
    out, lines = {}, [l.strip() for l in text.splitlines()]
    for i, l in enumerate(lines):
        m = re.match(r"^([A-Z][A-Za-z /&()#\-]{2,40}):\s*(.*)$", l)
        if not m: continue
        label, value = m.group(1).strip(), m.group(2).strip()
        if not value and i + 1 < len(lines): value = lines[i + 1]
        if label.lower() in SKIP_LABELS or not value or len(value) > 160: continue
        if re.search(r"\b(NTSB|OSHA|FDA|NHTSA)\b.*\d{3,}", label): continue
        out.setdefault(label, value)
    return out

def field_question(label, ref):
    l = label.lower()
    if "date" in l: return f"What is the {l} for {ref}?"
    if l in ("location", "place"): return f"Where did {ref} take place?"
    if l.startswith("number of") or "count" in l: return f"What is the {l} in {ref}?"
    return f"What is the {l} for {ref}?"

def expect_for(value):
    """An answer key a sentence-length answer can be scored against."""
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value): return {"date": value}
    if len(value.split()) > 10: return {"overlap": value}
    return {"any": [value]}

REPHRASE = {
    "date": ["On what date did {k} take place?", "Give me the date for {k}."],
    "firm": ["Who is the recalling firm in {k}?", "Name the company behind {k}."],
    "class": ["How was {k} classified?", "Which class is {k}?"],
    "reason": ["What was the reason for {k}?", "What problem led to {k}?"],
    "office": ["Who announced the case {k}?", "Which office issued the release about {k}?"],
    "what": ["Summarize the case {k}.", "Describe what the documents say happened in the case {k}."],
    "court": ["What court heard {k}?", "Name the court that decided {k}."],
    "parties": ["Who are the parties to {k}?", "List the parties in {k}."],
    "docket": ["What is the case number of {k}?", "Give the docket number for {k}."],
    "author": ["Who authored the opinion in {k}?", "Which judge wrote the opinion in {k}?"],
    "outcome": ["What was the outcome of {k}?", "How was {k} decided?"],
    "cause": ["What caused the accident in {k}?", "What did the NTSB find was the probable cause of {k}?"],
    "place": ["Where did the {k} accident occur?", "In which city and state did {k} happen?"],
    "aircraft": ["What kind of aircraft was involved in {k}?", "Which aircraft was in {k}?"],
    "injured": ["How many workers were injured in {k}?", "What is the number of injured employees in {k}?"],
    "fatal": ["Was anyone killed in {k}?", "Were there fatalities in {k}?"],
    "manufacturer": ["Who manufactured the vehicles in {k}?", "Which manufacturer is {k} about?"],
    "component": ["Which component was investigated in {k}?", "What part of the vehicle is {k} about?"],
}
ABSENT = {  # fields that kind of record never states
    "fda": ["What was the lot expiry date in {k}?", "Who was the FDA investigator assigned to {k}?"],
    "nhtsa": ["How many crashes were fatal in {k}?", "Who was the NHTSA engineer on {k}?"],
    "ntsb": ["What was the pilot's medical certificate number in {k}?", "Who was the air traffic controller in {k}?"],
    "osha": ["What penalty amount was paid in {k}?", "Who was the OSHA compliance officer in {k}?"],
    "doj": ["What is the defendant's social security number in the case {k}?", "Which prison is the defendant held in for the case {k}?"],
    "court": ["What was the jury's vote count in {k}?", "What fee did the plaintiff's lawyer charge in {k}?"],
}

def ref_of(r):
    q0 = r["questions"][0]["q"] if r["questions"] else ""
    m = re.search(r"\"([^\"]+)\"", q0)
    if m: return f"\"{m.group(1)}\""
    for pat in [r"(FDA recall [A-Z]-\d+-\d{4})", r"(NHTSA investigation [A-Z]{2}\d+)", r"(investigation [A-Z]{2}\d+)",
                r"(NTSB case [A-Z0-9]+)", r"(the NTSB [A-Z0-9]+ accident)", r"(OSHA investigation \d+)",
                r"in (.+?, \d+ [A-Z][\w. ]*\d+)\??$", r"decided (.+?, \d+ [A-Z][\w. ]*\d+)\??$"]:
        m = re.search(pat, q0)
        if m: return m.group(1)
    return r.get("key", r["case"])

def family(source):
    for f in ("fda", "nhtsa", "ntsb", "osha", "doj", "court"):
        if source.startswith(f): return f
    return "doj"

def main():
    cases, out = sys.argv[1], sys.argv[2]
    shutil.rmtree(out, ignore_errors=True)
    pool = {}  # source -> label -> values (for false yes/no checks)
    work = []
    for t in sorted(glob.glob(os.path.join(cases, "*/*/truth.jsonl"))):
        for line in open(t):
            r = json.loads(line); folder = os.path.join(os.path.dirname(t), r["case"])
            if not os.path.isdir(folder): continue
            fields = labeled_fields(case_text(folder))
            work.append((t, r, folder, fields))
            for k, v in fields.items(): pool.setdefault(r["source"], {}).setdefault(k, set()).add(v)
    counts = {"original": 0, "field": 0, "rephrase": 0, "yes": 0, "no": 0, "absent": 0}
    for t, r, folder, fields in work:
        ref = ref_of(r); fam = family(r["source"]); qs = []
        for q in r["questions"]:
            qs.append(q); counts["original"] += 1
            for i, tmpl in enumerate(REPHRASE.get(q["id"], [])):
                k = ref.strip("\"") if fam in ("doj",) and "case" in tmpl else ref
                qs.append({**q, "id": f"{q['id']}~r{i+1}", "q": tmpl.format(k=k)}); counts["rephrase"] += 1
        for label, value in list(fields.items())[:14]:
            qs.append({"id": f"field:{label.lower()}", "q": field_question(label, ref), "expect": expect_for(value), "in_docs": True})
            counts["field"] += 1
            if len(value.split()) <= 6:
                qs.append({"id": f"yes:{label.lower()}", "q": f"Is the {label.lower()} for {ref} {value}?", "expect": {"yesno": True}, "in_docs": True})
                counts["yes"] += 1
                others = sorted(v for v in pool.get(r["source"], {}).get(label, set()) if v != value and v.lower() not in value.lower() and value.lower() not in v.lower())
                if others:
                    wrong = random.choice(others)
                    qs.append({"id": f"no:{label.lower()}", "q": f"Is the {label.lower()} for {ref} {wrong}?", "expect": {"yesno": False, "truth": value}, "in_docs": True})
                    counts["no"] += 1
        for tmpl in ABSENT.get(fam, []):
            qs.append({"id": "absent", "q": tmpl.format(k=ref), "expect": {"any": ["__never__"]}, "in_docs": False}); counts["absent"] += 1
        dst = os.path.join(out, os.path.relpath(os.path.dirname(t), cases))
        os.makedirs(dst, exist_ok=True)
        if not os.path.exists(os.path.join(dst, r["case"])): shutil.copytree(folder, os.path.join(dst, r["case"]))
        with open(os.path.join(dst, "truth.jsonl"), "a") as w: w.write(json.dumps({**r, "questions": qs}) + "\n")
    print(json.dumps(counts), "total", sum(counts.values()), "cases", len(work))

if __name__ == "__main__":
    main()
