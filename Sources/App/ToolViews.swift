import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

extension View {
    func preset(_ url: URL?, into urls: Binding<[URL]>) -> some View {
        onAppear { if urls.wrappedValue.isEmpty, let u = url { urls.wrappedValue = [u] } }
    }
}

private func summary(_ url: URL) -> String {
    FileStore.sizeText(FileStore.size(url))
}

// MARK: Merge

struct MergeView: View {
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []

    var body: some View {
        ToolPage(tool: .merge, state: state) {
            InputPicker(urls: $inputs, types: [.pdf, .image], multiple: true, label: "Choose PDFs")
            if inputs.count >= 2 {
                Text("Use the arrows to set the order.").font(.caption).foregroundStyle(.secondary)
                Button("Merge \(inputs.count) files") {
                    let files = inputs
                    state.run("Merging") { rep in
                        let doc = try PDFOps.merge(files, progress: rep)
                        let url = try FileStore.save(doc, base: FileStore.baseName(files[0]) + " merged")
                        return ToolOutput(urls: [url], message: "\(doc.pageCount) pages · \(summary(url))")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.merge.color))
            }
        }
    }
}

// MARK: Split

struct SplitView: View {
    var preset: URL?
    enum Mode: String, CaseIterable, Identifiable { case ranges = "By ranges", every = "Every N pages", all = "Every page"; var id: String { rawValue } }
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var mode: Mode = .ranges
    @State private var ranges = "1-2, 3-"
    @State private var every = 2
    @State private var mergeRanges = false

    var body: some View {
        ToolPage(tool: .split, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    Picker("Mode", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    switch mode {
                    case .ranges:
                        TextField("Ranges, for example 1-3, 5, 8-", text: $ranges).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                        Toggle("Merge all ranges into one PDF", isOn: $mergeRanges)
                    case .every:
                        Stepper("Every \(every) pages", value: $every, in: 1...500)
                    case .all:
                        Text("Each page becomes its own PDF.").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Button("Split PDF") { run(url) }.buttonStyle(PrimaryButtonStyle(color: Tool.split.color))
            }
        }
        .preset(preset, into: $inputs)
    }

    private func run(_ url: URL) {
        let mode = mode, ranges = ranges, every = every, merge = mergeRanges
        state.run("Splitting") { rep in
            let doc = try PDFLoader.open(url)
            let n = doc.pageCount
            var groups: [[Int]]
            switch mode {
            case .ranges:
                guard let g = PageRanges.parse(ranges, pageCount: n) else { throw KertasError("Those ranges don't fit this \(n)-page PDF.") }
                groups = merge ? [g.flatMap { $0 }] : g
            case .every: groups = stride(from: 0, to: n, by: every).map { Array($0..<min($0 + every, n)) }
            case .all: groups = (0..<n).map { [$0] }
            }
            let base = FileStore.baseName(url)
            if groups.count == 1 {
                let out = try FileStore.save(PDFOps.subset(doc, pages: groups[0]), base: base + " pages")
                return ToolOutput(urls: [out], message: "\(groups[0].count) pages")
            }
            let folder = FileStore.folder(named: base + " split")
            for (k, g) in groups.enumerated() {
                rep(Double(k) / Double(groups.count), "Saving part \(k + 1) of \(groups.count)")
                let part = PDFOps.subset(doc, pages: g)
                try part.dataRepresentation()?.write(to: folder.appendingPathComponent("\(base) \(PageRanges.label(g)).pdf"))
            }
            FileStore.notify()
            return ToolOutput(urls: [folder], message: "\(groups.count) PDFs in a folder")
        }
    }
}

// MARK: Compress

struct CompressView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var level: PDFOps.CompressLevel = .recommended

    var body: some View {
        ToolPage(tool: .compress, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    ForEach(PDFOps.CompressLevel.allCases) { l in
                        Button { level = l } label: {
                            HStack(alignment: .top) {
                                Image(systemName: level == l ? "largecircle.fill.circle" : "circle").foregroundStyle(Tool.compress.color)
                                VStack(alignment: .leading) {
                                    Text(l.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text(l.note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Button("Compress PDF") {
                    let l = level
                    state.run("Compressing") { rep in
                        let before = FileStore.size(url)
                        let data = try PDFOps.compress(url, level: l, progress: rep)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " compressed", ext: "pdf")
                        let after = FileStore.size(out)
                        let saved = before > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0
                        let msg = saved > 0 ? "\(FileStore.sizeText(before)) → \(FileStore.sizeText(after)), \(saved)% smaller"
                                            : "This PDF was already well optimised (\(FileStore.sizeText(after))). Try Extreme for a smaller file."
                        return ToolOutput(urls: [out], message: msg)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.compress.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: Repair

struct RepairView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []

    var body: some View {
        ToolPage(tool: .repair, state: state) {
            InputPicker(urls: $inputs, types: [.pdf, .data])
            if let url = inputs.first {
                Button("Repair PDF") {
                    state.run("Repairing") { rep in
                        let (data, pages) = try PDFOps.repair(url, progress: rep)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " repaired", ext: "pdf")
                        return ToolOutput(urls: [out], message: "Recovered \(pages) page\(pages == 1 ? "" : "s")")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.repair.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: OCR

struct OCRView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var force = false

    var body: some View {
        ToolPage(tool: .ocr, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    Toggle("Also redo pages that already have text", isOn: $force)
                    Text("Text is read on your iPhone. Works best with English and other Latin-script languages, including Malay.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Make searchable") {
                    let f = force
                    state.run("Reading text") { rep in
                        let doc = try PDFLoader.open(url)
                        let (data, pages) = OCR.searchable(doc, force: f, progress: rep)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " OCR", ext: "pdf")
                        return ToolOutput(urls: [out], message: pages == 0 ? "No new text was found." : "Text added to \(pages) page\(pages == 1 ? "" : "s")")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.ocr.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: Images to PDF

struct ImagesToPDFView: View {
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var fit: PDFOps.PageFit = .a4
    @State private var margin: PDFOps.Margin = .small
    @State private var separate = false
    @State private var straighten = false

    var body: some View {
        ToolPage(tool: .jpgToPdf, state: state) {
            InputPicker(urls: $inputs, types: [.image], multiple: true, photos: true, label: "Choose images")
            if !inputs.isEmpty {
                Card {
                    OptionRow(title: "Page size") { Picker("", selection: $fit) { ForEach(PDFOps.PageFit.allCases) { Text($0.rawValue).tag($0) } } }
                    OptionRow(title: "Margin") { Picker("", selection: $margin) { ForEach(PDFOps.Margin.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 190) }
                    Toggle("Straighten documents in photos", isOn: $straighten)
                    Toggle("One PDF per image", isOn: $separate)
                }
                Button("Convert to PDF") { run() }.buttonStyle(PrimaryButtonStyle(color: Tool.jpgToPdf.color))
            }
        }
    }

    private func run() {
        let files = inputs, fit = fit, margin = margin, separate = separate, straighten = straighten
        state.run("Converting") { rep in
            let images: [UIImage] = files.compactMap { url in
                guard let img = UIImage(contentsOfFile: url.path)?.normalized(maxSide: 3500) else { return nil }
                guard straighten else { return img }
                return Perspective.apply(.auto, to: Perspective.correct(img, quad: Perspective.detect(img)))
            }
            guard !images.isEmpty else { throw KertasError("Those images couldn't be read.") }
            if separate {
                var urls: [URL] = []
                for (i, img) in images.enumerated() {
                    let d = PDFOps.imagesToPDF([img], fit: fit, margin: margin, progress: nil)
                    urls.append(try FileStore.save(d, base: FileStore.baseName(files[i]), ext: "pdf"))
                }
                return ToolOutput(urls: urls, message: "\(urls.count) PDFs")
            }
            let d = PDFOps.imagesToPDF(images, fit: fit, margin: margin, progress: rep)
            let url = try FileStore.save(d, base: "Images \(Date().formatted(.dateTime.year().month().day()))", ext: "pdf")
            return ToolOutput(urls: [url], message: "\(images.count) pages · \(summary(url))")
        }
    }
}

// MARK: PDF to JPG

struct PDFToJPGView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var dpi: Double = 150

    var body: some View {
        ToolPage(tool: .pdfToJpg, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    OptionRow(title: "Quality") {
                        Picker("", selection: $dpi) {
                            Text("Normal").tag(110.0); Text("High").tag(150.0); Text("Best").tag(300.0)
                        }.pickerStyle(.segmented).frame(width: 210)
                    }
                }
                Button("Convert to JPG") {
                    let d = CGFloat(dpi)
                    state.run("Converting") { rep in
                        let folder = try PDFOps.pdfToImages(url, dpi: d, progress: rep)
                        let count = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
                        return ToolOutput(urls: [folder], message: "\(count) images in a folder")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.pdfToJpg.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

struct ExtractImagesView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []

    var body: some View {
        ToolPage(tool: .extractImages, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Button("Extract images") {
                    state.run("Looking for pictures") { rep in
                        let (folder, n) = try PDFOps.extractImages(url, progress: rep)
                        return ToolOutput(urls: [folder], message: "\(n) picture\(n == 1 ? "" : "s") found")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.extractImages.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: PDF to text

struct PDFToTextView: View {
    var preset: URL?
    enum Format: String, CaseIterable, Identifiable { case text = "Plain text", markdown = "Markdown"; var id: String { rawValue } }
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var format: Format = .text

    var body: some View {
        ToolPage(tool: .pdfToText, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Picker("Format", selection: $format) { ForEach(Format.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Button("Get text") {
                    let f = format
                    state.run("Reading") { rep in
                        let doc = try PDFLoader.open(url)
                        let text = f == .text ? PDFOps.plainText(doc, progress: rep) : PDFOps.markdown(doc, progress: rep)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KertasError("No text was found.") }
                        let out = try FileStore.save(Data(text.utf8), base: FileStore.baseName(url), ext: f == .text ? "txt" : "md")
                        return ToolOutput(urls: [out], text: String(text.prefix(4000)) + (text.count > 4000 ? "\n…" : ""), message: "\(text.count) characters")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.pdfToText.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: Page numbers

struct PageNumbersView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var spot: PDFOps.Spot = .bottomCentre
    @State private var format: PDFOps.NumberFormat = .plain
    @State private var startAt = 1
    @State private var fromPage = 1
    @State private var size: Double = 10
    @State private var colour: Color = .black

    var body: some View {
        ToolPage(tool: .pageNumbers, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    SectionLabel("Position")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                        ForEach(PDFOps.Spot.allCases) { s in
                            Button { spot = s } label: {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(spot == s ? Tool.pageNumbers.color : Theme.chip)
                                    .frame(height: 30)
                                    .overlay(Text(s.rawValue).font(.caption2).foregroundStyle(spot == s ? .white : Theme.ink))
                            }
                        }
                    }
                    OptionRow(title: "Format") { Picker("", selection: $format) { ForEach(PDFOps.NumberFormat.allCases) { Text($0.rawValue).tag($0) } } }
                    Stepper("Start counting at \(startAt)", value: $startAt, in: 0...9999)
                    Stepper("Number from page \(fromPage)", value: $fromPage, in: 1...9999)
                    OptionRow(title: "Text size \(Int(size))") { Slider(value: $size, in: 6...24, step: 1).frame(width: 150) }
                    ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                }
                Button("Add page numbers") {
                    let s = spot, f = format, a = startAt, from = fromPage, sz = CGFloat(size), c = UIColor(colour)
                    state.run("Numbering") { rep in
                        let doc = try PDFLoader.open(url)
                        let data = PDFOps.pageNumbers(doc, spot: s, format: f, startAt: a, fromPage: from, fontSize: sz, color: c, margin: 24, progress: rep)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " numbered", ext: "pdf")
                        return ToolOutput(urls: [out], message: "\(doc.pageCount) pages")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.pageNumbers.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: Watermark

struct WatermarkView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var useImage = false
    @State private var text = "CONFIDENTIAL"
    @State private var size: Double = 48
    @State private var colour: Color = .red
    @State private var opacity: Double = 0.25
    @State private var angle: Double = 45
    @State private var place: PDFOps.WatermarkPlace = .centre
    @State private var behind = false
    @State private var imageItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var imageScale: Double = 0.4

    var body: some View {
        ToolPage(tool: .watermark, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    Picker("Type", selection: $useImage) { Text("Text").tag(false); Text("Image").tag(true) }.pickerStyle(.segmented)
                    if useImage {
                        PhotosPicker(selection: $imageItem, matching: .images) {
                            HStack {
                                if let image { Image(uiImage: image).resizable().scaledToFit().frame(height: 40) }
                                Text(image == nil ? "Choose image" : "Change image")
                            }
                        }
                        OptionRow(title: "Size") { Slider(value: $imageScale, in: 0.1...1).frame(width: 160) }
                    } else {
                        TextField("Watermark text", text: $text).textFieldStyle(.roundedBorder)
                        OptionRow(title: "Text size \(Int(size))") { Slider(value: $size, in: 12...120, step: 1).frame(width: 150) }
                        ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                    }
                    OptionRow(title: "See-through \(Int((1 - opacity) * 100))%") { Slider(value: $opacity, in: 0.05...1).frame(width: 150) }
                    OptionRow(title: "Angle \(Int(angle))°") { Slider(value: $angle, in: -90...90, step: 5).frame(width: 150) }
                    OptionRow(title: "Position") { Picker("", selection: $place) { ForEach(PDFOps.WatermarkPlace.allCases) { Text($0.rawValue).tag($0) } } }
                    Toggle("Put it behind the page content", isOn: $behind)
                }
                Button("Add watermark") {
                    let t = useImage ? nil : text, img = useImage ? image : nil
                    let sz = CGFloat(size), c = UIColor(colour), o = CGFloat(opacity), a = CGFloat(angle), p = place, b = behind, sc = CGFloat(imageScale)
                    state.run("Stamping") { rep in
                        let doc = try PDFLoader.open(url)
                        let data = PDFOps.watermark(doc, text: t, image: img, fontSize: sz, color: c, opacity: o, angle: a, place: p, behind: b, imageScale: sc, progress: rep)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " watermarked", ext: "pdf")
                        return ToolOutput(urls: [out])
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.watermark.color))
                .disabled(useImage ? image == nil : text.isEmpty)
            }
        }
        .preset(preset, into: $inputs)
        .onChange(of: imageItem) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    await MainActor.run { image = img.normalized(maxSide: 2000) }
                }
            }
        }
    }
}

// MARK: Protect and unlock

struct ProtectView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var password = ""
    @State private var repeatPassword = ""

    var body: some View {
        ToolPage(tool: .protect, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    SecureField("Type it again", text: $repeatPassword).textFieldStyle(.roundedBorder)
                    if !repeatPassword.isEmpty && password != repeatPassword {
                        Text("The passwords don't match.").font(.caption).foregroundStyle(Theme.red)
                    }
                }
                Button("Protect PDF") {
                    let pw = password
                    state.run("Locking") { _ in
                        let data = try PDFOps.protect(url, password: pw)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " protected", ext: "pdf")
                        return ToolOutput(urls: [out], message: "Anyone opening it will need the password.")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.protect.color))
                .disabled(password.isEmpty || password != repeatPassword)
            }
        }
        .preset(preset, into: $inputs)
    }
}

struct UnlockView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var password = ""

    var body: some View {
        ToolPage(tool: .unlock, state: state) {
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Card {
                    SecureField("Current password", text: $password).textFieldStyle(.roundedBorder)
                    Text("Leave empty if the PDF opens without a password but blocks printing or copying.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Unlock PDF") {
                    let pw = password
                    state.run("Unlocking") { _ in
                        let data = try PDFOps.unlock(url, password: pw)
                        let out = try FileStore.save(data, base: FileStore.baseName(url) + " unlocked", ext: "pdf")
                        return ToolOutput(urls: [out], message: "Password removed.")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.unlock.color))
            }
        }
        .preset(preset, into: $inputs)
    }
}

// MARK: Forms

struct FormsView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var doc: PDFDocument?
    @State private var fieldCount = 0

    var body: some View {
        Group {
            if let doc, state.output == nil {
                VStack(spacing: 0) {
                    if fieldCount == 0 {
                        Text("This PDF has no fillable boxes. Use Edit PDF to type anywhere on it.")
                            .font(.footnote).padding(10).frame(maxWidth: .infinity).background(Theme.redSoft)
                    } else {
                        Text("Tap a box to fill it in.").font(.footnote).padding(8).frame(maxWidth: .infinity).background(Theme.chip)
                    }
                    PDFKitView(document: doc)
                }
                .navigationTitle(Tool.forms.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let base = FileStore.baseName(inputs[0])
                            state.run("Saving") { _ in
                                let url = try FileStore.save(doc, base: base + " filled")
                                return ToolOutput(urls: [url])
                            }
                        }.bold()
                    }
                }
                .overlay { if state.busy { BusyOverlay(text: state.text, fraction: nil) } }
            } else {
                ToolPage(tool: .forms, state: state) {
                    InputPicker(urls: $inputs)
                }
            }
        }
        .preset(preset, into: $inputs)
        .onChange(of: inputs) { _, urls in load(urls.first) }
        .onAppear { if doc == nil { load(inputs.first) } }
    }

    private func load(_ url: URL?) {
        guard let url else { doc = nil; return }
        do {
            let d = try PDFLoader.open(url)
            var n = 0
            for i in 0..<d.pageCount { n += d.page(at: i)?.annotations.filter { $0.type == "Widget" }.count ?? 0 }
            fieldCount = n
            doc = d
        } catch { state.error = error.localizedDescription; inputs = [] }
    }
}
