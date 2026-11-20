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
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.font, UTType(filenameExtension: "ttf") ?? .data, UTType(filenameExtension: "otf") ?? .data]) { result in
                if case .success(let url) = result {
                    do { family = try lib.importFont(url) } catch { problem = error.localizedDescription }
                }
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
    static func all() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { FileStore.modified($0) > FileStore.modified($1) }
    }
    static func save(_ img: UIImage) {
        if let d = img.pngData() { try? d.write(to: dir.appendingPathComponent(UUID().uuidString + ".png")) }
    }
}

struct SignatureSheet: View {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saved: [URL] = SignatureStore.all()
    @State private var drawing = PKDrawing()
    @State private var ink: UIColor = .black
    @State private var drawingNew = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if drawingNew || saved.isEmpty {
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
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(saved, id: \.self) { url in
                                if let img = UIImage(contentsOfFile: url.path) {
                                    Button { onPick(img); dismiss() } label: {
                                        Image(uiImage: img).resizable().scaledToFit().frame(height: 80).frame(maxWidth: .infinity)
                                            .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) { try? FileManager.default.removeItem(at: url); saved = SignatureStore.all() } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            }
                        }
                    }
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
        }
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
