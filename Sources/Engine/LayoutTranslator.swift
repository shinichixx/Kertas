import UIKit
import PDFKit
import Vision

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
    /// Cells on the same table row share a row number; nil for normal text.
    var row: Int?
    var isColon: Bool { text.trimmingCharacters(in: .whitespaces) == ":" }

    /// True when the translation is just the original text again (names, addresses).
    var unchanged: Bool {
        guard let t = translated else { return true }
        let norm: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        return norm(t) == norm(text)
    }

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
            let segs = autoreleasepool { visualSegments(page) }
            return group(segs, page: i, pageWidth: PageRenderer.displaySize(page).width)
        }
    }

    // MARK: Finding text where it really is

    /// Positions come from the rendered page (Apple's text recognition finds each line and word
    /// where it actually appears). The words themselves come from the PDF's own text inside each
    /// box when it matches, so nothing is misread; style comes from the PDF too.
    private static func visualSegments(_ page: PDFPage) -> [Segment] {
        let size = PageRenderer.displaySize(page)
        let dpi = min(220, 3000 / max(size.width, size.height) * 72)
        let image = PageRenderer.image(page, dpi: dpi)
        guard let cg = image.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([req])
        let hasDigitalText = !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var out: [Segment] = []
        for obs in req.results ?? [] {
            guard let cand = obs.topCandidates(1).first else { continue }
            let str = cand.string
            // Word boxes inside this line.
            // Word boxes inside this line (split on spaces so tokens like ":" are kept).
            var words: [(text: String, rect: CGRect)] = []
            var idx = str.startIndex
            for token in str.split(separator: " ", omittingEmptySubsequences: true) {
                guard let r = str.range(of: token, range: idx..<str.endIndex) else { continue }
                idx = r.upperBound
                if let box = try? cand.boundingBox(for: r)?.boundingBox { words.append((String(token), toDisplay(box, size))) }
            }
            if words.isEmpty { words = [(str, toDisplay(obs.boundingBox, size))] }

            // Split the line where there's a column-sized gap.
            let lineH = words.map(\.rect.height).max() ?? 10
            var group: [(text: String, rect: CGRect)] = []
            func emit() {
                guard !group.isEmpty else { return }
                let rect = group.dropFirst().reduce(group[0].rect) { $0.union($1.rect) }
                let ocrText = group.map(\.text).joined(separator: " ")
                out.append(styled(ocrText, rect: rect, page: page, size: size, image: image, digital: hasDigitalText))
                group = []
            }
            for w in words.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                // A lone ":" is the divider of a "Label : value" row: keep it as its own cell.
                if w.text == ":" { emit(); group = [w]; emit(); continue }
                if let last = group.last, w.rect.minX - last.rect.maxX > max(lineH * 1.4, 12) { emit() }
                group.append(w)
            }
            emit()
        }
        return out
    }

    private static func toDisplay(_ box: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    /// Font size from the height of the letters, allowing for capitals, ascenders and descenders.
    private static func estimateSize(_ text: String, height: CGFloat) -> CGFloat {
        let ref = UIFont(name: "Helvetica", size: 100) ?? UIFont.systemFont(ofSize: 100)
        let asc = text.contains { "bdfhklt".contains($0) }
        let caps = text.contains { $0.isUppercase || $0.isNumber || "()/[]".contains($0) }
        let desc = text.contains { "gjpqy(),;[]".contains($0) }
        let top = asc ? ref.ascender * 0.95 : (caps ? ref.capHeight : ref.xHeight)
        let bottom = desc ? ref.descender * 0.9 : 0
        let ratio = max((top - bottom) / 100, 0.3)
        return height / ratio
    }

    private static func styled(_ ocrText: String, rect inRect: CGRect, page: PDFPage, size: CGSize, image: UIImage, digital: Bool) -> Segment {
        var rect = inRect
        var text = ocrText
        var name = "Helvetica"
        var fsize = estimateSize(ocrText, height: inRect.height)
        var bold = false, italic = false
        var color: UIColor?
        if digital {
            let norm = CGRect(x: rect.minX / size.width, y: (rect.minY + rect.height * 0.2) / size.height,
                              width: rect.width / size.width, height: rect.height * 0.6 / size.height)
            let pr = PageRenderer.pageRect(fromDisplay: norm, on: page)
            if let sel = page.selection(for: pr) {
                let digitalText = (sel.string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                if similar(digitalText, ocrText) {
                    text = digitalText
                    // The PDF knows exactly where its own text is; use that box when it agrees.
                    let n = PageRenderer.displayRect(fromPage: sel.bounds(for: page), on: page)
                    let exact = CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height)
                    let overlap = exact.intersection(inRect)
                    if !overlap.isNull, overlap.width * overlap.height > inRect.width * inRect.height * 0.5,
                       exact.width < inRect.width * 1.4, exact.height < inRect.height * 1.8 {
                        rect = exact
                    }
                }
                if let attr = sel.attributedString, attr.length > 0 {
                    let ns = attr.string as NSString
                    var k = 0
                    while k < ns.length - 1, let u = Unicode.Scalar(ns.character(at: k)), CharacterSet.whitespacesAndNewlines.contains(u) { k += 1 }
                    if let f = attr.attribute(.font, at: k, effectiveRange: nil) as? UIFont {
                        name = f.fontName
                        if f.pointSize > fsize * 0.7 && f.pointSize < fsize * 1.4 { fsize = f.pointSize }
                        bold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                    }
                    color = attr.attribute(.foregroundColor, at: k, effectiveRange: nil) as? UIColor
                }
            }
        }
        let parsed = FontLibrary.parse(name)
        bold = bold || parsed.bold
        italic = parsed.italic
        return Segment(text: text, rect: rect, fontName: name, size: fsize, bold: bold, italic: italic,
                       color: color ?? inkColour(rect, size: size, image: image))
    }

    /// Same words, ignoring case, spacing and punctuation (at least 70% of the recognised words).
    private static func similar(_ a: String, _ b: String) -> Bool {
        let wa = a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wb = b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let setA = Set(wa)
        let hits = wb.filter { setA.contains($0) }.count
        return Double(hits) / Double(wb.count) >= 0.7 && Double(wa.count) <= Double(wb.count) * 1.5 + 2
    }

    /// Darkest common colour inside the box: the ink.
    private static func inkColour(_ rect: CGRect, size: CGSize, image: UIImage) -> UIColor {
        guard let cg = image.cgImage else { return .black }
        let sx = CGFloat(cg.width) / size.width, sy = CGFloat(cg.height) / size.height
        let px = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
        guard px.width > 2, px.height > 2, let crop = cg.cropping(to: px) else { return .black }
        let w = crop.width, h = crop.height
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .black }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        var px3: [(Int, Int, Int)] = []
        for i in stride(from: 0, to: buf.count, by: 4 * 3) { px3.append((Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))) }
        let sorted = px3.sorted { $0.0 + $0.1 + $0.2 < $1.0 + $1.1 + $1.2 }
        let dark = sorted.prefix(max(1, sorted.count / 20))
        let n = Double(dark.count)
        let r = Double(dark.reduce(0) { $0 + $1.0 }) / n, g = Double(dark.reduce(0) { $0 + $1.1 }) / n, b = Double(dark.reduce(0) { $0 + $1.2 }) / n
        return UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    /// Draws every block it found, for checking what Kertas saw.
    static func boxes(_ doc: PDFDocument, blocks: [[TextBlock]]) -> Data {
        PageRenderer.render(doc, above: { i, ctx, _ in
            guard i < blocks.count else { return }
            for (n, b) in blocks[i].enumerated() {
                ctx.setStrokeColor(b.needsTranslation ? UIColor.systemBlue.cgColor : UIColor.systemGray.cgColor)
                ctx.setLineWidth(0.8)
                ctx.stroke(b.rect)
                UIGraphicsPushContext(ctx)
                NSAttributedString(string: "\(n + 1)", attributes: [.font: UIFont.systemFont(ofSize: 5), .foregroundColor: UIColor.systemRed])
                    .draw(at: CGPoint(x: b.rect.minX - 7, y: b.rect.minY))
                UIGraphicsPopContext()
            }
        })
    }

    // MARK: Grouping lines into paragraphs

    private static func group(_ input: [Segment], page: Int, pageWidth: CGFloat) -> [TextBlock] {
        // Most text on a page shares one body size; snap close guesses to it.
        var segs = input
        var counts: [CGFloat: Int] = [:]
        for s in segs { counts[(s.size * 2).rounded() / 2, default: 0] += s.text.count }
        if let body = counts.max(by: { $0.value < $1.value })?.key {
            for i in segs.indices where abs(segs[i].size - body) / body < 0.16 { segs[i].size = body }
        }
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
        var result: [TextBlock] = blocks.map { b in
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
                             justified: justified, centred: centred, translated: nil, row: nil)
        }
        // Table rows: cells that share a line get a row number.
        var rowID = 0
        for i in result.indices where result[i].row == nil && result[i].lineCount == 1 {
            let mates = result.indices.filter { j in
                j != i && result[j].lineCount == 1 && result[j].row == nil
                    && abs(result[j].rect.midY - result[i].rect.midY) < result[i].rect.height * 0.5
            }
            guard !mates.isEmpty else { continue }
            for j in [i] + mates { result[j].row = rowID }
            rowID += 1
        }
        // Left edges that should line up: snap within 3 pt to their shared position.
        let lefts = result.map(\.rect.minX).sorted()
        var clusters: [[CGFloat]] = []
        for x in lefts {
            if let last = clusters.last?.last, x - last < 3 { clusters[clusters.count - 1].append(x) } else { clusters.append([x]) }
        }
        for c in clusters where c.count > 1 {
            let target = c.sorted()[c.count / 2]
            for i in result.indices where abs(result[i].rect.minX - target) < 3 {
                let dx = target - result[i].rect.minX
                result[i].rect.origin.x = target
                result[i].rect.size.width -= dx
            }
        }
        return result
    }

    // MARK: What to send to the translator

    /// One piece of text to translate, and where the result goes back.
    struct Unit {
        var text: String
        var targets: [(page: Int, index: Int)]
        /// For table rows: split the result on ":" (colon rows) or nil for a single block.
        var colonRow: Bool
    }

    /// Whole table rows are translated together ("Position : Maintenance…") for context,
    /// then split back into their cells. Everything else is one unit per block.
    static func units(_ blocks: [[TextBlock]]) -> [Unit] {
        var out: [Unit] = []
        for p in blocks.indices {
            var doneRows = Set<Int>()
            for (i, b) in blocks[p].enumerated() {
                if let r = b.row {
                    if doneRows.contains(r) { continue }
                    doneRows.insert(r)
                    let cells = blocks[p].indices.filter { blocks[p][$0].row == r }.sorted { blocks[p][$0].rect.minX < blocks[p][$1].rect.minX }
                    let colons = cells.filter { blocks[p][$0].isColon }
                    let content = cells.filter { !blocks[p][$0].isColon }
                    guard content.contains(where: { blocks[p][$0].needsTranslation }) else { continue }
                    if colons.count == 1, content.count == 2 {
                        let text = blocks[p][content[0]].text + " : " + blocks[p][content[1]].text
                        out.append(Unit(text: text, targets: content.map { (p, $0) }, colonRow: true))
                    } else {
                        for c in content where blocks[p][c].needsTranslation {
                            out.append(Unit(text: blocks[p][c].text, targets: [(p, c)], colonRow: false))
                        }
                    }
                } else if b.needsTranslation {
                    out.append(Unit(text: b.text, targets: [(p, i)], colonRow: false))
                }
            }
        }
        return out
    }

    /// Puts a translated unit back into its block(s).
    static func apply(_ translated: String, to unit: Unit, in blocks: inout [[TextBlock]]) {
        if unit.colonRow, unit.targets.count == 2 {
            let parts = translated.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty {
                blocks[unit.targets[0].page][unit.targets[0].index].translated = parts[0]
                blocks[unit.targets[1].page][unit.targets[1].index].translated = parts[1]
                return
            }
        }
        for t in unit.targets { blocks[t.page][t.index].translated = translated }
    }

    // MARK: Writing the translation back

    static func render(_ doc: PDFDocument, blocks: [[TextBlock]], progress: ProgressReporter) -> Data {
        PageRenderer.render(doc, progress: progress, label: "Laying out", above: { i, ctx, size in
            guard i < blocks.count, let page = doc.page(at: i) else { return }
            // Text that comes back the same (names, addresses, brand lines) is left exactly as it was.
            let todo = blocks[i].filter { $0.translated != nil && !$0.unchanged }
            guard !todo.isEmpty else { return }
            let paper = PageRenderer.image(page, width: min(size.width * 2, 1600))
            let leftMargin = max(18, blocks[i].map(\.rect.minX).min() ?? 18)
            UIGraphicsPushContext(ctx)
            defer { UIGraphicsPopContext() }
            for b in todo {
                var limit = size.width - leftMargin
                // Table cells stop before the next cell on their row.
                if let r = b.row {
                    let next = blocks[i].filter { $0.row == r && $0.rect.minX > b.rect.maxX - 1 }.map(\.rect.minX).min()
                    if let n = next { limit = min(limit, n - 4) }
                }
                draw(b, in: ctx, page: size, paper: paper, rightLimit: limit)
            }
        })
    }

    private static func draw(_ b: TextBlock, in ctx: CGContext, page: CGSize, paper: UIImage, rightLimit: CGFloat) {
        guard let text = b.translated else { return }
        let parsed = FontLibrary.parse(b.fontName)
        let family = FontLibrary.shared.suggestions(for: parsed).first { $0.kind == .ready }?.family ?? "Helvetica"
        let para = NSMutableParagraphStyle()
        para.alignment = b.centred ? .center : (b.justified ? .justified : .natural)
        para.lineBreakMode = .byWordWrapping
        let lineGap = b.lineCount > 1 ? max(0, b.rect.height / CGFloat(b.lineCount) - b.size * 1.18) : 0
        para.lineSpacing = lineGap

        // Single lines grow to the right margin before the text shrinks.
        var width = b.rect.width
        var fontSize = b.size
        var attr = NSAttributedString()
        var bounds = CGRect.zero
        var usedFont = UIFont.systemFont(ofSize: fontSize)
        for attempt in 0..<12 {
            let font = FontLibrary.shared.font(family: family, bold: b.bold, italic: b.italic, size: fontSize)
            usedFont = font
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

        // The detected box starts at the top of the letters; text drawing starts at the line top.
        var origin = CGPoint(x: b.rect.minX, y: b.rect.minY - max(0, usedFont.ascender - usedFont.capHeight))
        if b.centred { origin.x = b.rect.midX - width / 2 }
        let textRect = CGRect(origin: origin, size: CGSize(width: width, height: max(bounds.height, b.rect.height)))
        let cover = b.rect.union(textRect).insetBy(dx: -1.5, dy: -1.5)
        let norm = CGRect(x: b.rect.minX / page.width, y: b.rect.minY / page.height, width: b.rect.width / page.width, height: b.rect.height / page.height)
        ColorSampler.surround(norm, in: paper).setFill()
        ctx.fill(cover)
        attr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}
