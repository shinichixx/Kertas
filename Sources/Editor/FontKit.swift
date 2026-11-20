import UIKit
import CoreText
import PDFKit

/// What a PDF font name tells us.
struct FontIdentity: Equatable {
    var raw: String
    var family: String
    var styleName: String
    var bold: Bool
    var italic: Bool
    var subset: Bool

    var display: String {
        family + (styleName.isEmpty || styleName.lowercased() == "regular" ? "" : " " + styleName)
    }
}

struct FontSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case ready, download }
    var family: String
    var note: String
    var kind: Kind
    var id: String { family }
}

final class FontLibrary: ObservableObject {
    static let shared = FontLibrary()

    @Published private(set) var downloaded: [String] = []
    /// Requested family name (normalised) → the family name the font file really registers.
    private var aliases: [String: String] = [:]
    @Published private(set) var googleCache: [String]?

    private var dir: URL { FileStore.support("Fonts") }

    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    // MARK: Identify

    static func parse(_ raw: String) -> FontIdentity {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var subset = false
        if let plus = s.firstIndex(of: "+"), s.distance(from: s.startIndex, to: plus) == 6,
           s[s.startIndex..<plus].allSatisfy({ $0.isUppercase }) {
            s = String(s[s.index(after: plus)...])
            subset = true
        }
        var fam = s, style = ""
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "," }) {
            fam = String(s[s.startIndex..<cut])
            style = String(s[s.index(after: cut)...])
        }
        for suffix in ["PSMT", "MT", "PS"] where fam.count > suffix.count + 3 && fam.hasSuffix(suffix) {
            fam = String(fam.dropLast(suffix.count))
        }
        for suffix in ["MT", "PS"] where style.hasSuffix(suffix) { style = String(style.dropLast(suffix.count)) }
        // Names like "ArialBold" with the style glued on.
        if style.isEmpty {
            for st in ["BoldItalic", "BoldOblique", "Bold", "Italic", "Oblique"] where fam.hasSuffix(st) && fam.count > st.count + 2 {
                style = st
                fam = String(fam.dropLast(st.count))
                break
            }
        }
        if !fam.contains(" ") {
            var spaced = ""
            let chars = Array(fam)
            for (i, ch) in chars.enumerated() {
                if i > 0, ch.isUppercase, chars[i - 1].isLowercase { spaced.append(" ") }
                spaced.append(ch)
            }
            fam = spaced
        }
        let low = style.lowercased()
        let bold = ["bold", "black", "heavy", "semibold", "demi"].contains { low.contains($0) }
        let italic = low.contains("italic") || low.contains("oblique")
        var styleName = style
        if !style.isEmpty && !style.contains(" ") {
            var spaced = ""
            for (i, ch) in style.enumerated() {
                if i > 0, ch.isUppercase { spaced.append(" ") }
                spaced.append(ch)
            }
            styleName = spaced
        }
        return FontIdentity(raw: raw, family: fam, styleName: styleName, bold: bold, italic: italic, subset: subset)
    }

    /// Fonts that ship with iOS, under the names PDFs usually use.
    private static let deviceAliases: [String: String] = [
        "arial": "Arial", "arialmt": "Arial", "helvetica": "Helvetica", "helveticaneue": "Helvetica Neue",
        "timesnewroman": "Times New Roman", "times": "Times New Roman", "timesroman": "Times New Roman",
        "couriernew": "Courier New", "courier": "Courier", "georgia": "Georgia", "verdana": "Verdana",
        "trebuchetms": "Trebuchet MS", "trebuchet": "Trebuchet MS", "palatino": "Palatino", "palatinolinotype": "Palatino",
        "bookantiqua": "Palatino", "gillsans": "Gill Sans", "gillsansmt": "Gill Sans", "futura": "Futura",
        "optima": "Optima", "baskerville": "Baskerville", "didot": "Didot", "avenir": "Avenir", "avenirnext": "Avenir Next",
        "menlo": "Menlo", "americantypewriter": "American Typewriter", "rockwell": "Rockwell", "charter": "Charter",
        "arialroundedmtbold": "Arial Rounded MT Bold", "arialrounded": "Arial Rounded MT Bold", "hoefler": "Hoefler Text",
        "hoeflertext": "Hoefler Text", "cochin": "Cochin", "copperplate": "Copperplate", "papyrus": "Papyrus",
        "markerfelt": "Marker Felt", "chalkboard": "Chalkboard SE", "noteworthy": "Noteworthy", "sfpro": "Helvetica Neue"
    ]

    /// Free fonts with the same letter widths (or a close look) for common paid fonts.
    private static let substitutes: [String: (String, String)] = [
        "calibri": ("Carlito", "Same letter widths as Calibri"),
        "calibrilight": ("Carlito", "Same letter widths as Calibri"),
        "cambria": ("Caladea", "Same letter widths as Cambria"),
        "cambriamath": ("Caladea", "Same letter widths as Cambria"),
        "arial": ("Arimo", "Same letter widths as Arial"),
        "helvetica": ("Arimo", "Same letter widths as Helvetica"),
        "timesnewroman": ("Tinos", "Same letter widths as Times New Roman"),
        "times": ("Tinos", "Same letter widths as Times"),
        "couriernew": ("Cousine", "Same letter widths as Courier New"),
        "courier": ("Cousine", "Same letter widths as Courier"),
        "segoeui": ("Open Sans", "Close look to Segoe UI"),
        "tahoma": ("PT Sans", "Close look to Tahoma"),
        "centurygothic": ("Questrial", "Close look to Century Gothic"),
        "garamond": ("EB Garamond", "Close look to Garamond"),
        "adobegaramondpro": ("EB Garamond", "Close look to Garamond"),
        "franklingothic": ("Libre Franklin", "Close look to Franklin Gothic"),
        "franklingothicbook": ("Libre Franklin", "Close look to Franklin Gothic"),
        "franklingothicmedium": ("Libre Franklin", "Close look to Franklin Gothic"),
        "franklingothicdemi": ("Libre Franklin", "Close look to Franklin Gothic"),
        "myriadpro": ("PT Sans", "Close look to Myriad Pro"),
        "minionpro": ("Crimson Pro", "Close look to Minion Pro"),
        "aptos": ("Inter", "Close look to Aptos"),
        "consolas": ("Inconsolata", "Close look to Consolas"),
        "comicsansms": ("Comic Neue", "Close look to Comic Sans"),
        "impact": ("Anton", "Close look to Impact"),
        "arialnarrow": ("Archivo Narrow", "Close look to Arial Narrow"),
        "bookmanoldstyle": ("Libre Baskerville", "Close look to Bookman"),
        "candara": ("Cabin", "Close look to Candara"),
        "corbel": ("Open Sans", "Close look to Corbel"),
        "constantia": ("Gelasio", "Close look to Constantia"),
        "lucidasans": ("Open Sans", "Close look to Lucida Sans"),
        "lucidagrande": ("Open Sans", "Close look to Lucida Grande"),
        "sourcesanspro": ("Source Sans 3", "Newer version of Source Sans Pro"),
        "sourcesans": ("Source Sans 3", "Newer version of Source Sans"),
        "bahnschrift": ("Barlow", "Close look to Bahnschrift"),
        "leelawadeeui": ("Noto Sans", "Close look"),
        "symbol": ("Noto Sans Symbols", "Symbols"),
    ]

    func deviceFamily(for family: String) -> String? {
        let n = Self.norm(family)
        if let a = Self.deviceAliases[n], !UIFont.fontNames(forFamilyName: a).isEmpty { return a }
        return UIFont.familyNames.first { Self.norm($0) == n }
    }

    func isInstalled(_ family: String) -> Bool {
        let n = Self.norm(family)
        return aliases[n] != nil || downloaded.contains { Self.norm($0) == n }
    }

    /// Best choices for a font found in a PDF, in order.
    func suggestions(for id: FontIdentity) -> [FontSuggestion] {
        var out: [FontSuggestion] = []
        func add(_ s: FontSuggestion) { if !out.contains(where: { Self.norm($0.family) == Self.norm(s.family) }) { out.append(s) } }
        let n = Self.norm(id.family)

        if let dev = deviceFamily(for: id.family) { add(FontSuggestion(family: dev, note: "Exact font, on your iPhone", kind: .ready)) }
        if isInstalled(id.family) { add(FontSuggestion(family: actualFamily(id.family), note: "Exact font, downloaded", kind: .ready)) }
        if let g = googleCache, g.contains(where: { Self.norm($0) == n }) {
            add(FontSuggestion(family: id.family, note: "Exact font, free on Google Fonts", kind: isInstalled(id.family) ? .ready : .download))
        }
        if let pair = Self.substitutes[n] {
            let (sub, note) = pair
            if let dev = deviceFamily(for: sub) { add(FontSuggestion(family: dev, note: note, kind: .ready)) }
            else { add(FontSuggestion(family: sub, note: note + " · free", kind: isInstalled(sub) ? .ready : .download)) }
        }
        if out.isEmpty || googleCache == nil {
            add(FontSuggestion(family: id.family, note: "Try Google Fonts", kind: isInstalled(id.family) ? .ready : .download))
        }
        return out
    }

    func actualFamily(_ family: String) -> String {
        aliases[Self.norm(family)] ?? deviceFamily(for: family) ?? family
    }

    /// The fonts a page declares, read from the PDF itself.
    static func pageFonts(_ page: PDFPage) -> [String] {
        guard let cg = page.pageRef, let dict = cg.dictionary else { return [] }
        var names: [String] = []
        var res: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &res), let resources = res else { return [] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fontDict = fonts else { return [] }
        CGPDFDictionaryApplyBlock(fontDict, { _, obj, _ in
            var fd: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(obj, .dictionary, &fd), let f = fd {
                var base: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(f, "BaseFont", &base), let b = base { names.append(String(cString: b)) }
            }
            return true
        }, nil)
        var seen = Set<String>()
        return names.filter { seen.insert(parse($0).display).inserted }
    }

    // MARK: Install

    func registerInstalledFonts() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var families: [String] = []
        for folder in folders where FileStore.isDirectory(folder) {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            if let fam = register(files) {
                aliases[Self.norm(folder.lastPathComponent)] = fam
                aliases[Self.norm(fam)] = fam
                families.append(folder.lastPathComponent)
            }
        }
        let list = families.sorted()
        DispatchQueue.main.async { self.downloaded = list }
    }

    /// Registers font files for this app and returns their family name.
    @discardableResult
    private func register(_ files: [URL]) -> String? {
        var family: String?
        for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if family == nil, let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let d = descs.first, let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                family = fam
            }
        }
        return family
    }

    func download(family: String) async throws {
        let folderName = FileStore.sanitize(family)
        let dirName = family.lowercased().filter { $0.isLetter || $0.isNumber }
        struct Item: Decodable { let name: String; let download_url: String?; let type: String }
        for licence in ["ofl", "apache", "ufl"] {
            guard let api = URL(string: "https://api.github.com/repos/google/fonts/contents/\(licence)/\(dirName)") else { continue }
            var req = URLRequest(url: api)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("Kertas-iOS", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 { throw KertasError("Google Fonts is busy. Try again in a few minutes.") }
            guard code == 200, let items = try? JSONDecoder().decode([Item].self, from: data) else { continue }
            let ttfs = items.filter { $0.type == "file" && ($0.name.lowercased().hasSuffix(".ttf") || $0.name.lowercased().hasSuffix(".otf")) }
            guard !ttfs.isEmpty else { continue }
            let wanted = ttfs.filter { item in
                let l = item.name.lowercased()
                return l.contains("[") || l.hasSuffix("-regular.ttf") || l.hasSuffix("-bold.ttf") || l.hasSuffix("-italic.ttf") || l.hasSuffix("-bolditalic.ttf")
            }
            let pick = Array((wanted.isEmpty ? ttfs : wanted).prefix(8))
            let folder = dir.appendingPathComponent(folderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var saved: [URL] = []
            for item in pick {
                guard let s = item.download_url, let u = URL(string: s) else { continue }
                let (fontData, r) = try await URLSession.shared.data(from: u)
                guard (r as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let dest = folder.appendingPathComponent(item.name.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"))
                try fontData.write(to: dest)
                saved.append(dest)
            }
            guard let fam = register(saved) else { throw KertasError("The font files for \(family) couldn't be used.") }
            await MainActor.run {
                aliases[Self.norm(family)] = fam
                aliases[Self.norm(fam)] = fam
                if !downloaded.contains(folderName) { downloaded.append(folderName); downloaded.sort() }
            }
            return
        }
        throw KertasError("\(family) isn't on Google Fonts. Try a close match, or import the font file.")
    }

    func importFont(_ url: URL) throws -> String {
        guard let copy = FileStore.importCopy(url) else { throw KertasError("Couldn't read that file.") }
        let temp = [copy]
        guard let fam = register(temp) else { throw KertasError("That isn't a font file iOS can use.") }
        let folder = dir.appendingPathComponent(FileStore.sanitize(fam), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: copy, to: dest)
        aliases[Self.norm(fam)] = fam
        if !downloaded.contains(FileStore.sanitize(fam)) { downloaded.append(FileStore.sanitize(fam)); downloaded.sort() }
        return fam
    }

    func remove(_ folderName: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(folderName))
        downloaded.removeAll { $0 == folderName }
    }

    func googleFamilies() async -> [String] {
        if let g = googleCache { return g }
        let cache = dir.appendingPathComponent("google-families.json")
        if let d = try? Data(contentsOf: cache), let list = try? JSONDecoder().decode([String].self, from: d),
           Date().timeIntervalSince(FileStore.modified(cache)) < 30 * 86400 {
            await MainActor.run { self.googleCache = list }
            return list
        }
        guard let url = URL(string: "https://fonts.google.com/metadata/fonts"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return [] }
        var body = data
        if let brace = body.firstIndex(of: UInt8(ascii: "{")) { body = body.subdata(in: brace..<body.endIndex) }
        struct Meta: Decodable { struct Fam: Decodable { let family: String }; let familyMetadataList: [Fam] }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: body) else { return [] }
        let list = meta.familyMetadataList.map(\.family).sorted()
        try? JSONEncoder().encode(list).write(to: cache)
        await MainActor.run { self.googleCache = list }
        return list
    }

    /// Loads the Google list in the background so suggestions can say "exact font on Google Fonts".
    func warmUp() { Task { _ = await googleFamilies() } }

    // MARK: Use

    func font(family: String, bold: Bool, italic: Bool, size: CGFloat) -> UIFont {
        let size = max(size, 1)
        let fam = actualFamily(family)
        let names = UIFont.fontNames(forFamilyName: fam)
        guard !names.isEmpty else {
            var f = UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if italic, let d = f.fontDescriptor.withSymbolicTraits(.traitItalic) { f = UIFont(descriptor: d, size: size) }
            return f
        }
        var best: UIFont?
        var bestScore = Int.min
        for name in names {
            guard let f = UIFont(name: name, size: size) else { continue }
            let traits = f.fontDescriptor.symbolicTraits
            let low = name.lowercased()
            let isBold = traits.contains(.traitBold) || low.contains("bold")
            let isItalic = traits.contains(.traitItalic) || low.contains("italic") || low.contains("oblique")
            var score = 0
            score += isBold == bold ? 10 : -10
            score += isItalic == italic ? 8 : -8
            for odd in ["light", "thin", "black", "heavy", "condensed", "narrow", "extra", "semi", "medium", "ultra"] where low.contains(odd) { score -= 3 }
            if low.contains("regular") || !low.contains("-") { score += 1 }
            if score > bestScore { bestScore = score; best = f }
        }
        guard var chosen = best else { return UIFont.systemFont(ofSize: size) }
        // Variable fonts: set the weight axis when there's no separate bold file.
        if bold && !chosen.fontDescriptor.symbolicTraits.contains(.traitBold) {
            let wght = 0x77676874
            let axes = CTFontCopyVariationAxes(chosen as CTFont) as? [[String: Any]] ?? []
            if axes.contains(where: { ($0[kCTFontVariationAxisIdentifierKey as String] as? Int) == wght }) {
                let d = chosen.fontDescriptor.addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: 700]])
                chosen = UIFont(descriptor: d, size: size)
            }
        }
        return chosen
    }
}

/// What's under your finger when you tap a line of text.
struct DetectedText {
    var text: String
    var displayRect: CGRect
    var identity: FontIdentity
    var size: CGFloat
    var color: UIColor
}

enum TextDetector {
    static func detect(page: PDFPage, at p: CGPoint) -> DetectedText? {
        let pt = PageRenderer.pagePoint(p, on: page)
        guard let sel = page.selectionForLine(at: pt), let raw = sel.string,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounds = sel.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var fontName = ""
        var size: CGFloat = 0
        var color = UIColor.black
        if let attr = sel.attributedString, attr.length > 0 {
            let ns = attr.string as NSString
            var idx = 0
            while idx < ns.length, let c = Unicode.Scalar(ns.character(at: idx)), CharacterSet.whitespacesAndNewlines.contains(c) { idx += 1 }
            idx = min(idx, attr.length - 1)
            if let f = attr.attribute(.font, at: idx, effectiveRange: nil) as? UIFont { fontName = f.fontName; size = f.pointSize }
            if let c = attr.attribute(.foregroundColor, at: idx, effectiveRange: nil) as? UIColor { color = c }
        }
        let display = PageRenderer.displayRect(fromPage: bounds, on: page)
        let lineHeight = (PageRenderer.rotation(page) % 180 == 0) ? bounds.height : bounds.width
        if size <= 1 || size > lineHeight * 2 { size = lineHeight * 0.78 }
        var identity = FontLibrary.parse(fontName.isEmpty ? "Helvetica" : fontName)
        // PDFKit sometimes reports a stand-in font. If the page declares exactly one real font, trust that.
        let declared = FontLibrary.pageFonts(page).map(FontLibrary.parse)
        if !declared.isEmpty, !declared.contains(where: { FontLibrary.norm($0.family) == FontLibrary.norm(identity.family) }) {
            let sameStyle = declared.filter { $0.bold == identity.bold && $0.italic == identity.italic }
            if let only = (sameStyle.count == 1 ? sameStyle.first : (declared.count == 1 ? declared.first : nil)) { identity = only }
        }
        return DetectedText(text: raw.trimmingCharacters(in: .newlines), displayRect: display, identity: identity, size: size, color: color)
    }
}

enum ColorSampler {
    /// Median colour just outside a rectangle — the paper colour to hide old text with.
    static func surround(_ rect: CGRect, in image: UIImage) -> UIColor {
        guard let cg = image.cgImage else { return .white }
        let W = cg.width, H = cg.height
        let px = CGRect(x: rect.minX * CGFloat(W), y: rect.minY * CGFloat(H), width: rect.width * CGFloat(W), height: rect.height * CGFloat(H)).insetBy(dx: -3, dy: -3)
        let x0 = max(Int(px.minX), 0), x1 = min(Int(px.maxX), W - 1)
        let y0 = max(Int(px.minY), 0), y1 = min(Int(px.maxY), H - 1)
        guard x1 > x0, y1 > y0 else { return .white }
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.draw(cg, in: CGRect(x: -x0, y: -(H - 1 - y1), width: W, height: H))
        var samples: [(Int, Int, Int)] = []
        func take(_ x: Int, _ y: Int) {
            let i = (y * w + x) * 4
            samples.append((Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2])))
        }
        for x in 0..<w { take(x, 0); take(x, h - 1) }
        for y in 0..<h { take(0, y); take(w - 1, y) }
        guard !samples.isEmpty else { return .white }
        let sorted = samples.sorted { ($0.0 + $0.1 + $0.2) < ($1.0 + $1.1 + $1.2) }
        // Upper median favours paper over neighbouring ink.
        let m = sorted[min(sorted.count - 1, sorted.count * 2 / 3)]
        return UIColor(red: CGFloat(m.0) / 255, green: CGFloat(m.1) / 255, blue: CGFloat(m.2) / 255, alpha: 1)
    }
}
