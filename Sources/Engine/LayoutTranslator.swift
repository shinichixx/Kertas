import UIKit
import PDFKit

/// Finds the text blocks on each page (paragraphs, headings, table cells) so a translation
/// can be written back in the same place, font, size and colour.
struct TextBlock {
    var page: Int
    /// Display space, points, origin top-left.
    var rect: CGRect
    var text: String
    var fontName: String
    var size: CGFloat
    var bold: Bool
    var italic: Bool
    var color: UIColor
    var lineCount: Int
    var justified: Bool
    var centred: Bool
    var translated: String?

    /// Numbers, emails, web addresses and codes stay as they are.
    var needsTranslation: Bool {
        let letters = text.filter { $0.isLetter }
        if letters.count < 2 { return false }
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("@") && !t.contains(" ") { return false }
        if t.lowercased().hasPrefix("www.") || t.lowercased().hasPrefix("http") { return false }
        return true
    }
}

enum LayoutTranslator {
    private struct Segment {
        var text: String
        var rect: CGRect
        var fontName: String
        var size: CGFloat
        var bold: Bool
        var italic: Bool
        var color: UIColor
    }

    static func extract(_ doc: PDFDocument, progress: ProgressReporter?) -> [[TextBlock]] {
        (0..<doc.pageCount).map { i in
            progress?(Double(i) / Double(max(doc.pageCount, 1)), "Reading the layout of page \(i + 1)")
            guard let page = doc.page(at: i) else { return [] }
            let segs = segments(page) ?? ocrSegments(page)
            return group(segs, page: i, pageWidth: PageRenderer.displaySize(page).width)
        }
    }

    // MARK: Finding text

    private static func segments(_ page: PDFPage) -> [Segment]? {
        guard let attr = page.attributedString, attr.length > 0 else { return nil }
        let ns = attr.string as NSString
        guard ns.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 else { return nil }
        let size = PageRenderer.displaySize(page)
        var out: [Segment] = []
        var cur: Segment?
        var lastRect: CGRect = .null

        func flush() {
            if var c = cur, !c.text.trimmingCharacters(in: .whitespaces).isEmpty {
                c.text = c.text.trimmingCharacters(in: .whitespaces)
                out.append(c)
            }
            cur = nil
            lastRect = .null
        }

        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 10 || ch == 13 { flush(); continue }
            let isSpace = ch == 32 || ch == 9 || ch == 160
            let b = page.characterBounds(at: i)
            if isSpace || b.width <= 0 || b.height <= 0 {
                if cur != nil { cur!.text += " " }
                continue
            }
            let n = PageRenderer.displayRect(fromPage: b, on: page)
            let r = CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height)
            let font = attr.attribute(.font, at: i, effectiveRange: nil) as? UIFont
            let color = attr.attribute(.foregroundColor, at: i, effectiveRange: nil) as? UIColor ?? .black
            let fsize = font?.pointSize ?? r.height
            if var c = cur, !lastRect.isNull {
                let sameLine = abs(r.midY - lastRect.midY) < max(r.height, lastRect.height) * 0.6
                let gap = r.minX - lastRect.maxX
                let columnGap = gap > max(fsize * 1.6, 12)
                if sameLine && !columnGap && gap > -fsize {
                    c.text += String(utf16CodeUnits: [ch], count: 1)
                    c.rect = c.rect.union(r)
                    cur = c
                    lastRect = r
                    continue
                }
                flush()
            }
            let name = font?.fontName ?? "Helvetica"
            let parsed = FontLibrary.parse(name)
            cur = Segment(text: String(utf16CodeUnits: [ch], count: 1), rect: r, fontName: name, size: fsize,
                          bold: parsed.bold || (font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false),
                          italic: parsed.italic, color: color)
            lastRect = r
        }
        flush()
        return out
    }

    /// Scanned pages: use the lines OCR reads.
    private static func ocrSegments(_ page: PDFPage) -> [Segment] {
        let size = PageRenderer.displaySize(page)
        let lines = OCR.recognize(PageRenderer.image(page, dpi: 200))
        return lines.map { l in
            let r = CGRect(x: l.box.minX * size.width, y: l.box.minY * size.height, width: l.box.width * size.width, height: l.box.height * size.height)
            return Segment(text: l.text, rect: r, fontName: "Helvetica", size: max(r.height * 0.78, 4), bold: false, italic: false,
                           color: UIColor(white: 0.12, alpha: 1))
        }
    }

    // MARK: Grouping lines into paragraphs

    private static func group(_ segs: [Segment], page: Int, pageWidth: CGFloat) -> [TextBlock] {
        let sorted = segs.sorted { a, b in
            abs(a.rect.minY - b.rect.minY) < min(a.rect.height, b.rect.height) * 0.5 ? a.rect.minX < b.rect.minX : a.rect.minY < b.rect.minY
        }
        var blocks: [(segs: [Segment], rect: CGRect)] = []
        for s in sorted {
            var placed = false
            for k in blocks.indices.reversed() {
                let b = blocks[k]
                guard let last = b.segs.last else { continue }
                let sameStyle = abs(last.size - s.size) < 0.8 && last.bold == s.bold
                let leftAligned = abs(b.rect.minX - s.rect.minX) < max(3, s.size * 0.4)
                let gap = s.rect.minY - last.rect.maxY
                let close = gap > -s.size * 0.3 && gap < s.size * 0.9
                // A line that stopped well short of the block's right edge ended its paragraph.
                let previousWasFull = last.rect.maxX > b.rect.maxX - max(s.size * 4, b.rect.width * 0.15)
                let wideEnough = b.rect.width > s.size * 12
                if sameStyle && leftAligned && close && previousWasFull && wideEnough {
                    blocks[k].segs.append(s)
                    blocks[k].rect = b.rect.union(s.rect)
                    placed = true
                    break
                }
                if s.rect.minY - b.rect.maxY > s.size * 3 { break }
            }
            if !placed { blocks.append(([s], s.rect)) }
        }
        return blocks.map { b in
            var text = ""
            for s in b.segs {
                if text.hasSuffix("-") { text.removeLast(); text += s.text } else { text += (text.isEmpty ? "" : " ") + s.text }
            }
            let first = b.segs[0]
            let full = b.segs.dropLast().filter { $0.rect.width > b.rect.width * 0.9 }.count
            let justified = b.segs.count >= 2 && full >= max(1, (b.segs.count - 1) * 2 / 3)
            let mid = b.rect.midX
            let centred = abs(mid - pageWidth / 2) < pageWidth * 0.04 && b.rect.width < pageWidth * 0.7
            return TextBlock(page: page, rect: b.rect, text: text, fontName: first.fontName, size: first.size,
                             bold: first.bold, italic: first.italic, color: first.color, lineCount: b.segs.count,
                             justified: justified, centred: centred, translated: nil)
        }
    }

    // MARK: Writing the translation back

    static func render(_ doc: PDFDocument, blocks: [[TextBlock]], progress: ProgressReporter) -> Data {
        PageRenderer.render(doc, progress: progress, label: "Laying out", above: { i, ctx, size in
            guard i < blocks.count, let page = doc.page(at: i) else { return }
            let todo = blocks[i].filter { $0.translated != nil }
            guard !todo.isEmpty else { return }
            let paper = PageRenderer.image(page, width: min(size.width * 2, 1600))
            UIGraphicsPushContext(ctx)
            defer { UIGraphicsPopContext() }
            for b in todo { draw(b, in: ctx, page: size, paper: paper) }
        })
    }

    private static func draw(_ b: TextBlock, in ctx: CGContext, page: CGSize, paper: UIImage) {
        guard let text = b.translated else { return }
        let parsed = FontLibrary.parse(b.fontName)
        let family = FontLibrary.shared.suggestions(for: parsed).first { $0.kind == .ready }?.family ?? "Helvetica"
        let para = NSMutableParagraphStyle()
        para.alignment = b.centred ? .center : (b.justified ? .justified : .natural)
        para.lineBreakMode = .byWordWrapping
        let lineGap = b.lineCount > 1 ? max(0, b.rect.height / CGFloat(b.lineCount) - b.size * 1.18) : 0
        para.lineSpacing = lineGap

        // Single lines may grow sideways a little before the text shrinks.
        let rightLimit = page.width - max(page.width - b.rect.maxX, 18)
        var width = b.rect.width
        var fontSize = b.size
        var attr = NSAttributedString()
        var bounds = CGRect.zero
        for attempt in 0..<12 {
            let font = FontLibrary.shared.font(family: family, bold: b.bold, italic: b.italic, size: fontSize)
            attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: b.color, .paragraphStyle: para])
            if b.lineCount == 1 {
                let w = attr.size().width + 1
                width = b.centred ? max(b.rect.width, w) : max(b.rect.width, min(w, rightLimit - b.rect.minX))
            }
            bounds = attr.boundingRect(with: CGSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let fitsHeight = bounds.height <= b.rect.height * 1.12 + 1
            let fitsLine = b.lineCount > 1 || bounds.height < fontSize * 1.6
            if (fitsHeight && fitsLine) || fontSize <= b.size * 0.75 || attempt == 11 { break }
            fontSize *= 0.96
        }

        var origin = CGPoint(x: b.rect.minX, y: b.rect.minY)
        if b.centred { origin.x = b.rect.midX - width / 2 }
        let textRect = CGRect(origin: origin, size: CGSize(width: width, height: max(bounds.height, b.rect.height)))
        let cover = b.rect.union(textRect).insetBy(dx: -1.5, dy: -1.5)
        let norm = CGRect(x: b.rect.minX / page.width, y: b.rect.minY / page.height, width: b.rect.width / page.width, height: b.rect.height / page.height)
        ColorSampler.surround(norm, in: paper).setFill()
        ctx.fill(cover)
        attr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}
