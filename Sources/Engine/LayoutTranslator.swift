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
        // Letters and their positions must come from the same source: page.string and
        // characterBounds share one index. (The attributed string can have extra line breaks,
        // which made positions drift in build 7.)
        guard let str = page.string, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ns = str as NSString
        let size = PageRenderer.displaySize(page)
        struct Raw { var text: String; var rect: CGRect; var start: Int; var end: Int }
        var raws: [Raw] = []
        var cur: Raw?
        var lastRect: CGRect = .null

        func flush() {
            if var c = cur, !c.text.trimmingCharacters(in: .whitespaces).isEmpty {
                c.text = c.text.trimmingCharacters(in: .whitespaces)
                raws.append(c)
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
            let approx = max(r.height * 0.85, 4)
            if var c = cur, !lastRect.isNull {
                let sameLine = abs(r.midY - lastRect.midY) < max(r.height, lastRect.height) * 0.6
                let gap = r.minX - lastRect.maxX
                let columnGap = gap > max(approx * 1.6, 12)
                if sameLine && !columnGap && gap > -approx {
                    c.text += String(utf16CodeUnits: [ch], count: 1)
                    c.rect = c.rect.union(r)
                    c.end = i
                    cur = c
                    lastRect = r
                    continue
                }
                flush()
            }
            cur = Raw(text: String(utf16CodeUnits: [ch], count: 1), rect: r, start: i, end: i)
            lastRect = r
        }
        flush()

        // Style of each piece, read from a selection of exactly those characters.
        return raws.map { raw in
            var name = "Helvetica", fsize = raw.rect.height * 0.8, color = UIColor.black, boldTrait = false
            if let sel = page.selection(for: NSRange(location: raw.start, length: raw.end - raw.start + 1)),
               let attr = sel.attributedString, attr.length > 0 {
                let s2 = attr.string as NSString
                var k = 0
                while k < s2.length - 1, let u = Unicode.Scalar(s2.character(at: k)), CharacterSet.whitespacesAndNewlines.contains(u) { k += 1 }
                if let f = attr.attribute(.font, at: k, effectiveRange: nil) as? UIFont {
                    name = f.fontName
                    fsize = f.pointSize
                    boldTrait = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                }
                if let c = attr.attribute(.foregroundColor, at: k, effectiveRange: nil) as? UIColor { color = c }
            }
            // Guard against odd size reports: the letters' own height is the truth.
            if fsize <= 1 || fsize > raw.rect.height * 2.2 || fsize < raw.rect.height * 0.45 { fsize = raw.rect.height * 0.8 }
            let parsed = FontLibrary.parse(name)
            return Segment(text: raw.text, rect: raw.rect, fontName: name, size: fsize, bold: parsed.bold || boldTrait,
                           italic: parsed.italic, color: color)
        }
    }

    /// Checks each block against the text PDFKit finds inside its box. If many don't match,
    /// the positions can't be trusted for that page.
    static func trustworthy(_ blocks: [TextBlock], page: PDFPage) -> Bool {
        let size = PageRenderer.displaySize(page)
        let checked = blocks.filter { $0.needsTranslation }
        guard !checked.isEmpty else { return true }
        var good = 0
        for b in checked {
            let norm = CGRect(x: b.rect.minX / size.width, y: b.rect.minY / size.height, width: b.rect.width / size.width, height: b.rect.height / size.height)
            let r = PageRenderer.pageRect(fromDisplay: norm, on: page).insetBy(dx: -1, dy: -1)
            let found = (page.selection(for: r)?.string ?? "").lowercased()
            let words = b.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 1 }
            if words.isEmpty { good += 1; continue }
            let hits = words.filter { found.contains($0) }.count
            if Double(hits) / Double(words.count) >= 0.7 { good += 1 }
        }
        return Double(good) / Double(checked.count) >= 0.85
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
        // The right edge of the text column: paragraph lines (except the last) reach it.
        let rights = sorted.map(\.rect.maxX).sorted()
        let textRight = rights.isEmpty ? pageWidth : rights[min(rights.count - 1, Int(Double(rights.count) * 0.95))]
        // Pieces that share a line with another piece are table cells, never paragraph lines.
        let cells: [Bool] = sorted.indices.map { i in
            sorted.indices.contains { j in
                j != i && abs(sorted[j].rect.midY - sorted[i].rect.midY) < sorted[i].rect.height * 0.5
            }
        }
        var blocks: [(segs: [Segment], rect: CGRect, cell: Bool)] = []
        for (n, s) in sorted.enumerated() {
            var placed = false
            for k in blocks.indices.reversed() {
                let b = blocks[k]
                guard let last = b.segs.last else { continue }
                let sameStyle = abs(last.size - s.size) < 0.8 && last.bold == s.bold
                let leftAligned = abs(b.rect.minX - s.rect.minX) < max(3, s.size * 0.4)
                let gap = s.rect.minY - last.rect.maxY
                let close = gap > -s.size * 0.3 && gap < s.size * 0.9
                // A line that stopped short of the text column's right edge ended its paragraph.
                let previousWasFull = last.rect.maxX > textRight - s.size * 3
                let wideEnough = b.rect.width > s.size * 12
                if sameStyle && leftAligned && close && previousWasFull && wideEnough && !cells[n] && !b.cell {
                    blocks[k].segs.append(s)
                    blocks[k].rect = b.rect.union(s.rect)
                    placed = true
                    break
                }
                if s.rect.minY - b.rect.maxY > s.size * 3 { break }
            }
            if !placed { blocks.append(([s], s.rect, cells[n])) }
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
