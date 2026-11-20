import SwiftUI
import PhotosUI
import VisionKit
import PDFKit

struct ScanPage: Identifiable {
    let id = UUID()
    var original: UIImage
    var quad: Quad?
    var turns = 0
    var filter: ScanFilter = .auto
    var straighten = true
    var result: UIImage?
    var version = 0
}

final class ScanSession: ObservableObject {
    @Published var pages: [ScanPage] = []
    @Published var detecting = 0

    func add(_ images: [UIImage], detect: Bool) {
        detecting += images.count
        DispatchQueue.global(qos: .userInitiated).async {
            for raw in images {
                let img = raw.normalized(maxSide: 3500)
                let quad = detect ? Perspective.detect(img) : nil
                DispatchQueue.main.async {
                    var p = ScanPage(original: img, quad: detect ? (quad ?? .full) : nil)
                    p.filter = .auto
                    self.pages.append(p)
                    self.detecting -= 1
                    self.process(p.id)
                }
            }
        }
    }

    func update(_ id: UUID, _ change: (inout ScanPage) -> Void) {
        guard let i = pages.firstIndex(where: { $0.id == id }) else { return }
        change(&pages[i])
        pages[i].version += 1
        process(id)
    }

    func process(_ id: UUID) {
        guard let p = pages.first(where: { $0.id == id }) else { return }
        let version = p.version
        DispatchQueue.global(qos: .userInitiated).async {
            let out = autoreleasepool { () -> UIImage in
                let straight = Perspective.correct(p.original, quad: p.quad)
                let turned = Perspective.rotate(straight, quarterTurns: p.turns)
                let level = p.straighten ? TextStraightener.refine(turned) : turned
                return Perspective.apply(p.filter, to: level)
            }
            DispatchQueue.main.async {
                if let i = self.pages.firstIndex(where: { $0.id == id }), self.pages[i].version == version {
                    self.pages[i].result = out
                }
            }
        }
    }

    func makePDF(searchable: Bool, size: PDFOps.PageFit, progress: ProgressReporter) -> Data {
        let images = pages.map { $0.result ?? $0.original }
        let base = PDFOps.imagesToPDF(images, fit: size, margin: .none, progress: progress)
        guard searchable, let doc = PDFDocument(data: base) else { return base }
        return OCR.searchable(doc, progress: progress).0
    }
}

struct ScanView: View {
    @StateObject private var session = ScanSession()
    @StateObject private var state = ToolState()
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var selected: UUID?
    @State private var adjusting: ScanPage?
    @State private var searchable = true
    @State private var pageSize: PDFOps.PageFit = .a4
    @State private var name = ""
    @State private var showResult = false

    private var current: ScanPage? {
        session.pages.first { $0.id == selected } ?? session.pages.last
    }

    var body: some View {
        Group {
            if session.pages.isEmpty && session.detecting == 0 {
                emptyState
            } else {
                editor
            }
        }
        .background(Theme.page)
        .navigationTitle("Scan to PDF")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(onFinish: { imgs in
                showCamera = false
                session.add(imgs, detect: false)
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var imgs: [UIImage] = []
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d) { imgs.append(img) }
                }
                await MainActor.run {
                    session.add(imgs, detect: true)
                    photoItems = []
                }
            }
        }
        .sheet(item: $adjusting) { page in
            CornerAdjustView(image: page.original, quad: page.quad ?? Perspective.detect(page.original) ?? .inset) { q in
                session.update(page.id) { $0.quad = q }
            }
        }
        .sheet(isPresented: $showResult) {
            NavigationStack {
                if let out = state.output {
                    ResultView(tool: .scan, output: out) { showResult = false }
                        .navigationTitle("Saved").navigationBarTitleDisplayMode(.inline)
                }
            }
            .onDisappear {
                if state.output != nil { session.pages.removeAll(); state.output = nil; name = "" }
            }
        }
        .overlay { if state.busy { BusyOverlay(text: state.text, fraction: state.fraction) } }
        .onChange(of: state.output != nil) { _, has in if has { showResult = true } }
        .alert("Couldn't save", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(state.error ?? "") }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.viewfinder").font(.system(size: 64, weight: .light)).foregroundStyle(Theme.red)
            Text("Scan a document").font(.title2.weight(.semibold))
            Text("Use the camera, or pick a photo you already took. Kertas finds the page edges and straightens it like a flatbed scan, however tilted it is.")
                .font(.subheadline).foregroundStyle(Theme.grey).multilineTextAlignment(.center).padding(.horizontal, 30)
            VStack(spacing: 10) {
                Button { showCamera = true } label: { Label("Use camera", systemImage: "camera") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!VNDocumentCameraViewController.isSupported)
                PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .images) {
                    Label("Choose photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 30)
            Spacer()
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ZStack {
                if let p = current {
                    if let r = p.result {
                        Image(uiImage: r).resizable().scaledToFit()
                            .background(Color.white)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    } else {
                        ProgressView().tint(Theme.red)
                    }
                } else {
                    ProgressView("Finding page edges").tint(Theme.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)

            if let p = current {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(ScanFilter.allCases) { f in
                            Button { session.update(p.id) { $0.filter = f } } label: {
                                Text(f.rawValue).font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .foregroundStyle(p.filter == f ? .white : Theme.ink)
                                    .background(p.filter == f ? Theme.red : Theme.chip, in: Capsule())
                            }
                        }
                        Button { session.update(p.id) { $0.straighten.toggle() } } label: {
                            Label("Straighten text", systemImage: p.straighten ? "checkmark.circle.fill" : "circle")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .foregroundStyle(p.straighten ? Theme.red : Theme.ink)
                                .background(p.straighten ? Theme.redSoft : Theme.chip, in: Capsule())
                        }
                        Button("Use on all") {
                            for page in session.pages where page.id != p.id {
                                session.update(page.id) { $0.filter = p.filter; $0.straighten = p.straighten }
                            }
                        }
                        .font(.footnote)
                    }
                    .padding(.horizontal)
                }

                HStack(spacing: 0) {
                    toolButton("Corners", "crop") { adjusting = p }
                    toolButton("Rotate", "rotate.right") { session.update(p.id) { $0.turns += 1 } }
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 30, matching: .images) {
                        VStack(spacing: 4) { Image(systemName: "photo.badge.plus").font(.system(size: 19)); Text("Photo").font(.caption2) }
                            .frame(maxWidth: .infinity).foregroundStyle(Theme.ink)
                    }
                    toolButton("Camera", "camera") { showCamera = true }
                    toolButton("Delete", "trash") {
                        session.pages.removeAll { $0.id == p.id }
                        selected = session.pages.last?.id
                    }
                }
                .padding(.vertical, 10)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { i, page in
                        Button { selected = page.id } label: {
                            ZStack(alignment: .bottomTrailing) {
                                Image(uiImage: page.result ?? page.original).resizable().scaledToFill()
                                    .frame(width: 48, height: 64).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(page.id == current?.id ? Theme.red : Theme.line, lineWidth: page.id == current?.id ? 2 : 0.5))
                                Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(.white).padding(3).background(Theme.ink.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .contextMenu {
                            if i > 0 { Button("Move left") { session.pages.swapAt(i, i - 1) } }
                            if i < session.pages.count - 1 { Button("Move right") { session.pages.swapAt(i, i + 1) } }
                        }
                    }
                    if session.detecting > 0 { ProgressView().frame(width: 48, height: 64) }
                }
                .padding(.horizontal)
            }
            .frame(height: 72)

            VStack(spacing: 10) {
                TextField("File name", text: $name, prompt: Text(defaultName))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Searchable text", isOn: $searchable).font(.footnote).fixedSize()
                    Spacer()
                    Picker("Page", selection: $pageSize) {
                        ForEach(PDFOps.PageFit.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                Button { save() } label: { Label("Save PDF (\(session.pages.count) page\(session.pages.count == 1 ? "" : "s"))", systemImage: "doc.badge.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.pages.isEmpty || session.pages.contains { $0.result == nil })
            }
            .padding()
            .background(Color.white)
        }
    }

    private var defaultName: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        return "Scan " + f.string(from: Date())
    }

    private func toolButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 19)); Text(title).font(.caption2) }
                .frame(maxWidth: .infinity)
                .foregroundStyle(Theme.ink)
        }
    }

    private func save() {
        let fileName = name.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : name
        let ocr = searchable, size = pageSize
        let s = session
        state.run("Making your PDF") { rep in
            let data = s.makePDF(searchable: ocr, size: size, progress: rep)
            let url = try FileStore.save(data, base: fileName, ext: "pdf")
            return ToolOutput(urls: [url], message: "\(s.pages.count) page\(s.pages.count == 1 ? "" : "s") · \(FileStore.sizeText(FileStore.size(url)))")
        }
    }
}
