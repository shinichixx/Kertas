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
        var sizeFromPDF = false
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
                out.append(contentsOf: styled(ocrText, rect: rect, page: page, size: size, image: image, digital: hasDigitalText))
                group = []
            }
            for var w in words.sorted(by: { $0.rect.minX < $1.rect.minX }) {
                // A lone ":" is the divider of a "Label : value" row: keep it as its own cell.
                if w.text == ":" { emit(); group = [w]; emit(); continue }
                // ":Execute" read as one word: split off the colon.
                if w.text.hasPrefix(":"), w.text.count > 1 {
                    let share = w.rect.width / CGFloat(w.text.count)
                    emit()
                    group = [(":", CGRect(x: w.rect.minX, y: w.rect.minY, width: share, height: w.rect.height))]
                    emit()
                    w = (String(w.text.dropFirst()), CGRect(x: w.rect.minX + share * 1.5, y: w.rect.minY, width: w.rect.width - share * 1.5, height: w.rect.height))
                }
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

    private static func styled(_ ocrText: String, rect inRect: CGRect, page: PDFPage, size: CGSize, image: UIImage, digital: Bool) -> [Segment] {
        var name = "Helvetica"
        var fsize = estimateSize(ocrText, height: inRect.height)
        var fromPDF = false
        var bold = false, italic = false
        var color: UIColor?
        var pieces: [(text: String, rect: CGRect)] = [(ocrText, inRect)]

        if digital {
            let norm = CGRect(x: inRect.minX / size.width, y: (inRect.minY + inRect.height * 0.2) / size.height,
                              width: inRect.width / size.width, height: inRect.height * 0.6 / size.height)
            let pr = PageRenderer.pageRect(fromDisplay: norm, on: page)
            if let sel = page.selection(for: pr) {
                let digitalText = (sel.string ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
                if similar(digitalText, ocrText) {
                    pieces = [(digitalText, inRect)]
                    if let exact = exactPieces(digitalText, near: inRect, page: page, size: size) { pieces = exact }
                }
                if let attr = sel.attributedString, attr.length > 0 {
                    let ns = attr.string as NSString
                    var k = 0
                    while k < ns.length - 1, let u = Unicode.Scalar(ns.character(at: k)), CharacterSet.whitespacesAndNewlines.contains(u) { k += 1 }
                    if let f = attr.attribute(.font, at: k, effectiveRange: nil) as? UIFont {
                        name = f.fontName
                        if f.pointSize > fsize * 0.6 && f.pointSize < fsize * 1.5 { fsize = f.pointSize; fromPDF = true }
                        bold = f.fontDescriptor.symbolicTraits.contains(.traitBold)
                    }
                    color = attr.attribute(.foregroundColor, at: k, effectiveRange: nil) as? UIColor
                }
            }
        }
        let parsed = FontLibrary.parse(name)
        bold = bold || parsed.bold
        italic = parsed.italic
        let ink = color ?? inkColour(inRect, size: size, image: image)
        return pieces.map { p in
            Segment(text: p.text, rect: p.rect, fontName: name, size: fsize, bold: bold, italic: italic, color: ink, sizeFromPDF: fromPDF)
        }
    }

    /// Finds the text in the PDF's own string and asks PDFKit for exact boxes. Also splits
    /// "Label : value" rows at a stand-alone colon, so the colon stays where it was.
    private static func exactPieces(_ text: String, near target: CGRect, page: PDFPage, size: CGSize) -> [(text: String, rect: CGRect)]? {
        guard let full = page.string, !text.isEmpty else { return nil }
        let ns = full as NSString
        let tokens = text.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !tokens.isEmpty, let re = try? NSRegularExpression(pattern: tokens.joined(separator: "\\s*")) else { return nil }
        func box(_ r: NSRange) -> CGRect? {
            guard r.length > 0, let sel = page.selection(for: r) else { return nil }
            let n = PageRenderer.displayRect(fromPage: sel.bounds(for: page), on: page)
            let rect = CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height)
            guard rect.width > 0, rect.height > 0 else { return nil }
            // Clamp to the line that was seen, in case PDFKit's box reaches into the next line.
            let top = max(rect.minY, target.minY - target.height * 0.25)
            let bottom = min(rect.maxY, target.maxY + target.height * 0.25)
            return bottom > top ? CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top) : nil
        }
        // The occurrence that sits where the text was seen on the page.
        var best: (NSRange, CGRect)?
        var bestScore: CGFloat = 0
        for m in re.matches(in: full, range: NSRange(location: 0, length: ns.length)) {
            guard let r = box(m.range) else { continue }
            let o = r.intersection(target)
            let score = o.isNull ? 0 : o.width * o.height
            if score > bestScore { bestScore = score; best = (m.range, r) }
        }
        guard let (range, rect) = best, bestScore > target.width * target.height * 0.3,
              rect.height < target.height * 1.35, abs(rect.midY - target.midY) < target.height * 0.4 else { return nil }

        // A colon with space (or nothing) before it and space after it divides a table row.
        let sub = ns.substring(with: range) as NSString
        func isSpace(_ i: Int) -> Bool {
            guard let u = Unicode.Scalar(sub.character(at: i)) else { return false }
            return CharacterSet.whitespacesAndNewlines.contains(u)
        }
        var colon = -1
        for i in 0..<sub.length where sub.character(at: i) == 58 {
            // Stand-alone divider: start of the text or a space before it ("Label : value", ":value").
            // "Telephone: +603" has a letter before the colon, so it isn't split.
            let before = i == 0 || isSpace(i - 1)
            if before && i < sub.length - 1 { colon = i; break }
        }
        guard colon >= 0 else { return [(text, rect)] }
        func trimmed(_ start: Int, _ end: Int) -> NSRange? {
            var s = start, e = end
            while s < e, isSpace(s) { s += 1 }
            while e > s, isSpace(e - 1) { e -= 1 }
            return e > s ? NSRange(location: range.location + s, length: e - s) : nil
        }
        var out: [(text: String, rect: CGRect)] = []
        if let l = trimmed(0, colon), let r = box(l) {
            out.append((ns.substring(with: l).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "), r))
        }
        if let r = box(NSRange(location: range.location + colon, length: 1)) { out.append((":", r)) }
        if let v = trimmed(colon + 1, sub.length), let r = box(v) {
            out.append((ns.substring(with: v).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "), r))
        }
        return out.count >= 2 ? out : [(text, rect)]
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
        for s in segs where s.sizeFromPDF { counts[(s.size * 2).rounded() / 2, default: 0] += s.text.count }
        if counts.isEmpty { for s in segs { counts[(s.size * 2).rounded() / 2, default: 0] += s.text.count } }
        if let body = counts.max(by: { $0.value < $1.value })?.key {
            // Only guessed sizes are snapped; sizes the PDF states are kept as they are.
            for i in segs.indices where !segs[i].sizeFromPDF && abs(segs[i].size - body) / body < 0.10 { segs[i].size = body }
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
        // Cover the original words (and any extra width), but never spill onto the next line.
        let coverX0 = min(b.rect.minX, textRect.minX), coverX1 = max(b.rect.maxX, textRect.maxX)
        let cover = CGRect(x: coverX0 - 1.5, y: b.rect.minY - 1.5, width: coverX1 - coverX0 + 3,
                           height: (b.lineCount == 1 ? b.rect.height : max(b.rect.height, min(bounds.height, b.rect.height * 1.15))) + 3)
        let norm = CGRect(x: b.rect.minX / page.width, y: b.rect.minY / page.height, width: b.rect.width / page.width, height: b.rect.height / page.height)
        ColorSampler.surround(norm, in: paper).setFill()
        ctx.fill(cover)
        attr.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}
