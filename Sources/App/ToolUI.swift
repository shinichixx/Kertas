import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct ToolOutput {
    var urls: [URL]
    var text: String? = nil
    var message: String? = nil
}

final class ProgressReporter {
    private let handler: (Double?, String) -> Void
    init(_ h: @escaping (Double?, String) -> Void) { handler = h }
    func callAsFunction(_ fraction: Double?, _ text: String) {
        DispatchQueue.main.async { self.handler(fraction, text) }
    }
}

final class ToolState: ObservableObject {
    @Published var busy = false
    @Published var text = ""
    @Published var fraction: Double?
    @Published var output: ToolOutput?
    @Published var error: String?

    var reporter: ProgressReporter {
        ProgressReporter { [weak self] f, t in
            self?.fraction = f
            self?.text = t
        }
    }

    /// Runs heavy work off the main thread.
    func run(_ label: String, _ work: @escaping (ProgressReporter) throws -> ToolOutput) {
        busy = true; text = label; fraction = nil
        let rep = reporter
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let out = try work(rep)
                DispatchQueue.main.async { self.output = out; self.busy = false }
            } catch is CancelSilently {
                DispatchQueue.main.async { self.busy = false }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription; self.busy = false }
            }
        }
    }

    /// Runs work that has to touch UIKit (web views, AI sessions) on the main actor.
    @MainActor
    func runMain(_ label: String, _ work: @escaping @MainActor (ProgressReporter) async throws -> ToolOutput) {
        busy = true; text = label; fraction = nil
        let rep = reporter
        Task { @MainActor in
            do {
                let out = try await work(rep)
                self.output = out
            } catch {
                self.error = error.localizedDescription
            }
            self.busy = false
        }
    }
}

struct BusyOverlay: View {
    let text: String
    let fraction: Double?
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 14) {
                if let f = fraction {
                    ProgressView(value: f).tint(Theme.red).frame(width: 180)
                } else {
                    ProgressView().controlSize(.large).tint(Theme.red)
                }
                Text(text).font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Theme.ink)
            }
            .padding(24)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            .padding(40)
        }
    }
}

/// Standard layout for a tool: header, content, busy overlay, and the result once done.
struct ToolPage<Content: View>: View {
    let tool: Tool
    @ObservedObject var state: ToolState
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            if let out = state.output {
                ResultView(tool: tool, output: out) { state.output = nil }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            ToolIcon(tool: tool, size: 20)
                            Text(tool.subtitle).font(.subheadline).foregroundStyle(Theme.grey)
                        }
                        content()
                    }
                    .padding()
                }
                .background(Theme.page)
            }
        }
        .overlay { if state.busy { BusyOverlay(text: state.text, fraction: state.fraction) } }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't finish", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(state.error ?? "") }
    }
}

// MARK: - Picking files

struct InputPicker: View {
    @Binding var urls: [URL]
    var types: [UTType] = [.pdf]
    var multiple = false
    var photos = false
    var label = "Choose PDF"

    @State private var showImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showRecent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !urls.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(urls.enumerated()), id: \.element) { i, url in
                        HStack(spacing: 10) {
                            FileThumb(url: url).frame(width: 34, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent).font(.subheadline).lineLimit(1)
                                Text(info(url)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if multiple && urls.count > 1 {
                                Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                                Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == urls.count - 1)
                            }
                            Button { urls.remove(at: i) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 8)
                        if i < urls.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 0.5))
            }

            if urls.isEmpty || multiple {
                HStack(spacing: 10) {
                    Button { showImporter = true } label: {
                        Label(urls.isEmpty ? label : "Add more", systemImage: "folder")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    if photos {
                        PhotosPicker(selection: $photoItems, maxSelectionCount: multiple ? 50 : 1, matching: .images) {
                            Label("Photos", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    } else if types.contains(.pdf) {
                        Button { showRecent = true } label: { Label("Kertas files", systemImage: "clock") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .documentPicker(isPresented: $showImporter, types: types, multiple: multiple) { copies in
            if multiple { urls.append(contentsOf: copies) } else { urls = Array(copies.prefix(1)) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var added: [URL] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data), let jpg = img.normalized().jpegData(compressionQuality: 0.92) {
                        let url = FileStore.uniqueURL(base: "Photo", ext: "jpg", in: FileStore.inbox)
                        try? jpg.write(to: url)
                        added.append(url)
                    }
                }
                await MainActor.run {
                    if multiple { urls.append(contentsOf: added) } else { urls = Array(added.prefix(1)) }
                    photoItems = []
                }
            }
        }
        .sheet(isPresented: $showRecent) {
            RecentPicker(multiple: multiple) { picked in
                if multiple { urls.append(contentsOf: picked) } else { urls = Array(picked.prefix(1)) }
            }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard j >= 0, j < urls.count else { return }
        urls.swapAt(i, j)
    }

    private func info(_ url: URL) -> String {
        var parts = [FileStore.sizeText(FileStore.size(url))]
        if url.pathExtension.lowercased() == "pdf", let d = PDFDocument(url: url) {
            parts.insert(d.isLocked ? "Locked" : "\(d.pageCount) page\(d.pageCount == 1 ? "" : "s")", at: 0)
        }
        return parts.joined(separator: " · ")
    }
}

struct RecentPicker: View {
    var multiple: Bool
    var onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []

    var body: some View {
        NavigationStack {
            let files = FileStore.pdfs()
            List(files, id: \.self) { url in
                Button {
                    if multiple {
                        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
                    } else { onPick([url]); dismiss() }
                } label: {
                    HStack {
                        FileThumb(url: url).frame(width: 30, height: 40)
                        Text(url.lastPathComponent).lineLimit(1).foregroundStyle(Theme.ink)
                        Spacer()
                        if selected.contains(url) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.red) }
                    }
                }
            }
            .overlay { if files.isEmpty { ContentUnavailableView("No PDFs yet", systemImage: "doc", description: Text("Files you make in Kertas show up here.")) } }
            .navigationTitle("Kertas files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if multiple {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") { onPick(files.filter { selected.contains($0) }); dismiss() }.disabled(selected.isEmpty)
                    }
                }
            }
        }
    }
}

// MARK: - Result

struct ResultView: View {
    let tool: Tool
    let output: ToolOutput
    var onAgain: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.title).foregroundStyle(Color(hex: 0x4E9A2B))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Done").font(.title3.weight(.semibold))
                        if let m = output.message { Text(m).font(.subheadline).foregroundStyle(Theme.grey) }
                    }
                }

                if let text = output.text {
                    Card {
                        Text(text).font(.body).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy text") {
                            UIPasteboard.general.string = text
                            copied = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                if output.urls.count == 1, let url = output.urls.first, url.pathExtension.lowercased() == "pdf" {
                    PDFKitView(url: url)
                        .frame(height: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 0.5))
                }

                if !output.urls.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(output.urls, id: \.self) { url in
                            Button { preview = url } label: {
                                HStack(spacing: 10) {
                                    FileThumb(url: url).frame(width: 34, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent).font(.subheadline).lineLimit(1).foregroundStyle(Theme.ink)
                                        Text(FileStore.sizeText(FileStore.size(url))).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "eye").foregroundStyle(Theme.grey)
                                }
                                .padding(.vertical, 8)
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))

                    ShareLink(items: shareURLs) {
                        Label("Share or save", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Text("Also saved in Files › On My iPhone › Kertas.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("Start again") { onAgain() }.buttonStyle(SecondaryButtonStyle())
                    Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding()
        }
        .background(Theme.page)
        .quickLookPreview($preview, in: previewList)
    }

    /// Folders can't be shared directly, so share what's inside them.
    private var shareURLs: [URL] {
        output.urls.flatMap { url -> [URL] in
            if FileStore.isDirectory(url) {
                return ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            return [url]
        }
    }

    private var previewList: [URL] { shareURLs }
}

// MARK: - Small views

struct PDFKitView: UIViewRepresentable {
    var url: URL? = nil
    var document: PDFDocument? = nil
    var interactive = true

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = UIColor(Theme.page)
        v.isUserInteractionEnabled = interactive
        v.document = document ?? url.flatMap { PDFDocument(url: $0) }
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if let d = document, v.document !== d { v.document = d }
    }
}

struct FileThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Theme.chip)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: symbol).foregroundStyle(Theme.grey)
            }
        }
        .task(id: url) { image = await Self.thumbnail(url) }
    }

    private var symbol: String {
        if FileStore.isDirectory(url) { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "txt", "md": return "doc.text"
        default: return "doc"
        }
    }

    static func thumbnail(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) { () -> UIImage? in
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let doc = PDFDocument(url: url), !doc.isLocked, let page = doc.page(at: 0) else { return nil }
                return page.thumbnail(of: CGSize(width: 120, height: 160), for: .cropBox)
            }
            if ["jpg", "jpeg", "png", "heic"].contains(ext), let img = UIImage(contentsOfFile: url.path) {
                return img.preparingThumbnail(of: CGSize(width: 120, height: 160))
            }
            return nil
        }.value
    }
}

struct OptionRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            content()
        }
    }
}

extension UIImage {
    /// Redraws the image so its pixels are upright, optionally shrinking it.
    func normalized(maxSide: CGFloat = 4000) -> UIImage {
        let longest = max(size.width, size.height)
        let scaleDown = longest > maxSide ? maxSide / longest : 1
        if imageOrientation == .up && scaleDown == 1 && scale == 1 { return self }
        let target = CGSize(width: (size.width * scaleDown).rounded(), height: (size.height * scaleDown).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
