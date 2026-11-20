import SwiftUI
import PDFKit
import PencilKit

enum EditTool: String, CaseIterable, Identifiable {
    case select = "Select", editText = "Edit text", addText = "Add text", image = "Image", draw = "Draw"
    case highlight = "Highlight", whiteout = "Whiteout", note = "Note", sign = "Sign", redact = "Redact"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .select: return "hand.point.up.left"
        case .editText: return "character.cursor.ibeam"
        case .addText: return "textformat"
        case .image: return "photo.badge.plus"
        case .draw: return "pencil.tip"
        case .highlight: return "highlighter"
        case .whiteout: return "rectangle"
        case .note: return "note.text"
        case .sign: return "signature"
        case .redact: return "rectangle.fill"
        }
    }
    var hint: String {
        switch self {
        case .select: return "Tap something you added to move, resize or delete it."
        case .editText: return "Tap a line of text to change it. The font is matched for you."
        case .addText: return "Tap where the new text should go."
        case .image: return "Pick a picture, then drag it into place."
        case .draw: return "Draw with your finger."
        case .highlight: return "Drag across the text to highlight."
        case .whiteout: return "Drag to cover something with a white box."
        case .note: return "Tap to leave a note."
        case .sign: return "Pick or draw your signature, then drag it into place."
        case .redact: return "Drag over anything to black it out, or search for words."
        }
    }
}

enum EditMode { case full, sign, redact
    var tools: [EditTool] {
        switch self {
        case .full: return [.editText, .addText, .image, .draw, .highlight, .whiteout, .note, .sign, .select]
        case .sign: return [.sign, .addText, .draw, .select]
        case .redact: return [.redact, .select]
        }
    }
    var tool: Tool { switch self { case .full: return .edit; case .sign: return .sign; case .redact: return .redact } }
}

enum ItemKind { case replace, text, image, highlight, whiteout, redact, note }

struct EditItem: Identifiable {
    let id = UUID()
    var kind: ItemKind
    var page: Int
    /// Normalised to the page as displayed, origin top-left.
    var rect: CGRect
    var text = ""
    var family = "Helvetica"
    var bold = false
    var italic = false
    var size: CGFloat = 12
    var color: UIColor = .black
    var patch: UIColor = .white
    var image: UIImage?
    var detected: FontIdentity?
    var originalText = ""
}

final class EditModel: ObservableObject {
    let doc: PDFDocument
    let url: URL
    @Published var pageIndex = 0
    @Published var items: [EditItem] = []
    @Published var drawings: [Int: PKDrawing] = [:]
    @Published var canvasSizes: [Int: CGSize] = [:]
    @Published var selected: UUID?
    @Published var tool: EditTool
    @Published var pageImage: UIImage?
    @Published var inkColor: UIColor = .black
    @Published var inkWidth: CGFloat = 3
    private var history: [[EditItem]] = []

    init(doc: PDFDocument, url: URL, mode: EditMode) {
        self.doc = doc
        self.url = url
        self.tool = mode.tools[0]
        loadPage()
    }

    var page: PDFPage? { doc.page(at: pageIndex) }
    var pageSize: CGSize { page.map(PageRenderer.displaySize) ?? CGSize(width: 595, height: 842) }
    var pageItems: [EditItem] { items.filter { $0.page == pageIndex } }

    func loadPage() {
        guard let page else { return }
        pageImage = nil
        let idx = pageIndex
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PageRenderer.image(page, width: 1400)
            DispatchQueue.main.async { if self.pageIndex == idx { self.pageImage = img } }
        }
    }

    func go(_ delta: Int) {
        let n = pageIndex + delta
        guard n >= 0, n < doc.pageCount else { return }
        selected = nil
        pageIndex = n
        loadPage()
    }

    func snapshot() {
        history.append(items)
        if history.count > 50 { history.removeFirst() }
    }

    var canUndo: Bool { !history.isEmpty }

    func undo() {
        guard let last = history.popLast() else { return }
        items = last
        selected = nil
    }

    func add(_ item: EditItem) {
        snapshot()
        items.append(item)
        selected = item.id
    }

    func update(_ id: UUID, _ change: (inout EditItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    func delete(_ id: UUID) {
        snapshot()
        items.removeAll { $0.id == id }
        if selected == id { selected = nil }
    }

    /// Size of a text item's box in normalised units.
    func measure(_ item: EditItem) -> CGSize {
        let font = FontLibrary.shared.font(family: item.family, bold: item.bold, italic: item.italic, size: item.size)
        let s = NSAttributedString(string: item.text.isEmpty ? " " : item.text, attributes: [.font: font])
            .boundingRect(with: CGSize(width: 10000, height: 10000), options: [.usesLineFragmentOrigin], context: nil).size
        let ps = pageSize
        return CGSize(width: (s.width + 2) / ps.width, height: (s.height + 2) / ps.height)
    }

    func fitText(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.kind == .text else { return }
        let m = measure(item)
        update(id) { $0.rect.size = m }
    }

    /// Adds black boxes over every match of a word or phrase.
    func redactMatches(_ query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        snapshot()
        var n = 0
        for sel in doc.findString(query, withOptions: [.caseInsensitive]) {
            for page in sel.pages {
                let i = doc.index(for: page)
                let r = PageRenderer.displayRect(fromPage: sel.bounds(for: page).insetBy(dx: -1, dy: -1), on: page)
                items.append(EditItem(kind: .redact, page: i, rect: r))
                n += 1
            }
        }
        return n
    }

    // MARK: Save

    /// Ink is turned into images in light mode so black ink stays black.
    private func inkImages() -> [Int: UIImage] {
        var out: [Int: UIImage] = [:]
        for (i, d) in drawings where !d.strokes.isEmpty {
            guard let size = canvasSizes[i] else { continue }
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                out[i] = d.image(from: CGRect(origin: .zero, size: size), scale: 3)
            }
        }
        return out
    }

    func render(progress: ProgressReporter) -> Data {
        let items = self.items
        let inks = inkImages()
        let doc = self.doc
        let redactedPages = Set(items.filter { $0.kind == .redact }.map(\.page))

        let draw: (Int, CGContext, CGSize) -> Void = { i, ctx, size in
            UIGraphicsPushContext(ctx)
            for item in items where item.page == i { EditRenderer.draw(item, in: ctx, size: size) }
            if let ink = inks[i] { ink.draw(in: CGRect(origin: .zero, size: size)) }
            UIGraphicsPopContext()
        }

        var data = PageRenderer.render(doc, progress: progress, label: "Saving",
            above: { i, ctx, size in if !redactedPages.contains(i) { draw(i, ctx, size) } },
            replace: { i, size in
                guard redactedPages.contains(i), let page = doc.page(at: i) else { return nil }
                // Flatten the page into an image so the hidden text is really gone.
                let px = size.width * 200 / 72
                let scale = px / size.width
                let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
                return UIGraphicsImageRenderer(size: size, format: format).image { c in
                    UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
                    PageRenderer.drawPage(page, in: c.cgContext, size: size)
                    draw(i, c.cgContext, size)
                }
            },
            extra: { i, ctx, size in
                guard redactedPages.contains(i), let page = doc.page(at: i) else { return }
                // Put back searchable text for everything that wasn't blacked out.
                let format = UIGraphicsImageRendererFormat(); format.scale = 200 / 72; format.opaque = true
                let img = UIGraphicsImageRenderer(size: size, format: format).image { c in
                    UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
                    PageRenderer.drawPage(page, in: c.cgContext, size: size)
                    draw(i, c.cgContext, size)
                }
                OCR.drawInvisible(OCR.recognize(img), in: ctx, size: size)
            })

        // Notes become real PDF comments.
        let notes = items.filter { $0.kind == .note && !$0.text.isEmpty }
        if !notes.isEmpty, let out = PDFDocument(data: data) {
            for n in notes {
                guard let p = out.page(at: n.page) else { continue }
                let b = p.bounds(for: .mediaBox)
                let r = CGRect(x: n.rect.minX * b.width, y: b.height - n.rect.maxY * b.height, width: 20, height: 20)
                let a = PDFAnnotation(bounds: r, forType: .text, withProperties: nil)
                a.contents = n.text
                a.color = .systemYellow
                p.addAnnotation(a)
            }
            if let d = out.dataRepresentation() { data = d }
        }
        return data
    }
}

enum EditRenderer {
    static func draw(_ item: EditItem, in ctx: CGContext, size: CGSize) {
        let r = CGRect(x: item.rect.minX * size.width, y: item.rect.minY * size.height,
                       width: item.rect.width * size.width, height: item.rect.height * size.height)
        switch item.kind {
        case .replace:
            let font = FontLibrary.shared.font(family: item.family, bold: item.bold, italic: item.italic, size: item.size)
            let attr = NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: item.color])
            let textW = attr.size().width
            let patch = CGRect(x: r.minX - 1, y: r.minY - 1, width: max(r.width, textW) + 2, height: r.height + 2)
            item.patch.setFill()
            ctx.fill(patch)
            let y = r.maxY + font.descender - font.ascender
            attr.draw(at: CGPoint(x: r.minX, y: y))
        case .text:
            let font = FontLibrary.shared.font(family: item.family, bold: item.bold, italic: item.italic, size: item.size)
            let attr = NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: item.color])
            attr.draw(with: CGRect(x: r.minX + 1, y: r.minY + 1, width: 10000, height: 10000), options: [.usesLineFragmentOrigin], context: nil)
        case .image:
            item.image?.draw(in: r)
        case .highlight:
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            UIColor(red: 1, green: 0.9, blue: 0.2, alpha: 0.45).setFill()
            ctx.fill(r)
            ctx.restoreGState()
        case .whiteout:
            UIColor.white.setFill(); ctx.fill(r)
        case .redact:
            UIColor.black.setFill(); ctx.fill(r)
        case .note:
            break // saved as a real PDF comment instead
        }
    }
}
