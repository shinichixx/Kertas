import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Four corners, normalised to 0...1 with the origin at the top-left of the image.
struct Quad: Equatable {
    var tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint
    static let full = Quad(tl: .init(x: 0, y: 0), tr: .init(x: 1, y: 0), br: .init(x: 1, y: 1), bl: .init(x: 0, y: 1))
    static let inset = Quad(tl: .init(x: 0.08, y: 0.08), tr: .init(x: 0.92, y: 0.08), br: .init(x: 0.92, y: 0.92), bl: .init(x: 0.08, y: 0.92))
    var points: [CGPoint] { [tl, tr, br, bl] }
    subscript(i: Int) -> CGPoint {
        get { [tl, tr, br, bl][i] }
        set { switch i { case 0: tl = newValue; case 1: tr = newValue; case 2: br = newValue; default: bl = newValue } }
    }
}

enum ScanFilter: String, CaseIterable, Identifiable {
    case auto = "Auto", colour = "Colour", grey = "Grey", bw = "B and W", original = "Original"
    var id: String { rawValue }
}

enum Perspective {
    static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Finds the page in a photo. Tries the document detector first, then a plain rectangle search.
    static func detect(_ image: UIImage) -> Quad? {
        guard let cg = image.cgImage else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        let doc = VNDetectDocumentSegmentationRequest()
        let rect = VNDetectRectanglesRequest()
        rect.minimumAspectRatio = 0.2
        rect.maximumAspectRatio = 1
        rect.minimumSize = 0.2
        rect.quadratureTolerance = 45
        rect.minimumConfidence = 0.5
        rect.maximumObservations = 1
        try? handler.perform([doc, rect])
        let obs = (doc.results?.first).flatMap { $0.confidence > 0.3 ? $0 : nil } ?? rect.results?.first
        guard let o = obs else { return nil }
        let flip: (CGPoint) -> CGPoint = { CGPoint(x: $0.x, y: 1 - $0.y) }
        let q = Quad(tl: flip(o.topLeft), tr: flip(o.topRight), br: flip(o.bottomRight), bl: flip(o.bottomLeft))
        return area(q) > 0.05 ? q : nil
    }

    static func area(_ q: Quad) -> CGFloat {
        let p = q.points
        var a: CGFloat = 0
        for i in 0..<4 { let j = (i + 1) % 4; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return abs(a) / 2
    }

    /// Straightens the page so it looks like it came off a flatbed scanner.
    static func correct(_ image: UIImage, quad: Quad?) -> UIImage {
        guard let q = quad, q != .full, let ci = CIImage(image: image) else { return image }
        let w = ci.extent.width, h = ci.extent.height
        let toCI: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * w, y: (1 - $0.y) * h) }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = ci
        f.topLeft = toCI(q.tl)
        f.topRight = toCI(q.tr)
        f.bottomRight = toCI(q.br)
        f.bottomLeft = toCI(q.bl)
        f.crop = true
        guard let out = f.outputImage else { return image }

        // Keep the true page proportions using the average opposite edge lengths.
        let top = dist(toCI(q.tl), toCI(q.tr)), bottom = dist(toCI(q.bl), toCI(q.br))
        let left = dist(toCI(q.tl), toCI(q.bl)), right = dist(toCI(q.tr), toCI(q.br))
        let targetW = max(top, bottom), targetH = max(left, right)
        let sx = targetW / out.extent.width, sy = targetH / out.extent.height
        let scaled = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY).scaledBy(x: sx, y: sy))
        guard let cg = context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: targetW.rounded(), height: targetH.rounded())) else { return image }
        return UIImage(cgImage: cg)
    }

    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func rotate(_ image: UIImage, quarterTurns: Int) -> UIImage {
        let t = ((quarterTurns % 4) + 4) % 4
        guard t != 0 else { return image }
        let size = t % 2 == 0 ? image.size : CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let ctx = c.cgContext
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: CGFloat(t) * .pi / 2)
            image.draw(in: CGRect(x: -image.size.width / 2, y: -image.size.height / 2, width: image.size.width, height: image.size.height))
        }
    }

    /// Scanner-style clean up: whiter paper, darker text.
    static func apply(_ filter: ScanFilter, to image: UIImage) -> UIImage {
        guard filter != .original, let ci = CIImage(image: image) else { return image }
        var img = ci
        let enhancer = CIFilter.documentEnhancer()
        enhancer.inputImage = img
        enhancer.amount = 1
        if let e = enhancer.outputImage { img = e }
        switch filter {
        case .auto:
            let sharpen = CIFilter.sharpenLuminance(); sharpen.inputImage = img; sharpen.sharpness = 0.4
            img = sharpen.outputImage ?? img
        case .colour:
            let c = CIFilter.colorControls(); c.inputImage = img; c.saturation = 1.3; c.contrast = 1.1
            img = c.outputImage ?? img
            let v = CIFilter.vibrance(); v.inputImage = img; v.amount = 0.4
            img = v.outputImage ?? img
        case .grey:
            let c = CIFilter.colorControls(); c.inputImage = img; c.saturation = 0; c.contrast = 1.15
            img = c.outputImage ?? img
        case .bw:
            let c = CIFilter.colorControls(); c.inputImage = img; c.saturation = 0; c.contrast = 1.3
            img = c.outputImage ?? img
            let t = CIFilter.colorThresholdOtsu(); t.inputImage = img
            img = t.outputImage ?? img
        case .original: break
        }
        guard let cg = context.createCGImage(img, from: ci.extent) else { return image }
        return UIImage(cgImage: cg)
    }
}
