import SwiftUI
import PDFKit
import PencilKit
import UniformTypeIdentifiers

struct TextEditSheet: View {
    @ObservedObject var model: EditModel
    let itemID: UUID
    @ObservedObject private var lib = FontLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var family = "Helvetica"
    @State private var bold = false
    @State private var italic = false
    @State private var size: Double = 12
    @State private var color: Color = .black
    @State private var identity: FontIdentity?
    @State private var pageFonts: [FontIdentity] = []
    @State private var downloading: String?
    @State private var problem: String?
    @State private var showImport = false
    @State private var loaded = false

    private var item: EditItem? { model.items.first { $0.id == itemID } }

    var body: some View {
        NavigationStack {
            Form {
                Section(item?.kind == .note ? "Note" : "Text") {
                    TextField(item?.kind == .note ? "Write a note" : "Type here", text: $text, axis: .vertical).lineLimit(1...8)
                }

                if item?.kind != .note {
                    if let id = identity {
                        Section("Font found in this text") {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(id.display).font(.headline)
                                    Text("\(Int(size.rounded())) pt · \(id.subset ? "partly embedded in the PDF" : "named in the PDF")")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if id.raw != id.display { Text(id.raw).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                let onPhone = lib.deviceFamily(for: id.family) != nil || lib.isInstalled(id.family)
                                Text(onPhone ? "On iPhone" : "Not on iPhone")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .foregroundStyle(onPhone ? Color(hex: 0x27500A) : Color(hex: 0xA32D2D))
                                    .background(onPhone ? Color(hex: 0xEAF3DE) : Theme.redSoft, in: Capsule())
                            }
                            if pageFonts.count > 1 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Other fonts on this page. Tap if the match looks wrong.").font(.caption).foregroundStyle(.secondary)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack {
                                            ForEach(pageFonts, id: \.raw) { f in
                                                Button(f.display) { pick(identity: f) }
                                                    .font(.caption)
                                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                                    .background(f == id ? Theme.redSoft : Theme.chip, in: Capsule())
                                                    .foregroundStyle(Theme.ink)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section("Use this font") {
                        if let id = identity {
                            ForEach(lib.suggestions(for: id)) { s in suggestionRow(s) }
                        }
                        NavigationLink {
                            FontSearchView(selected: family) { chosen in family = chosen }
                        } label: { Label("Search all fonts", systemImage: "magnifyingglass") }
                        Button { showImport = true } label: { Label("Import font file (.ttf, .otf)", systemImage: "square.and.arrow.down") }
                        if identity == nil {
                            HStack { Text("Current"); Spacer(); Text(family).foregroundStyle(.secondary) }
                        }
                    }

                    Section("Style") {
                        Stepper("Size \(String(format: "%.1f", size)) pt", value: $size, in: 4...144, step: 0.5)
                        Toggle("Bold", isOn: $bold)
                        Toggle("Italic", isOn: $italic)
                        ColorPicker("Colour", selection: $color, supportsOpacity: false)
                    }

                    Section("Preview") {
                        Text(text.isEmpty ? "Sample" : text)
                            .font(Font(lib.font(family: family, bold: bold, italic: italic, size: min(size * 1.6, 34))))
                            .foregroundStyle(color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle(item?.kind == .replace ? "Edit text" : (item?.kind == .note ? "Note" : "Add text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let it = item, it.kind != .replace, it.text.isEmpty { model.delete(itemID) }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { apply(); dismiss() }.bold() }
            }
            .alert("Font", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
            .documentPicker(isPresented: $showImport, types: [.font, UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data]) { urls in
                guard let url = urls.first else { return }
                do { family = try lib.importFont(url) } catch { problem = error.localizedDescription }
            }
        }
        .onAppear(perform: load)
        .task { _ = await lib.googleFamilies() }
    }

    @ViewBuilder private func suggestionRow(_ s: FontSuggestion) -> some View {
        let isSelected = FontLibrary.norm(lib.actualFamily(s.family)) == FontLibrary.norm(lib.actualFamily(family)) && s.kind == .ready
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.family)
                    .font(s.kind == .ready ? Font(lib.font(family: s.family, bold: false, italic: false, size: 17)) : .body)
                Text(s.note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.kind == .download {
                if downloading == s.family {
                    ProgressView()
                } else {
                    Button { download(s.family) } label: {
                        Label("Get", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
                            .font(.subheadline.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Theme.red, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                }
            } else if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Theme.red)
            } else {
                Button("Use") { family = s.family }.buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if s.kind == .ready { family = s.family } }
    }

    private func load() {
        guard !loaded, let it = item else { return }
        loaded = true
        text = it.text
        family = it.family
        bold = it.bold
        italic = it.italic
        size = Double(it.size)
        color = Color(it.color)
        identity = it.detected
        if it.kind == .replace, let page = model.doc.page(at: it.page) {
            pageFonts = FontLibrary.pageFonts(page).map(FontLibrary.parse)
        }
    }

    private func pick(identity id: FontIdentity) {
        identity = id
        bold = id.bold
        italic = id.italic
        if let ready = lib.suggestions(for: id).first(where: { $0.kind == .ready }) { family = ready.family } else { family = id.family }
    }

    private func download(_ fam: String) {
        downloading = fam
        Task {
            do {
                try await lib.download(family: fam)
                await MainActor.run { family = fam; downloading = nil }
            } catch {
                await MainActor.run { problem = error.localizedDescription; downloading = nil }
            }
        }
    }

    private func apply() {
        guard item != nil else { return }
        model.snapshot()
        model.update(itemID) { it in
            it.text = text
            it.family = family
            it.bold = bold
            it.italic = italic
            it.size = CGFloat(size)
            it.color = UIColor(color)
            it.detected = identity
        }
        model.fitText(itemID)
        if let it = item, it.kind == .text, it.text.isEmpty { model.delete(itemID) }
    }
}

// MARK: - Font search

struct FontSearchView: View {
    var selected: String
    var onPick: (String) -> Void
    @ObservedObject private var lib = FontLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var google: [String] = []
    @State private var downloading: String?
    @State private var problem: String?

    private var device: [String] { UIFont.familyNames.sorted() }

    private func filter(_ list: [String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        List {
            if !lib.downloaded.isEmpty {
                Section("Downloaded") {
                    ForEach(filter(lib.downloaded), id: \.self) { f in
                        row(f, ready: true)
                            .swipeActions { Button(role: .destructive) { lib.remove(f) } label: { Label("Remove", systemImage: "trash") } }
                    }
                }
            }
            Section("Google Fonts (free)") {
                if google.isEmpty {
                    if query.isEmpty {
                        HStack { ProgressView(); Text("Loading the list…").foregroundStyle(.secondary) }
                    } else {
                        row(query.trimmingCharacters(in: .whitespaces), ready: false)
                    }
                }
                ForEach(filter(google).prefix(query.isEmpty ? 60 : 300), id: \.self) { f in
                    row(f, ready: lib.isInstalled(f))
                }
            }
            Section("On iPhone") {
                ForEach(filter(device), id: \.self) { f in row(f, ready: true) }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Font name")
        .navigationTitle("Fonts")
        .navigationBarTitleDisplayMode(.inline)
        .task { google = await lib.googleFamilies() }
        .alert("Font", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private func row(_ f: String, ready: Bool) -> some View {
        HStack {
            Text(f).font(ready ? Font(lib.font(family: f, bold: false, italic: false, size: 17)) : .body)
            Spacer()
            if downloading == f {
                ProgressView()
            } else if !ready {
                Image(systemName: "arrow.down.circle").foregroundStyle(Theme.red)
            } else if FontLibrary.norm(f) == FontLibrary.norm(selected) {
                Image(systemName: "checkmark").foregroundStyle(Theme.red)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if ready { onPick(f); dismiss(); return }
            downloading = f
            Task {
                do {
                    try await lib.download(family: f)
                    await MainActor.run { downloading = nil; onPick(f); dismiss() }
                } catch {
                    await MainActor.run { downloading = nil; problem = error.localizedDescription }
                }
            }
        }
    }
}

// MARK: - Signatures

enum SignatureStore {
    static var dir: URL { FileStore.support("Signatures") }
    private static let defaultKey = "defaultSignature"

    static func all() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { FileStore.modified($0) > FileStore.modified($1) }
    }

    @discardableResult
    static func save(_ img: UIImage) -> URL? {
        guard let d = img.pngData() else { return nil }
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        do { try d.write(to: url) } catch { return nil }
        if defaultURL == nil { setDefault(url) }
        return url
    }

    static var defaultURL: URL? {
        guard let name = UserDefaults.standard.string(forKey: defaultKey) else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var defaultImage: UIImage? { defaultURL.flatMap { UIImage(contentsOfFile: $0.path) } }

    static func setDefault(_ url: URL?) {
        UserDefaults.standard.set(url?.lastPathComponent, forKey: defaultKey)
    }

    static func delete(_ url: URL) {
        if defaultURL == url { setDefault(nil) }
        try? FileManager.default.removeItem(at: url)
        if defaultURL == nil, let first = all().first { setDefault(first) }
    }

    /// Makes white or light paper see-through and trims the empty edges,
    /// so a photo or scan of a signature sits cleanly on the page.
    static func cleaned(_ source: UIImage) -> UIImage {
        let img = source.normalized(maxSide: 1600)
        guard let cg = img.cgImage else { return img }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Only knock out the background when there's no transparency already.
        var hasAlpha = false
        for i in stride(from: 3, to: buf.count, by: 4 * 7) where buf[i] < 250 { hasAlpha = true; break }

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if !hasAlpha {
                    let r = Double(buf[i]), g = Double(buf[i + 1]), b = Double(buf[i + 2])
                    let lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
                    // Paper → clear, ink → solid, a soft ramp in between keeps edges smooth.
                    let a = lum > 0.82 ? 0.0 : (lum < 0.55 ? 1.0 : (0.82 - lum) / 0.27)
                    let alpha = UInt8(a * 255)
                    buf[i] = UInt8(r * a); buf[i + 1] = UInt8(g * a); buf[i + 2] = UInt8(b * a); buf[i + 3] = alpha
                }
                if buf[i + 3] > 24 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX > minX, maxY > minY, let out = ctx.makeImage() else { return img }
        let pad = 8
        let crop = CGRect(x: max(minX - pad, 0), y: max(minY - pad, 0),
                          width: min(maxX - minX + 2 * pad, w - max(minX - pad, 0)),
                          height: min(maxY - minY + 2 * pad, h - max(minY - pad, 0)))
        guard let cropped = out.cropping(to: crop) else { return UIImage(cgImage: out) }
        return UIImage(cgImage: cropped)
    }
}

struct SignatureSheet: View {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [URL] = SignatureStore.all()
    @State private var defaultURL: URL? = SignatureStore.defaultURL
    @State private var drawing = PKDrawing()
    @State private var ink: UIColor = .black
    @State private var drawingNew = false
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if drawingNew {
                    Text("Sign inside the box").font(.subheadline).foregroundStyle(.secondary)
                    SignaturePad(drawing: $drawing, color: ink)
                        .frame(height: 220)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 24).padding(.bottom, 50) }
                    HStack(spacing: 16) {
                        ForEach([UIColor.black, UIColor(red: 0.1, green: 0.25, blue: 0.75, alpha: 1)], id: \.self) { c in
                            Circle().fill(Color(c)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Theme.red, lineWidth: ink == c ? 2 : 0).padding(-3))
                                .onTapGesture { ink = c }
                        }
                        Spacer()
                        Button("Clear") { drawing = PKDrawing() }
                    }
                    Button("Use signature") {
                        guard let img = trimmed() else { return }
                        SignatureStore.save(img)
                        onPick(img)
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(drawing.strokes.isEmpty)
                    Button("Back") { drawingNew = false; drawing = PKDrawing() }.font(.subheadline)
                } else {
                    if saved.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "signature").font(.system(size: 40)).foregroundStyle(Theme.red)
                            Text("No signature yet").font(.headline)
                            Text("Import a picture of your signature, or draw one with your finger.")
                                .font(.subheadline).foregroundStyle(Theme.grey).multilineTextAlignment(.center)
                        }
                        .padding(.vertical, 24)
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(saved, id: \.self) { url in
                                    if let img = UIImage(contentsOfFile: url.path) { row(url, img) }
                                }
                            }
                        }
                        Text("Tap a signature to use it. Tap the star to make it your default, so Sign places it straight away.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    Button { showImport = true } label: { Label("Import signature", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PrimaryButtonStyle())
                    Button { drawingNew = true } label: { Label("Draw a new signature", systemImage: "signature") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer(minLength: 0)
            }
            .padding()
            .background(Theme.page)
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .documentPicker(isPresented: $showImport, types: [.png, .jpeg, .heic, .image]) { urls in
                guard let url = urls.first, let raw = UIImage(contentsOfFile: url.path) else { return }
                let img = SignatureStore.cleaned(raw)
                if let saved = SignatureStore.save(img) {
                    SignatureStore.setDefault(saved)
                }
                reload()
            }
        }
    }

    private func row(_ url: URL, _ img: UIImage) -> some View {
        let isDefault = url == defaultURL
        return Button { onPick(img); dismiss() } label: {
            Image(uiImage: img).resizable().scaledToFit().frame(height: 80).frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(isDefault ? Theme.red : Theme.line, lineWidth: isDefault ? 1.5 : 0.5))
                .overlay(alignment: .topTrailing) {
                    Button {
                        SignatureStore.setDefault(url)
                        reload()
                    } label: {
                        if isDefault {
                            Label("Default", systemImage: "star.fill").font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Theme.red, in: Capsule())
                        } else {
                            Image(systemName: "star").foregroundStyle(Theme.grey).padding(4)
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
        }
        .contextMenu {
            Button { SignatureStore.setDefault(url); reload() } label: { Label("Make default", systemImage: "star") }
            Button(role: .destructive) { SignatureStore.delete(url); reload() } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func reload() {
        saved = SignatureStore.all()
        defaultURL = SignatureStore.defaultURL
    }

    private func trimmed() -> UIImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let b = drawing.bounds.insetBy(dx: -8, dy: -8)
        var img: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            img = drawing.image(from: b, scale: 3)
        }
        return img
    }
}

struct SignaturePad: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var color: UIColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.overrideUserInterfaceStyle = .light
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        v.tool = PKInkingTool(.pen, color: color, width: 4)
        if drawing.strokes.isEmpty && !v.drawing.strokes.isEmpty { v.drawing = drawing }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SignaturePad
        init(_ p: SignaturePad) { parent = p }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { parent.drawing = canvasView.drawing }
    }
}
