import PDFKit
import UIKit
import CoreText

enum PDFOps {
    // MARK: Organise

    static func merge(_ urls: [URL], progress: ProgressReporter) throws -> PDFDocument {
        let out = PDFDocument()
        for (n, url) in urls.enumerated() {
            progress(Double(n) / Double(urls.count), "Adding \(url.lastPathComponent)")
            if ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased()) {
                if let img = UIImage(contentsOfFile: url.path), let page = PDFPage(image: img.normalized(maxSide: 3000)) {
                    out.insert(page, at: out.pageCount)
                }
                continue
            }
            let doc = try PDFLoader.open(url)
            for i in 0..<doc.pageCount {
                if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
            }
        }
        guard out.pageCount > 0 else { throw KertasError("Nothing to merge.") }
        return out
    }

    static func subset(_ doc: PDFDocument, pages: [Int]) -> PDFDocument {
        let out = PDFDocument()
        for i in pages {
            if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
        }
        return out
    }

    // MARK: Compress

    enum CompressLevel: String, CaseIterable, Identifiable {
        case less = "Less", recommended = "Recommended", extreme = "Extreme"
        var id: String { rawValue }
        var note: String {
            switch self {
            case .less: return "Good quality, small saving. Text stays sharp."
            case .recommended: return "Good quality, good saving. Text stays sharp."
            case .extreme: return "Smallest file. Pages become images with hidden searchable text."
            }
        }
    }

    static func compress(_ url: URL, level: CompressLevel, progress: ProgressReporter) throws -> Data {
        let doc = try PDFLoader.open(url)
        switch level {
        case .less:
            progress(nil, "Recompressing images")
            guard let d = doc.dataRepresentation(options: [PDFDocumentWriteOption.saveImagesAsJPEGOption: true]) else { throw KertasError("Couldn't compress this PDF.") }
            return d
        case .recommended:
            progress(nil, "Recompressing images")
            guard let d = doc.dataRepresentation(options: [PDFDocumentWriteOption.saveImagesAsJPEGOption: true,
                                                           PDFDocumentWriteOption.optimizeImagesForScreenOption: true]) else { throw KertasError("Couldn't compress this PDF.") }
            return d
        case .extreme:
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
            return renderer.pdfData { c in
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    progress(Double(i) / Double(doc.pageCount), "Squeezing page \(i + 1) of \(doc.pageCount)")
                    autoreleasepool {
                        let size = PageRenderer.displaySize(page)
                        c.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                        let img = PageRenderer.image(page, dpi: 110)
                        if let jpg = img.jpegData(compressionQuality: 0.45), let small = UIImage(data: jpg) {
                            small.draw(in: CGRect(origin: .zero, size: size))
                        }
                        let lines = OCR.recognize(PageRenderer.image(page, dpi: 200))
                        OCR.drawInvisible(lines, in: c.cgContext, size: size)
                    }
                }
            }
        }
    }

    // MARK: Repair

    static func repair(_ url: URL, progress: ProgressReporter) throws -> (Data, Int) {
        progress(nil, "Checking the file")
        var data = try Data(contentsOf: url)
        if PDFDocument(data: data) == nil {
            // Trim junk before %PDF and after the last %%EOF, a common cause of damage.
            if let start = data.range(of: Data("%PDF".utf8)) { data = data.subdata(in: start.lowerBound..<data.endIndex) }
            if let end = data.range(of: Data("%%EOF".utf8), options: .backwards) { data = data.subdata(in: data.startIndex..<end.upperBound) }
        }
        guard let provider = CGDataProvider(data: data as CFData), let cg = CGPDFDocument(provider), cg.numberOfPages > 0 else {
            throw KertasError("This file is too damaged to recover.")
        }
        if cg.isEncrypted && !cg.isUnlocked { throw KertasError("This PDF has a password. Unlock it first.") }
        let count = cg.numberOfPages
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        var recovered = 0
        let out = renderer.pdfData { c in
            for n in 1...count {
                guard let page = cg.page(at: n) else { continue }
                progress(Double(n) / Double(count), "Rebuilding page \(n) of \(count)")
                let box = page.getBoxRect(.cropBox)
                let angle = ((Int(page.rotationAngle) % 360) + 360) % 360
                let size = angle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
                c.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                let ctx = c.cgContext
                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
                ctx.drawPDFPage(page)
                ctx.restoreGState()
                recovered += 1
            }
        }
        return (out, recovered)
    }

    // MARK: Security

    static func protect(_ url: URL, password: String) throws -> Data {
        let doc = try PDFLoader.open(url)
        let opts: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        let tmp = FileStore.uniqueURL(base: "locked", ext: "pdf", in: FileStore.inbox)
        guard doc.write(to: tmp, withOptions: opts) else { throw KertasError("Couldn't lock this PDF.") }
        return try Data(contentsOf: tmp)
    }

    static func unlock(_ url: URL, password: String) throws -> Data {
        guard let doc = PDFDocument(url: url) else { throw KertasError("This file can't be opened as a PDF.") }
        if doc.isLocked && !doc.unlock(withPassword: password) { throw KertasError("That password isn't right.") }
        let fresh = PDFDocument()
        for i in 0..<doc.pageCount {
            if let p = doc.page(at: i)?.copy() as? PDFPage { fresh.insert(p, at: fresh.pageCount) }
        }
        if let d = fresh.dataRepresentation(), let check = PDFDocument(data: d), !check.isEncrypted { return d }
        return PageRenderer.render(doc)
    }

    // MARK: Images

    enum PageFit: String, CaseIterable, Identifiable {
        case fit = "Same as image", a4 = "A4", letter = "Letter"
        var id: String { rawValue }
    }

    enum Margin: String, CaseIterable, Identifiable {
        case none = "None", small = "Small", big = "Big"
        var id: String { rawValue }
        var points: CGFloat { self == .none ? 0 : (self == .small ? 20 : 48) }
    }

    static func imagesToPDF(_ images: [UIImage], fit: PageFit, margin: Margin, progress: ProgressReporter?) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        return renderer.pdfData { c in
            for (i, raw) in images.enumerated() {
                progress?(Double(i) / Double(images.count), "Adding image \(i + 1) of \(images.count)")
                autoreleasepool {
                    let img = raw.normalized(maxSide: 3000)
                    let landscape = img.size.width > img.size.height
                    var pageSize: CGSize
                    switch fit {
                    case .fit: pageSize = CGSize(width: 595, height: 595 * img.size.height / img.size.width)
                    case .a4: pageSize = CGSize(width: 595.2, height: 841.8)
                    case .letter: pageSize = CGSize(width: 612, height: 792)
                    }
                    if fit != .fit && landscape { pageSize = CGSize(width: pageSize.height, height: pageSize.width) }
                    let m = margin.points
                    if fit == .fit { pageSize = CGSize(width: pageSize.width + 2 * m, height: pageSize.height + 2 * m) }
                    c.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                    let area = CGRect(origin: .zero, size: pageSize).insetBy(dx: m, dy: m)
                    let s = min(area.width / img.size.width, area.height / img.size.height)
                    let drawSize = CGSize(width: img.size.width * s, height: img.size.height * s)
                    let rect = CGRect(x: area.midX - drawSize.width / 2, y: area.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
                    if let jpg = img.jpegData(compressionQuality: 0.85), let j = UIImage(data: jpg) { j.draw(in: rect) } else { img.draw(in: rect) }
                }
            }
        }
    }

    static func pdfToImages(_ url: URL, dpi: CGFloat, progress: ProgressReporter) throws -> URL {
        let doc = try PDFLoader.open(url)
        let folder = FileStore.folder(named: FileStore.baseName(url) + " images")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            progress(Double(i) / Double(doc.pageCount), "Saving page \(i + 1) of \(doc.pageCount)")
            try autoreleasepool {
                let img = PageRenderer.image(page, dpi: dpi)
                guard let data = img.jpegData(compressionQuality: 0.9) else { return }
                try data.write(to: folder.appendingPathComponent(String(format: "Page %03d.jpg", i + 1)))
            }
        }
        FileStore.notify()
        return folder
    }

    /// Pulls the embedded pictures out of a PDF.
    static func extractImages(_ url: URL, progress: ProgressReporter) throws -> (URL, Int) {
        guard let cg = CGPDFDocument(url as CFURL) else { throw KertasError("This file can't be opened as a PDF.") }
        if cg.isEncrypted && !cg.isUnlocked { throw KertasError("This PDF has a password. Unlock it first.") }
        let folder = FileStore.folder(named: FileStore.baseName(url) + " pictures")
        var seen = Set<Int>()
        var count = 0
        let pages = cg.numberOfPages
        for n in 1...max(pages, 1) {
            guard let page = cg.page(at: n), let dict = page.dictionary else { continue }
            progress(Double(n) / Double(pages), "Looking in page \(n) of \(pages)")
            var res: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let resources = res else { continue }
            collectImages(resources, depth: 0) { image, jpeg in
                let key = (jpeg?.hashValue ?? 0) ^ Int(image.size.width * 1000 + image.size.height)
                if seen.contains(key) { return }
                seen.insert(key)
                count += 1
                let name = String(format: "Picture %03d", count)
                if let jpeg { try? jpeg.write(to: folder.appendingPathComponent(name + ".jpg")) }
                else if let png = image.pngData() { try? png.write(to: folder.appendingPathComponent(name + ".png")) }
            }
        }
        FileStore.notify()
        if count == 0 { try? FileManager.default.removeItem(at: folder); throw KertasError("No pictures were found in this PDF.") }
        return (folder, count)
    }

    private static func collectImages(_ resources: CGPDFDictionaryRef, depth: Int, found: (UIImage, Data?) -> Void) {
        var xobj: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobj), let xobjects = xobj else { return }
        var streams: [CGPDFStreamRef] = []
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?
            if CGPDFObjectGetValue(object, .stream, &stream), let s = stream { streams.append(s) }
            return true
        }, nil)
        for stream in streams {
            guard let sdict = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(sdict, "Subtype", &subtype), let st = subtype else { continue }
            let kind = String(cString: st)
            if kind == "Form", depth < 3 {
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(sdict, "Resources", &inner), let r = inner { collectImages(r, depth: depth + 1, found: found) }
                continue
            }
            guard kind == "Image" else { continue }
            var w: CGPDFInteger = 0, h: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(sdict, "Width", &w)
            CGPDFDictionaryGetInteger(sdict, "Height", &h)
            if w < 40 || h < 40 { continue }
            var format = CGPDFDataFormat.raw
            guard let cfData = CGPDFStreamCopyData(stream, &format) else { continue }
            let data = cfData as Data
            if format == .jpegEncoded || format == .JPEG2000 {
                if let img = UIImage(data: data) { found(img, format == .jpegEncoded ? data : nil) }
                continue
            }
            var bpc: CGPDFInteger = 8
            CGPDFDictionaryGetInteger(sdict, "BitsPerComponent", &bpc)
            guard bpc == 8 else { continue }
            let comps = components(sdict)
            guard comps > 0, data.count >= Int(w * h) * comps else { continue }
            let space: CGColorSpace = comps == 1 ? CGColorSpaceCreateDeviceGray() : (comps == 4 ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceRGB())
            guard let provider = CGDataProvider(data: data as CFData),
                  let cgimg = CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 8 * comps,
                                      bytesPerRow: Int(w) * comps, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { continue }
            var img = UIImage(cgImage: cgimg)
            if comps == 4 {
                // CMYK → RGB so it saves properly.
                img = UIGraphicsImageRenderer(size: img.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { _ in img.draw(at: .zero) }
            }
            found(img, nil)
        }
    }

    private static func components(_ sdict: CGPDFDictionaryRef) -> Int {
        var name: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(sdict, "ColorSpace", &name), let n = name {
            switch String(cString: n) {
            case "DeviceGray", "CalGray": return 1
            case "DeviceRGB", "CalRGB": return 3
            case "DeviceCMYK": return 4
            default: return 0
            }
        }
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(sdict, "ColorSpace", &arr), let a = arr {
            var first: UnsafePointer<Int8>?
            if CGPDFArrayGetName(a, 0, &first), let f = first, String(cString: f) == "ICCBased" {
                var icc: CGPDFStreamRef?
                if CGPDFArrayGetStream(a, 1, &icc), let s = icc, let d = CGPDFStreamGetDictionary(s) {
                    var n: CGPDFInteger = 0
                    if CGPDFDictionaryGetInteger(d, "N", &n) { return Int(n) }
                }
            }
        }
        return 0
    }

    // MARK: Text

    static func plainText(_ doc: PDFDocument, progress: ProgressReporter) -> String {
        let pages = OCR.documentText(doc, progress: progress)
        return pages.enumerated().map { "— Page \($0.offset + 1) —\n\($0.element)" }.joined(separator: "\n\n")
    }

    static func markdown(_ doc: PDFDocument, progress: ProgressReporter) -> String {
        var out: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            progress(Double(i) / Double(doc.pageCount), "Reading page \(i + 1)")
            guard let attr = page.attributedString, attr.length > 0 else {
                let t = OCR.text(of: OCR.recognize(PageRenderer.image(page, dpi: 200)))
                if !t.isEmpty { out.append(t) }
                continue
            }
            // Find the usual body text size so bigger lines become headings.
            var sizes: [CGFloat: Int] = [:]
            attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { v, r, _ in
                if let f = v as? UIFont { sizes[f.pointSize.rounded(), default: 0] += r.length }
            }
            let body = sizes.max { $0.value < $1.value }?.key ?? 12
            let ns = attr.string as NSString
            var paragraph = ""
            func flush() { if !paragraph.isEmpty { out.append(paragraph); paragraph = "" } }
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { line, range, _, _ in
                guard let line = line?.trimmingCharacters(in: .whitespaces) else { return }
                if line.isEmpty { flush(); return }
                let font = range.length > 0 ? attr.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont : nil
                let size = font?.pointSize ?? body
                let bold = font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false
                if size >= body * 1.45 { flush(); out.append("# " + line); return }
                if size >= body * 1.15 || (bold && line.count < 80 && !line.hasSuffix(".")) { flush(); out.append("## " + line); return }
                if line.hasPrefix("•") || line.hasPrefix("- ") || line.hasPrefix("◦") {
                    flush(); out.append("- " + line.drop(while: { "•-◦ ".contains($0) })); return
                }
                paragraph += paragraph.isEmpty ? line : (paragraph.hasSuffix("-") ? String(line) : " " + line)
                if line.hasSuffix(".") || line.hasSuffix(":") { flush() }
            }
            flush()
        }
        return out.joined(separator: "\n\n")
    }

    /// Lays plain text out over A4 pages.
    static func textPDF(title: String, sections: [(String, String)]) -> Data {
        let attr = NSMutableAttributedString()
        let titleFont = UIFont.systemFont(ofSize: 20, weight: .bold)
        let headFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: 11)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 3; para.paragraphSpacing = 6
        attr.append(NSAttributedString(string: title + "\n\n", attributes: [.font: titleFont, .foregroundColor: UIColor.black]))
        for (head, body) in sections {
            if !head.isEmpty { attr.append(NSAttributedString(string: head + "\n", attributes: [.font: headFont, .foregroundColor: UIColor.darkGray, .paragraphStyle: para])) }
            attr.append(NSAttributedString(string: body + "\n\n", attributes: [.font: bodyFont, .foregroundColor: UIColor.black, .paragraphStyle: para]))
        }
        let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        return UIGraphicsPDFRenderer(bounds: pageRect).pdfData { c in
            var start = 0
            while start < attr.length {
                c.beginPage()
                let ctx = c.cgContext
                ctx.saveGState()
                ctx.translateBy(x: 0, y: pageRect.height)
                ctx.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: pageRect.insetBy(dx: 56, dy: 56), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
                CTFrameDraw(frame, ctx)
                let visible = CTFrameGetVisibleStringRange(frame)
                ctx.restoreGState()
                if visible.length == 0 { break }
                start += visible.length
            }
        }
    }

    // MARK: Stamps

    enum Spot: String, CaseIterable, Identifiable {
        case topLeft = "Top left", topCentre = "Top centre", topRight = "Top right"
        case bottomLeft = "Bottom left", bottomCentre = "Bottom centre", bottomRight = "Bottom right"
        var id: String { rawValue }
        var isTop: Bool { [.topLeft, .topCentre, .topRight].contains(self) }
        var align: NSTextAlignment {
            switch self { case .topLeft, .bottomLeft: return .left; case .topRight, .bottomRight: return .right; default: return .center }
        }
    }

    enum NumberFormat: String, CaseIterable, Identifiable {
        case plain = "1", page = "Page 1", ofTotal = "Page 1 of 9", slash = "1 / 9"
        var id: String { rawValue }
        func text(_ n: Int, _ total: Int) -> String {
            switch self {
            case .plain: return "\(n)"
            case .page: return "Page \(n)"
            case .ofTotal: return "Page \(n) of \(total)"
            case .slash: return "\(n) / \(total)"
            }
        }
    }

    static func pageNumbers(_ doc: PDFDocument, spot: Spot, format: NumberFormat, startAt: Int, fromPage: Int,
                            fontSize: CGFloat, color: UIColor, margin: CGFloat, progress: ProgressReporter) -> Data {
        let numbered = max(doc.pageCount - (fromPage - 1), 0)
        return PageRenderer.render(doc, progress: progress, label: "Numbering", above: { i, ctx, size in
            guard i >= fromPage - 1 else { return }
            let n = startAt + (i - (fromPage - 1))
            let text = format.text(n, startAt + numbered - 1)
            let p = NSMutableParagraphStyle(); p.alignment = spot.align
            let attr = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: color, .paragraphStyle: p])
            let h = attr.size().height
            let y = spot.isTop ? margin : size.height - margin - h
            UIGraphicsPushContext(ctx)
            attr.draw(in: CGRect(x: margin, y: y, width: size.width - 2 * margin, height: h + 2))
            UIGraphicsPopContext()
        })
    }

    enum WatermarkPlace: String, CaseIterable, Identifiable {
        case centre = "Centre", tiled = "Tiled", top = "Top", bottom = "Bottom"
        var id: String { rawValue }
    }

    static func watermark(_ doc: PDFDocument, text: String?, image: UIImage?, fontSize: CGFloat, color: UIColor,
                          opacity: CGFloat, angle: CGFloat, place: WatermarkPlace, behind: Bool, imageScale: CGFloat,
                          progress: ProgressReporter) -> Data {
        let draw: (Int, CGContext, CGSize) -> Void = { _, ctx, size in
            UIGraphicsPushContext(ctx)
            defer { UIGraphicsPopContext() }
            ctx.saveGState()
            ctx.setAlpha(opacity)
            var itemSize = CGSize.zero
            var attr: NSAttributedString?
            if let image {
                let w = size.width * imageScale
                itemSize = CGSize(width: w, height: w * image.size.height / max(image.size.width, 1))
            } else if let text, !text.isEmpty {
                let a = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: fontSize, weight: .bold), .foregroundColor: color])
                attr = a
                itemSize = a.size()
            }
            func stamp(at c: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: -angle * .pi / 180)
                let r = CGRect(x: -itemSize.width / 2, y: -itemSize.height / 2, width: itemSize.width, height: itemSize.height)
                if let image { image.draw(in: r) } else { attr?.draw(in: r) }
                ctx.restoreGState()
            }
            switch place {
            case .centre: stamp(at: CGPoint(x: size.width / 2, y: size.height / 2))
            case .top: stamp(at: CGPoint(x: size.width / 2, y: 40 + itemSize.height / 2))
            case .bottom: stamp(at: CGPoint(x: size.width / 2, y: size.height - 40 - itemSize.height / 2))
            case .tiled:
                for row in 0..<4 { for col in 0..<3 {
                    stamp(at: CGPoint(x: size.width * (CGFloat(col) + 0.5) / 3, y: size.height * (CGFloat(row) + 0.5) / 4))
                } }
            }
            ctx.restoreGState()
        }
        return PageRenderer.render(doc, progress: progress, label: "Stamping", below: behind ? draw : nil, above: behind ? nil : draw)
    }

    // MARK: Crop

    /// `rect` is normalised in display space.
    static func crop(_ doc: PDFDocument, rect: CGRect, pages: [Int]) -> PDFDocument {
        for i in pages {
            guard let page = doc.page(at: i) else { continue }
            let r = PageRenderer.pageRect(fromDisplay: rect, on: page)
            page.setBounds(r, for: .cropBox)
        }
        return doc
    }
}
