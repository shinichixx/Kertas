import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject var router: AppRouter
    @State private var files: [URL] = []
    @State private var showImporter = false
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var quickLook: URL?

    var body: some View {
        List {
            ForEach(files, id: \.self) { url in
                Button { open(url) } label: {
                    HStack(spacing: 12) {
                        FileThumb(url: url).frame(width: 40, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(url.lastPathComponent).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
                            Text("\(FileStore.modified(url).formatted(date: .abbreviated, time: .shortened)) · \(FileStore.sizeText(FileStore.size(url)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { delete(url) } label: { Label("Delete", systemImage: "trash") }
                    Button { newName = FileStore.baseName(url); renaming = url } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                }
                .contextMenu {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { newName = FileStore.baseName(url); renaming = url } label: { Label("Rename", systemImage: "pencil") }
                    Button(role: .destructive) { delete(url) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if files.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "doc", description: Text("Scans and PDFs you make are kept here."))
            }
        }
        .navigationTitle("Files")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "plus") }
            }
        }
        .documentPicker(isPresented: $showImporter, types: [.pdf, .image], multiple: true) { urls in
            let adopted = urls.compactMap { FileStore.adopt($0) }
            reload()
            if adopted.count == 1, adopted[0].pathExtension.lowercased() == "pdf" { open(adopted[0]) }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename() }
        }
        .navigationDestination(for: URL.self) { FileDetailView(url: $0) }
        .quickLookPreview($quickLook)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .kertasFilesChanged)) { _ in reload() }
        .onChange(of: router.openedFile) { _, url in
            if let url { reload(); open(url); router.openedFile = nil }
        }
    }

    private func open(_ url: URL) {
        if url.pathExtension.lowercased() == "pdf" {
            NotificationCenter.default.post(name: .kertasPushFile, object: url)
        } else {
            quickLook = url
        }
    }

    private func reload() { files = FileStore.list() }

    private func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    private func rename() {
        guard let url = renaming else { return }
        let ext = url.pathExtension
        let dest = FileStore.uniqueURL(base: newName, ext: ext)
        try? FileManager.default.moveItem(at: url, to: dest)
        renaming = nil
        reload()
    }
}

extension Notification.Name {
    static let kertasPushFile = Notification.Name("kertasPushFile")
}

/// Wraps FilesView so tapping a PDF can push the viewer.
struct FilesTab: View {
    @State private var path = NavigationPath()
    var body: some View {
        NavigationStack(path: $path) {
            FilesView()
                .onReceive(NotificationCenter.default.publisher(for: .kertasPushFile)) { note in
                    if let url = note.object as? URL { path.append(url) }
                }
        }
    }
}

struct FileDetailView: View {
    let url: URL
    private let quickTools: [Tool] = [.edit, .sign, .compress, .ocr, .organize, .split, .pageNumbers, .watermark, .protect, .pdfToJpg, .summarize, .translate]

    @State private var page = 1
    @State private var pages = 1

    var body: some View {
        FittedPDFView(url: url, page: $page, pages: $pages)
            .background(Theme.page)
            .overlay(alignment: .bottom) {
                Text("\(page) / \(pages)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.ink.opacity(0.85), in: Capsule())
                    .padding(.bottom, 10)
            }
            .toolbar(.hidden, for: .tabBar)
            .navigationTitle(FileStore.baseName(url))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(quickTools) { tool in
                            NavigationLink { ToolRouter(tool: tool, preset: url) } label: { Label(tool.title, systemImage: tool.icon) }
                        }
                    } label: { Image(systemName: "wand.and.stars") }
                }
            }
    }
}


/// PDF viewer that fits each page on screen, centred, without the doubled top inset.
struct FittedPDFView: UIViewRepresentable {
    let url: URL
    @Binding var page: Int
    @Binding var pages: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FittingPDFView {
        let v = FittingPDFView()
        v.backgroundColor = UIColor(Theme.page)
        v.displayDirection = .vertical
        v.displaysPageBreaks = true
        v.pageBreakMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let doc = PDFDocument(url: url)
        v.displayMode = (doc?.pageCount ?? 1) > 1 ? .singlePageContinuous : .singlePage
        v.document = doc
        context.coordinator.observe(v)
        DispatchQueue.main.async {
            pages = max(doc?.pageCount ?? 1, 1)
            page = 1
        }
        return v
    }

    func updateUIView(_ v: FittingPDFView, context: Context) {}

    final class Coordinator: NSObject {
        let parent: FittedPDFView
        private var token: NSObjectProtocol?
        init(_ p: FittedPDFView) { parent = p }

        func observe(_ v: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: v, queue: .main) { [weak self] _ in
                guard let self, let doc = v.document, let current = v.currentPage else { return }
                self.parent.page = doc.index(for: current) + 1
            }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

final class FittingPDFView: PDFView {
    private var lastSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // PDFView's own scroll view adds the navigation bar height again; stop that.
        for case let scroll as UIScrollView in subviews {
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.contentInset = .zero
        }
        guard bounds.size != lastSize, bounds.width > 0, document != nil else { return }
        lastSize = bounds.size
        let fit = scaleFactorForSizeToFit
        minScaleFactor = fit
        maxScaleFactor = max(fit * 6, 4)
        scaleFactor = fit
        if let first = document?.page(at: 0), currentPage == nil || currentPage == first { go(to: first) }
    }
}
