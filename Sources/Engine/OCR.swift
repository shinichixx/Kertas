import UIKit
import Vision
import PDFKit

enum OCR {
    struct Line {
        let text: String
        /// Normalised, origin top-left.
        let box: CGRect
    }

    static func recognize(_ image: UIImage) -> [Line] {
        guard let cg = image.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        return (req.results ?? []).compactMap { obs in
            guard let c = obs.topCandidates(1).first else { return nil }
            let b = obs.boundingBox
            return Line(text: c.string, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
    }

    static func text(of lines: [Line]) -> String {
        // Group by rows so the text reads top to bottom.
        let sorted = lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5 { return a.box.minX < b.box.minX }
            return a.box.midY < b.box.midY
        }
        return sorted.map(\.text).joined(separator: "\n")
    }

    /// Draws recognised text invisibly over a page so it can be searched, selected and copied.
    static func drawInvisible(_ lines: [Line], in ctx: CGContext, size: CGSize) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        for line in lines {
            let rect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                              width: line.box.width * size.width, height: line.box.height * size.height)
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = UIFont.systemFont(ofSize: max(rect.height * 0.82, 1))
            let attr = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: UIColor.clear])
            let w = attr.size().width
            guard w > 0 else { continue }
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / w, y: 1)
            attr.draw(at: .zero)
            ctx.restoreGState()
        }
    }

    /// Image-only pages become image + hidden text layer. Pages that already have text are kept as they are.
    static func searchable(_ doc: PDFDocument, dpi: CGFloat = 200, force: Bool = false, progress: ProgressReporter?) -> (Data, Int) {
        var done = 0
        let data = PageRenderer.render(doc, progress: progress, label: "Reading text on", extra: { i, ctx, size in
            guard let page = doc.page(at: i) else { return }
            let hasText = !(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText && !force { return }
            let img = PageRenderer.image(page, dpi: dpi)
            let lines = recognize(img)
            if !lines.isEmpty { done += 1 }
            drawInvisible(lines, in: ctx, size: size)
        })
        return (data, done)
    }

    /// Text for a document, running OCR on pages that are only images.
    static func documentText(_ doc: PDFDocument, progress: ProgressReporter?) -> [String] {
        (0..<doc.pageCount).map { i in
            guard let page = doc.page(at: i) else { return "" }
            let t = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            progress?(Double(i) / Double(max(doc.pageCount, 1)), "Reading scanned page \(i + 1)")
            return autoreleasepool { text(of: recognize(PageRenderer.image(page, dpi: 200))) }
        }
    }
}
