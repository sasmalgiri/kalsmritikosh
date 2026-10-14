//
//  ProofBundle.swift
//  Kalsmritikosh
//
//  I-1 — an answer anyone can verify WITHOUT this app. Everyone shows
//  citations; this lets a court, editor or client check them independently.
//
//  A bundle is a folder with two files:
//    bundle.json  — the question, the answer, every quoted passage (with its
//                   source and SHA-256), each source's SHA-256 as recorded at
//                   import, and an ECDSA P-256 signature by this installation's
//                   key (Secure Enclave when available).
//    verify.html  — one self-contained page that runs offline in any modern
//                   browser: it checks the signature with WebCrypto, re-hashes
//                   the source files the reader chooses, and confirms each quote
//                   appears in text-based sources.
//
//  Signed message (UTF-8, "\n"-joined) — rebuilt identically by verify.html:
//    kalsmritikosh.proof.v1
//    <question>
//    <sha256(answer)>
//    S<ref>:<source sha256 or ->      one line per source, by ref
//    Q<index>:<ref>:<sha256(quote)>   one line per quote, in order
//
//  Honest scope: proves this installation's key signed exactly these quotes and
//  hashes; it does not prove who ran the app, and quote checks inside PDFs or
//  images need the reader to compare by eye (the page says so).
//

import Foundation
import CryptoKit

public struct ProofBundle: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public let ref: Int
        public let filename: String
        public let sha256: String?
    }
    public struct Quote: Codable, Sendable {
        public let index: Int
        public let ref: Int
        public let text: String
        public let sha256: String
    }
    public struct Signature: Codable, Sendable {
        public let algorithm: String
        /// X9.63 uncompressed point, base64 (WebCrypto "raw" import).
        public let publicKey: String
        /// r||s, base64 (WebCrypto verify format).
        public let raw: String
        /// DER, base64 (for standard tools).
        public let der: String
        public let keyStore: String
    }

    public let format: String
    public let question: String
    public let answer: String
    public let generatedAt: String
    public let sources: [Source]
    public let quotes: [Quote]
    public var signature: Signature?

    public static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The exact bytes that are signed.
    public var signedMessage: Data {
        var lines = [format, question, Self.sha256Hex(answer)]
        for s in sources.sorted(by: { $0.ref < $1.ref }) { lines.append("S\(s.ref):\(s.sha256 ?? "-")") }
        for q in quotes { lines.append("Q\(q.index):\(q.ref):\(q.sha256)") }
        return Data(lines.joined(separator: "\n").utf8)
    }

    public static func build(question: String, answer: String,
                             citations: [(objectID: UUID, snippet: String)],
                             filenames: [UUID: String], hashes: [UUID: String]) -> ProofBundle {
        var refs: [UUID: Int] = [:]
        var sources: [Source] = []
        for c in citations where refs[c.objectID] == nil {
            let ref = sources.count + 1
            refs[c.objectID] = ref
            sources.append(Source(ref: ref, filename: filenames[c.objectID] ?? "Source \(ref)", sha256: hashes[c.objectID]))
        }
        let quotes = citations.enumerated().map { i, c in
            Quote(index: i + 1, ref: refs[c.objectID] ?? 0, text: c.snippet, sha256: sha256Hex(c.snippet))
        }
        return ProofBundle(format: "kalsmritikosh.proof.v1", question: question, answer: answer,
                           generatedAt: ISO8601DateFormatter().string(from: Date()),
                           sources: sources, quotes: quotes, signature: nil)
    }

    /// Sign with this installation's key; nil when no key store is available.
    public func signed() -> ProofBundle? {
        guard let key = ConformanceSigningKey.loadOrGenerateBackend(),
              let sig = try? key.signature(for: signedMessage) else { return nil }
        var copy = self
        copy.signature = Signature(algorithm: "ECDSA-P256-SHA256",
                                   publicKey: key.publicKey.x963Representation.base64EncodedString(),
                                   raw: sig.rawRepresentation.base64EncodedString(),
                                   der: sig.derRepresentation.base64EncodedString(),
                                   keyStore: key.assurance)
        return copy
    }

    /// Write bundle.json + verify.html into a new folder under `parent`.
    public func write(into parent: URL, folderName: String) throws -> URL {
        let dir = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: dir.appendingPathComponent("bundle.json"), options: .atomic)
        try Data(Self.verifierHTML.utf8).write(to: dir.appendingPathComponent("verify.html"), options: .atomic)
        return dir
    }

    // MARK: - Offline verifier page

    static let verifierHTML = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Verify a Kalsmritikosh proof bundle</title>
<style>
body{font:15px -apple-system,system-ui,sans-serif;max-width:760px;margin:32px auto;padding:0 16px;color:#222}
h1{font-size:22px}.ok{color:#137a2a}.bad{color:#b3261e}.muted{color:#666;font-size:13px}
.box{border:1px solid #ddd;border-radius:10px;padding:12px 14px;margin:12px 0}
blockquote{margin:6px 0;padding:6px 10px;border-left:3px solid #ccc;background:#fafafa}
</style></head><body>
<h1>Verify a Kalsmritikosh proof bundle</h1>
<p class="muted">Runs entirely in this browser. Nothing is uploaded. Works offline.</p>
<div class="box"><b>1.</b> Choose <code>bundle.json</code>: <input type="file" id="bundle" accept=".json"></div>
<div class="box"><b>2.</b> Optionally choose the source files to check them too: <input type="file" id="sources" multiple></div>
<div id="out"></div>
<script>
const $=s=>document.querySelector(s);let B=null;
const hex=b=>[...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join('');
const sha=async d=>hex(await crypto.subtle.digest('SHA-256',typeof d==='string'?new TextEncoder().encode(d):d));
const b64=s=>Uint8Array.from(atob(s),c=>c.charCodeAt(0));
const norm=s=>s.toLowerCase().replace(/\s+/g,' ').trim();
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function message(b){const L=[b.format,b.question,await sha(b.answer)];
 [...b.sources].sort((x,y)=>x.ref-y.ref).forEach(s=>L.push('S'+s.ref+':'+(s.sha256||'-')));
 b.quotes.forEach(q=>L.push('Q'+q.index+':'+q.ref+':'+q.sha256));return new TextEncoder().encode(L.join('\n'));}
async function render(){if(!B)return;let h='';
 let sigOK=false;try{if(B.signature){const k=await crypto.subtle.importKey('raw',b64(B.signature.publicKey),{name:'ECDSA',namedCurve:'P-256'},false,['verify']);
  sigOK=await crypto.subtle.verify({name:'ECDSA',hash:'SHA-256'},k,b64(B.signature.raw),await message(B));}}catch(e){sigOK=false}
 const fp=B.signature?(await sha(b64(B.signature.publicKey))).slice(0,16):'';
 h+=B.signature?(sigOK?`<p class="ok"><b>Signature valid.</b> Signed by key ${fp} (${esc(B.signature.keyStore)}). Any change to the question, answer, quotes or source hashes would fail this check.</p>`
  :`<p class="bad"><b>Signature FAILED.</b> The bundle was changed after signing, or the signature is not genuine.</p>`):`<p class="bad">This bundle is not signed.</p>`;
 let qOK=true;for(const q of B.quotes){if(await sha(q.text)!==q.sha256)qOK=false}
 h+=qOK?`<p class="ok">All ${B.quotes.length} quote fingerprints match their text.</p>`:`<p class="bad">A quote does not match its fingerprint.</p>`;
 h+=`<div class="box"><b>Question:</b> ${esc(B.question)}<br><b>Answer:</b> ${esc(B.answer)}<br><span class="muted">Generated ${esc(B.generatedAt)}</span></div>`;
 const files=[...($('#sources').files||[])];const byHash={};
 for(const f of files){const buf=await f.arrayBuffer();byHash[await sha(buf)]={f,text:/\.(txt|md|csv|eml|html?|json|xml|log|rtf)$/i.test(f.name)?new TextDecoder().decode(buf):null}}
 for(const s of B.sources){const m=s.sha256&&byHash[s.sha256];
  h+=`<div class="box"><b>[${s.ref}] ${esc(s.filename)}</b><br><span class="muted">SHA-256 at import: ${esc(s.sha256||'not recorded')}</span><br>`;
  h+=files.length?(m?`<span class="ok">Matches your file “${esc(m.f.name)}”.</span>`:`<span class="bad">None of the files you chose has this fingerprint.</span>`):`<span class="muted">Choose source files above to check this one.</span>`;
  for(const q of B.quotes.filter(q=>q.ref===s.ref)){let note='';
   if(m&&m.text!==null)note=norm(m.text).includes(norm(q.text))?' <span class="ok">— found in the file</span>':' <span class="bad">— not found in the file text</span>';
   else if(m)note=' <span class="muted">— this file type cannot be read here; compare by eye</span>';
   h+=`<blockquote>${esc(q.text)}${note}</blockquote>`}
  h+='</div>'}
 $('#out').innerHTML=h;}
$('#bundle').onchange=async e=>{B=JSON.parse(await e.target.files[0].text());render()};
$('#sources').onchange=render;
</script></body></html>
"""#
}
