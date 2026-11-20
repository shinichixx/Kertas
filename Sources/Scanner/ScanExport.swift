import UIKit
import PDFKit

enum ScanFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF", jpg = "JPG", png = "PNG"
    var id: String { rawValue }
}

enum ScanPageSize: String, CaseIterable, Identifiable {
    case original = "Original", a4 = "A4", a5 = "A5", letter = "Letter", square = "Square", fourThree = "4:3", sixteenNine = "16:9"
    var id: String { rawValue }

    /// Portrait shape in points (short side × long side). Nil means "same as the scan".
    var portrait: CGSize? {
        switch self {
        case .original: return nil
        case .a4: return CGSize(width: 595.2, height: 841.8)
        case .a5: return CGSize(width: 419.5, height: 595.3)
        case .letter: return CGSize(width: 612, height: 792)
        case .square: return CGSize(width: 595, height: 595)
        case .fourThree: return CGSize(width: 595, height: 793.3)
        case .sixteenNine: return CGSize(width: 595, height: 1057.8)
        }
    }
}

enum ScanFit: String, CaseIterable, Identifiable {
    case fit = "Fit inside", fill = "Fill page", stretch = "Stretch"
    var id: String { rawValue }
    var note: String {
        switch self {
        case .fit: return "white border"
        case .fill: return "edges trimmed"
        case .stretch: return "no border, no trim"
        }
    }
}

enum ScanExport {
    /// Where the image goes on a page of `page` size.
    static func drawRect(_ img: UIImage, in page: CGSize, size: ScanPageSize, fit: ScanFit) -> CGRect {
        let full = CGRect(origin: .zero, size: page)
        if size == .original || fit == .stretch { return full }
        let sx = page.width / img.size.width, sy = page.height / img.size.height
        let s = fit == .fill ? max(sx, sy) : min(sx, sy)
        let w = img.size.width * s, h = img.size.height * s
        return CGRect(x: (page.width - w) / 2, y: (page.height - h) / 2, width: w, height: h)
    }

    static func pdf(_ images: [UIImage], size: ScanPageSize, fit: ScanFit, searchable: Bool, progress: ProgressReporter) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        let data = renderer.pdfData { c in
            for (i, raw) in images.enumerated() {
                progress(Double(i) / Double(images.count), "Adding page \(i + 1) of \(images.count)")
                autoreleasepool {
                    let page: CGSize
                    if let p = size.portrait {
                        page = raw.size.width > raw.size.height ? CGSize(width: p.height, height: p.width) : p
                    } else {
                        page = CGSize(width: 595, height: 595 * raw.size.height / max(raw.size.width, 1))
                    }
                    c.beginPage(withBounds: CGRect(origin: .zero, size: page), pageInfo: [:])
                    let ctx = c.cgContext
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: page))
                    ctx.saveGState()
                    ctx.clip(to: CGRect(origin: .zero, size: page))
                    let img = (raw.jpegData(compressionQuality: 0.85)).flatMap(UIImage.init(data:)) ?? raw
                    img.draw(in: drawRect(raw, in: page, size: size, fit: fit))
                    ctx.restoreGState()
                }
            }
        }
        guard searchable, let doc = PDFDocument(data: data) else { return data }
        return OCR.searchable(doc, progress: progress).0
    }

    /// One image per page at full scan resolution, shaped to the chosen page size.
    static func image(_ raw: UIImage, size: ScanPageSize, fit: ScanFit) -> UIImage {
        guard let p = size.portrait else { return raw }
        let landscape = raw.size.width > raw.size.height
        let shape = landscape ? CGSize(width: p.height, height: p.width) : p
        // Keep the scan's resolution: the long side stays the same.
        let long = max(raw.size.width, raw.size.height)
        let k = long / max(shape.width, shape.height)
        let canvas = CGSize(width: (shape.width * k).rounded(), height: (shape.height * k).rounded())
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: canvas, format: format).image { c in
            UIColor.white.setFill()
            c.fill(CGRect(origin: .zero, size: canvas))
            c.cgContext.clip(to: CGRect(origin: .zero, size: canvas))
            raw.draw(in: drawRect(raw, in: canvas, size: size, fit: fit))
        }
    }

    static func save(_ images: [UIImage], name: String, format: ScanFormat, size: ScanPageSize, fit: ScanFit,
                     searchable: Bool, progress: ProgressReporter) throws -> ToolOutput {
        switch format {
        case .pdf:
            let data = pdf(images, size: size, fit: fit, searchable: searchable, progress: progress)
            let url = try FileStore.save(data, base: name, ext: "pdf")
            return ToolOutput(urls: [url], message: "\(images.count) page\(images.count == 1 ? "" : "s") · \(FileStore.sizeText(FileStore.size(url)))")
        case .jpg, .png:
            let ext = format == .jpg ? "jpg" : "png"
            func encode(_ img: UIImage) -> Data? { format == .jpg ? img.jpegData(compressionQuality: 0.9) : img.pngData() }
            if images.count == 1 {
                guard let d = encode(image(images[0], size: size, fit: fit)) else { throw KertasError("Couldn't save the image.") }
                let url = try FileStore.save(d, base: name, ext: ext)
                return ToolOutput(urls: [url], message: "\(format.rawValue) · \(FileStore.sizeText(FileStore.size(url)))")
            }
            let folder = FileStore.folder(named: name)
            for (i, raw) in images.enumerated() {
                progress(Double(i) / Double(images.count), "Saving image \(i + 1) of \(images.count)")
                try autoreleasepool {
                    guard let d = encode(image(raw, size: size, fit: fit)) else { return }
                    try d.write(to: folder.appendingPathComponent(String(format: "Page %03d.%@", i + 1, ext)))
                }
            }
            FileStore.notify()
            return ToolOutput(urls: [folder], message: "\(images.count) \(format.rawValue) images in a folder")
        }
    }
}
