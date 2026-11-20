import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Second straightening pass that uses the page content instead of its edges:
/// text lines are made level and letter strokes upright, by solving for the one
/// small perspective correction that does both. Used after the edge-based warp,
/// because paper edges often don't match the print (trimmed crooked, bent covers).
enum TextStraightener {
    private struct Cue {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var w: Double
        var horizontal: Bool
    }

    static func refine(_ image: UIImage) -> UIImage {
        guard let full = image.cgImage else { return image }
        let W = Double(full.width), H = Double(full.height)
        guard W > 200, H > 200 else { return image }

        // Work on a smaller copy for speed.
        let k = min(1.0, 1400.0 / max(W, H))
        let aw = Int(W * k), ah = Int(H * k)
        guard let gray = grayBuffer(full, aw, ah) else { return image }

        // 1. Where the text is.
        guard let small = grayImage(gray, aw, ah) else { return image }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: small, orientation: .up, options: [:]).perform([req])
        let boxes: [CGRect] = (req.results ?? []).compactMap { obs in
            let b = obs.boundingBox
            let r = CGRect(x: b.minX * Double(aw), y: (1 - b.maxY) * Double(ah), width: b.width * Double(aw), height: b.height * Double(ah))
            return r.width > Double(aw) * 0.08 && r.height > 6 ? r : nil
        }
        guard boxes.count >= 3 else { return image }

        // 2. Real baselines measured from the ink, not from the boxes.
        var cues: [Cue] = []
        for box in boxes {
            if let c = baseline(in: box, gray: gray, w: aw, h: ah) { cues.append(c) }
        }
        guard cues.count >= 3 else { return image }

        // 3. Upright strokes inside the text areas.
        let verticals = strokes(gray: gray, w: aw, h: ah, regions: boxes)
        let hSum = cues.reduce(0) { $0 + $1.w }
        let vSum = verticals.reduce(0) { $0 + $1.w }
        if vSum > 0 {
            let scale = 0.5 * hSum / vSum
            cues += verticals.map { var c = $0; c.w *= scale; return c }
        }

        // 4. Solve in normalised coordinates centred on the image.
        let cx = Double(aw) / 2, cy = Double(ah) / 2, s = Double(max(aw, ah)) / 2
        let norm = cues.map { c -> Cue in
            var n = c
            n.a = SIMD2((c.a.x - cx) / s, (c.a.y - cy) / s)
            n.b = SIMD2((c.b.x - cx) / s, (c.b.y - cy) / s)
            return n
        }
        let lines = norm.filter(\.horizontal)
        let before = meanError([0, 0, 0, 0], lines)
        let p = solve(norm)
        let after = meanError(p, lines)
        guard p.allSatisfy({ abs($0) < 0.25 }), before > 0.004, after < before * 0.75 else { return image }

        // 5. Apply the same correction to the full-size image.
        return apply(p, to: image, cg: full)
    }

    // MARK: Measuring

    private static func grayBuffer(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    private static func grayImage(_ buf: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Measures the slope of the text in a box with the projection-profile method:
    /// the angle at which the rows of ink stack up most sharply is the line angle.
    /// Robust to descenders, accents and two lines sharing one box.
    private static func baseline(in box: CGRect, gray: [UInt8], w: Int, h: Int) -> Cue? {
        let r = box.insetBy(dx: 0, dy: -box.height * 0.15)
        let x0 = max(Int(r.minX), 0), x1 = min(Int(r.maxX), w - 1)
        let y0 = max(Int(r.minY), 0), y1 = min(Int(r.maxY), h - 1)
        guard x1 - x0 > 20, y1 - y0 > 4 else { return nil }

        // Otsu threshold for this box.
        var hist = [Int](repeating: 0, count: 256)
        for y in y0...y1 { for x in x0...x1 { hist[Int(gray[y * w + x])] += 1 } }
        let total = (x1 - x0 + 1) * (y1 - y0 + 1)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, t = 128
        for i in 0..<256 {
            wB += hist[i]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(i * hist[i])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; t = i }
        }
        var dark = 0
        for i in 0...t { dark += hist[i] }
        let inkIsDark = dark < total / 2

        var xs: [Double] = [], ys: [Double] = []
        for y in y0...y1 {
            for x in x0...x1 {
                let v = Int(gray[y * w + x])
                if inkIsDark ? v <= t : v > t { xs.append(Double(x)); ys.append(Double(y)) }
            }
        }
        guard xs.count > 50 else { return nil }
        if xs.count > 6000 {
            let step = Double(xs.count - 1) / 5999
            let idx = (0..<6000).map { Int(Double($0) * step) }
            xs = idx.map { xs[$0] }; ys = idx.map { ys[$0] }
        }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let height = y1 - y0 + 1
        let width = Double(x1 - x0)
        var bestScore = -1.0, bestM = 0.0
        var m = -0.12
        while m <= 0.1201 {
            var bins = [Int](repeating: 0, count: height + Int(width * 0.13) * 2 + 4)
            let off = Int(width * 0.13) + 2
            for i in xs.indices {
                let yy = Int((ys[i] - Double(y0) - m * (xs[i] - mx)).rounded()) + off
                if yy >= 0 && yy < bins.count { bins[yy] += 1 }
            }
            var score = 0.0
            for b in bins { score += Double(b * b) }
            if score > bestScore { bestScore = score; bestM = m }
            m += 0.0015
        }
        let half = width / 2
        return Cue(a: SIMD2(mx - half, my - bestM * half), b: SIMD2(mx + half, my + bestM * half), w: width, horizontal: true)
    }

    private static func fit(_ xs: [Double], _ ys: [Double]) -> (Double, Double)? {
        let n = Double(xs.count)
        guard n >= 2 else { return nil }
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in xs.indices { sxx += (xs[i] - mx) * (xs[i] - mx); sxy += (xs[i] - mx) * (ys[i] - my) }
        guard sxx > 0 else { return nil }
        let m = sxy / sxx
        return (m, my - m * mx)
    }

    /// Local stroke direction from the gradient structure tensor; keeps blocks that hold
    /// a clear near-vertical stroke (letter stems, table rules).
    private static func strokes(gray: [UInt8], w: Int, h: Int, regions: [CGRect]) -> [Cue] {
        let B = 14
        let grown = regions.map { $0.insetBy(dx: -4, dy: -$0.height * 0.2) }
        var out: [Cue] = []
        var by = 1
        while by + B < h - 1 {
            var bx = 1
            while bx + B < w - 1 {
                let centre = CGPoint(x: bx + B / 2, y: by + B / 2)
                if grown.contains(where: { $0.contains(centre) }) {
                    var jxx = 0.0, jyy = 0.0, jxy = 0.0
                    for y in by..<(by + B) {
                        for x in bx..<(bx + B) {
                            let i = y * w + x
                            let gx = Double(Int(gray[i - w + 1]) + 2 * Int(gray[i + 1]) + Int(gray[i + w + 1])
                                            - Int(gray[i - w - 1]) - 2 * Int(gray[i - 1]) - Int(gray[i + w - 1]))
                            let gy = Double(Int(gray[i + w - 1]) + 2 * Int(gray[i + w]) + Int(gray[i + w + 1])
                                            - Int(gray[i - w - 1]) - 2 * Int(gray[i - w]) - Int(gray[i - w + 1]))
                            jxx += gx * gx; jyy += gy * gy; jxy += gx * gy
                        }
                    }
                    let energy = jxx + jyy
                    if energy > Double(B * B) * 4000 {
                        let coh = sqrt((jxx - jyy) * (jxx - jyy) + 4 * jxy * jxy) / energy
                        let theta = 0.5 * atan2(2 * jxy, jxx - jyy) // dominant gradient direction
                        if coh > 0.6, abs(theta) < 0.21 {
                            // Stroke runs at right angles to the gradient.
                            let e = SIMD2(-sin(theta), cos(theta))
                            let c = SIMD2(Double(centre.x), Double(centre.y))
                            out.append(Cue(a: c - e * 7, b: c + e * 7, w: coh * Double(B), horizontal: false))
                        }
                    }
                }
                bx += B
            }
            by += B
        }
        return out
    }

    // MARK: Solving

    private static func matrix(_ p: [Double]) -> [[Double]] {
        [[1, p[0], 0], [p[1], 1, 0], [p[2], p[3], 1]]
    }

    private static func map(_ m: [[Double]], _ q: SIMD2<Double>) -> SIMD2<Double> {
        let x = m[0][0] * q.x + m[0][1] * q.y + m[0][2]
        let y = m[1][0] * q.x + m[1][1] * q.y + m[1][2]
        let z = m[2][0] * q.x + m[2][1] * q.y + m[2][2]
        return SIMD2(x / z, y / z)
    }

    private static func residuals(_ p: [Double], _ cues: [Cue]) -> [Double] {
        let m = matrix(p)
        return cues.map { c in
            let A = map(m, c.a), B = map(m, c.b)
            if c.horizontal {
                let dx = B.x - A.x
                return abs(dx) < 1e-6 ? 0 : (B.y - A.y) / dx
            }
            let dy = B.y - A.y
            return abs(dy) < 1e-6 ? 0 : (B.x - A.x) / dy
        }
    }

    private static func meanError(_ p: [Double], _ cues: [Cue]) -> Double {
        let r = residuals(p, cues)
        var s = 0.0, ws = 0.0
        for (i, c) in cues.enumerated() { s += abs(r[i]) * c.w; ws += c.w }
        return ws > 0 ? s / ws : 0
    }

    /// Robust Gauss–Newton over 4 parameters: shear, rotation-ish skew and two perspective terms.
    private static func solve(_ cues: [Cue]) -> [Double] {
        var p = [0.0, 0.0, 0.0, 0.0]
        let delta = 0.02
        for _ in 0..<25 {
            let r = residuals(p, cues)
            var J = [[Double]](repeating: [0, 0, 0, 0], count: cues.count)
            for j in 0..<4 {
                var q = p; q[j] += 1e-5
                let r2 = residuals(q, cues)
                for i in cues.indices { J[i][j] = (r2[i] - r[i]) / 1e-5 }
            }
            var A = [[Double]](repeating: [0, 0, 0, 0], count: 4)
            var g = [0.0, 0.0, 0.0, 0.0]
            for i in cues.indices {
                let huber = abs(r[i]) <= delta ? 1 : delta / abs(r[i])
                let wi = cues[i].w * huber
                for a in 0..<4 {
                    g[a] += wi * J[i][a] * r[i]
                    for b in 0..<4 { A[a][b] += wi * J[i][a] * J[i][b] }
                }
            }
            for a in 0..<4 { A[a][a] += 1e-6 + A[a][a] * 1e-3 }
            guard let step = solve4(A, g.map { -$0 }) else { break }
            p = zip(p, step).map { $0 + $1 }
            if step.map(abs).max() ?? 0 < 1e-7 { break }
        }
        return p
    }

    private static func solve4(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        var m = A.enumerated().map { $0.element + [b[$0.offset]] }
        let n = 4
        for col in 0..<n {
            guard let piv = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[piv][col]) > 1e-12 else { return nil }
            m.swapAt(col, piv)
            for r in 0..<n where r != col {
                let f = m[r][col] / m[col][col]
                for c in col...n { m[r][c] -= f * m[col][c] }
            }
        }
        return (0..<n).map { m[$0][n] / m[$0][$0] }
    }

    // MARK: Applying

    private static func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    private static func inverse(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2], d = m[1][0], e = m[1][1], f = m[1][2], g = m[2][0], h = m[2][1], i = m[2][2]
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-12 else { return nil }
        let inv = [[A, -(b * i - c * h), b * f - c * e],
                   [B, a * i - c * g, -(a * f - c * d)],
                   [C, -(a * h - b * g), a * e - b * d]]
        return inv.map { $0.map { $0 / det } }
    }

    private static func apply(_ p: [Double], to image: UIImage, cg: CGImage) -> UIImage {
        let W = Double(cg.width), H = Double(cg.height)
        let cx = W / 2, cy = H / 2, s = max(W, H) / 2
        let N = [[1 / s, 0, -cx / s], [0, 1 / s, -cy / s], [0, 0, 1]]
        let Ninv = [[s, 0, cx], [0, s, cy], [0, 0, 1]]
        let M = mul(Ninv, mul(matrix(p), N))
        guard let Minv = inverse(M) else { return image }

        let q = [SIMD2(0, 0), SIMD2(W, 0), SIMD2(W, H), SIMD2(0, H)].map { map(M, $0) }
        let x0 = max(q[0].x, q[3].x), x1 = min(q[1].x, q[2].x)
        let y0 = max(q[0].y, q[1].y), y1 = min(q[2].y, q[3].y)
        guard x1 - x0 > W * 0.6, y1 - y0 > H * 0.6 else { return image }

        // Where the clean output rectangle comes from in the source image.
        let src = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)].map { map(Minv, $0) }
        guard let ci = CIImage(image: image) else { return image }
        let toCI: (SIMD2<Double>) -> CGPoint = { CGPoint(x: $0.x, y: H - $0.y) }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = ci
        f.topLeft = toCI(src[0]); f.topRight = toCI(src[1])
        f.bottomRight = toCI(src[2]); f.bottomLeft = toCI(src[3])
        f.crop = true
        guard let out = f.outputImage else { return image }
        let tw = (x1 - x0).rounded(), th = (y1 - y0).rounded()
        let scaled = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY)
            .scaledBy(x: tw / out.extent.width, y: th / out.extent.height))
        guard let result = Perspective.context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: tw, height: th)) else { return image }
        return UIImage(cgImage: result)
    }
}
