// Case bench document renderer (dev tool, not part of the app).
//
// Turns a case's plain text into the document types an investigation actually receives:
//   render pdf  IN.txt OUT.pdf    — a text PDF (selectable text, paginated US Letter)
//   render scan IN.txt OUT.pdf    — an image-only PDF (each page a 150 dpi bitmap; only OCR reads it)
//   render png  IN.txt OUT.png    — a photo of the first page (bitmap, OCR only)
//
// Build once: swiftc -O scripts/casebench/render.swift -o build/casebench-render
import AppKit
import PDFKit

let pageSize = CGSize(width: 612, height: 792)
let margin: CGFloat = 54

func pages(of text: String) -> [NSAttributedString] {
    let font = NSFont(name: "Times New Roman", size: 11) ?? NSFont.systemFont(ofSize: 11)
    let para = NSMutableParagraphStyle(); para.lineSpacing = 2
    let full = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: para, .foregroundColor: NSColor.black])
    let storage = NSTextStorage(attributedString: full)
    let layout = NSLayoutManager(); storage.addLayoutManager(layout)
    var out: [NSAttributedString] = []
    while true {
        let container = NSTextContainer(size: CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin))
        layout.addTextContainer(container)
        let range = layout.characterRange(forGlyphRange: layout.glyphRange(for: container), actualGlyphRange: nil)
        if range.length == 0 { break }
        out.append(full.attributedSubstring(from: range))
        if NSMaxRange(range) >= full.length { break }
    }
    return out.isEmpty ? [full] : out
}

func draw(_ page: NSAttributedString, in ctx: CGContext) {
    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(origin: .zero, size: pageSize))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    page.draw(with: CGRect(x: margin, y: margin, width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin),
              options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
}

func bitmap(_ page: NSAttributedString, dpi: CGFloat = 150) -> CGImage? {
    let scale = dpi / 72
    let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    draw(page, in: ctx)
    return ctx.makeImage()
}

let args = CommandLine.arguments
guard args.count == 4, let text = try? String(contentsOfFile: args[2], encoding: .utf8) else {
    FileHandle.standardError.write("usage: render pdf|scan|png IN.txt OUT\n".data(using: .utf8)!); exit(2)
}
let out = URL(fileURLWithPath: args[3])
switch args[1] {
case "pdf":
    var box = CGRect(origin: .zero, size: pageSize)
    guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { exit(1) }
    for p in pages(of: text) { ctx.beginPDFPage(nil); draw(p, in: ctx); ctx.endPDFPage() }
    ctx.closePDF()
case "scan":
    let doc = PDFDocument()
    for (i, p) in pages(of: text).enumerated() {
        guard let img = bitmap(p), let page = PDFPage(image: NSImage(cgImage: img, size: pageSize)) else { exit(1) }
        doc.insert(page, at: i)
    }
    guard doc.write(to: out) else { exit(1) }
case "png":
    guard let img = bitmap(pages(of: text)[0]),
          let data = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { exit(1) }
    try data.write(to: out)
default:
    exit(2)
}
