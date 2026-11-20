import PDFKit
import UIKit

/// Works in "display space": the page as you see it (rotation applied),
/// origin top-left, units are PDF points.
enum PageRenderer {
    static func rotation(_ page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    static func displaySize(_ page: PDFPage) -> CGSize {
        let b = page.bounds(for: .cropBox)
        return rotation(page) % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
    }

    /// Normalised display point (0...1, top-left) → page space point.
    static func pagePoint(_ p: CGPoint, on page: PDFPage) -> CGPoint {
        let u = p.x, v = p.y
        var x = u, y = v
        switch rotation(page) {
        case 90: x = v; y = 1 - u
        case 180: x = 1 - u; y = 1 - v
        case 270: x = 1 - v; y = u
        default: break
        }
        let b = page.bounds(for: .cropBox)
        return CGPoint(x: b.minX + x * b.width, y: b.maxY - y * b.height)
    }

    /// Page space point → normalised display point.
    static func displayPoint(_ p: CGPoint, on page: PDFPage) -> CGPoint {
        let b = page.bounds(for: .cropBox)
        let x = (p.x - b.minX) / b.width
        let y = (b.maxY - p.y) / b.height
        switch rotation(page) {
        case 90: return CGPoint(x: 1 - y, y: x)
        case 180: return CGPoint(x: 1 - x, y: 1 - y)
        case 270: return CGPoint(x: y, y: 1 - x)
        default: return CGPoint(x: x, y: y)
        }
    }

    static func pageRect(fromDisplay r: CGRect, on page: PDFPage) -> CGRect {
        let a = pagePoint(CGPoint(x: r.minX, y: r.minY), on: page)
        let b = pagePoint(CGPoint(x: r.maxX, y: r.maxY), on: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func displayRect(fromPage r: CGRect, on page: PDFPage) -> CGRect {
        let a = displayPoint(CGPoint(x: r.minX, y: r.minY), on: page)
        let b = displayPoint(CGPoint(x: r.maxX, y: r.maxY), on: page)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Draws the page's own content into a context whose origin is top-left (UIKit style).
    static func drawPage(_ page: PDFPage, in ctx: CGContext, size: CGSize) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let natural = displaySize(page)
        ctx.scaleBy(x: size.width / natural.width, y: size.height / natural.height)
        if let cg = page.pageRef {
            // Core Graphics' drawing transform handles the page rotation and crop box offset.
            ctx.concatenate(cg.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true))
            ctx.clip(to: cg.getBoxRect(.cropBox))
            ctx.drawPDFPage(cg)
            // Filled form fields, stamps and comments drawn on top, like a viewer shows them.
            for a in page.annotations where a.shouldDisplay && a.type != "Link" && a.type != "Popup" {
                a.draw(with: .cropBox, in: ctx)
            }
        } else {
            ctx.concatenate(page.transform(for: .cropBox))
            page.draw(with: .cropBox, to: ctx)
        }
        ctx.restoreGState()
    }

    /// Renders a page to a bitmap, `width` in pixels.
    static func image(_ page: PDFPage, width: CGFloat) -> UIImage {
        let natural = displaySize(page)
        let size = CGSize(width: width, height: (width * natural.height / natural.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: size))
            drawPage(page, in: c.cgContext, size: size)
        }
    }

    static func image(_ page: PDFPage, dpi: CGFloat) -> UIImage {
        image(page, width: (displaySize(page).width * dpi / 72).rounded())
    }

    /// Rebuilds a document page by page, keeping the original vector content,
    /// and lets the caller draw extra things above (or below) each page.
    static func render(_ doc: PDFDocument,
                       progress: ProgressReporter? = nil,
                       label: String = "Working",
                       below: ((Int, CGContext, CGSize) -> Void)? = nil,
                       above: ((Int, CGContext, CGSize) -> Void)? = nil,
                       replace: ((Int, CGSize) -> UIImage?)? = nil,
                       extra: ((Int, CGContext, CGSize) -> Void)? = nil) -> Data {
        let first = doc.page(at: 0).map(displaySize) ?? CGSize(width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first))
        return renderer.pdfData { c in
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                progress?(Double(i) / Double(max(doc.pageCount, 1)), "\(label) page \(i + 1) of \(doc.pageCount)")
                let size = displaySize(page)
                c.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                let ctx = c.cgContext
                UIColor.white.setFill()
                autoreleasepool {
                    if let img = replace?(i, size) {
                        img.draw(in: CGRect(origin: .zero, size: size))
                    } else {
                        below?(i, ctx, size)
                        drawPage(page, in: ctx, size: size)
                    }
                    above?(i, ctx, size)
                    extra?(i, ctx, size)
                }
            }
        }
    }
}
