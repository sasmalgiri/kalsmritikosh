//
//  ArchivalPDF.swift
//  Kalsmritikosh
//
//  ALCOA ALC-20 (DATA-30, owner 2026-11-24) — enduring. Report PDFs are written as an "archival PDF": every font the
//  page uses embedded (Quartz embeds the subsets it draws), an sRGB output intent, the document information dictionary
//  (title, author, creator, producer) and an XMP metadata packet (Dublin Core title/creator/date, the producer, the
//  creation and modification time, and a plain statement of what the file is). Nothing is encrypted and nothing is
//  linked from outside the file.
//
//  Honest limit: the app has no PDF/A validator and adds no dependency, so it does NOT claim PDF/A-2b conformance —
//  the XMP carries no pdfaid entry. Run a PDF/A validator (or convert) when a formal PDF/A-2b file is required. The
//  wording everywhere is "archival PDF (embedded fonts, XMP metadata; PDF/A-2b not verified)".
//

import Foundation
import CoreGraphics

public nonisolated enum ArchivalPDF {

    /// What the app says about these files, wherever it names the format.
    public static let statement = "Archival PDF: fonts embedded, sRGB output intent, XMP metadata; PDF/A-2b conformance is not verified by the app."

    static func escaped(_ s: String) -> String {
        var out = ""
        for c in s.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                let v = c.value
                if v == 0x9 || v == 0xA || v == 0xD || v >= 0x20 { out.unicodeScalars.append(c) }
            }
        }
        return out
    }

    /// The document information dictionary plus the sRGB output intent, for `CGContext(consumer:mediaBox:_:)`.
    public static func info(title: String, author: String) -> [CFString: Any] {
        var info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextAuthor: author,
                                     kCGPDFContextCreator: CertifiedCopy.producerName, kCGPDFContextSubject: statement]
        if let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() {
            let intent: [CFString: Any] = [kCGPDFXOutputIntentSubtype: "GTS_PDFA1",
                                           kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
                                           kCGPDFXInfo: "sRGB IEC61966-2.1",
                                           kCGPDFXDestinationOutputProfile: icc]
            info[kCGPDFContextOutputIntent] = intent
        }
        return info
    }

    /// The XMP packet (no pdfaid claim — see the header).
    public static func xmp(title: String, author: String, at date: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
           <dc:format>application/pdf</dc:format>
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">\(escaped(title))</rdf:li></rdf:Alt></dc:title>
           <dc:creator><rdf:Seq><rdf:li>\(escaped(author))</rdf:li></rdf:Seq></dc:creator>
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">\(escaped(statement))</rdf:li></rdf:Alt></dc:description>
           <xmp:CreateDate>\(iso)</xmp:CreateDate>
           <xmp:ModifyDate>\(iso)</xmp:ModifyDate>
           <xmp:MetadataDate>\(iso)</xmp:MetadataDate>
           <xmp:CreatorTool>\(escaped(CertifiedCopy.producerName))</xmp:CreatorTool>
           <pdf:Producer>\(escaped(CertifiedCopy.producerName))</pdf:Producer>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        return Data(packet.utf8)
    }

    /// A PDF context with the archival information and XMP already added. nil when Quartz could not make one.
    public static func context(into out: NSMutableData, mediaBox: inout CGRect, title: String, author: String) -> CGContext? {
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, info(title: title, author: author) as CFDictionary) else { return nil }
        ctx.addDocumentMetadata(xmp(title: title, author: author) as CFData)
        return ctx
    }

    /// What a written file shows of the archival properties (for tests and the integrity report).
    public struct Check: Sendable, Equatable {
        public let hasXMP: Bool
        public let fontsEmbedded: Bool
        public let outputIntent: Bool
        public let encrypted: Bool
        public var archival: Bool { hasXMP && fontsEmbedded && outputIntent && !encrypted }
    }

    public static func check(_ data: Data) -> Check {
        // The PDF's own bytes (Quartz writes the XMP stream and the font dictionaries uncompressed enough to find).
        let raw = String(decoding: data, as: UTF8.self)
        let latin = String(data: data, encoding: .isoLatin1) ?? raw
        func has(_ s: String) -> Bool { latin.contains(s) }
        return Check(hasXMP: has("x:xmpmeta") || has("/Metadata"),
                     fontsEmbedded: has("/FontFile"),
                     outputIntent: has("/OutputIntent"),
                     encrypted: has("/Encrypt"))
    }
}
