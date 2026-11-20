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

}

struct ScanView: View {
    @StateObject private var session = ScanSession()
    @StateObject private var state = ToolState()
    @ObservedObject private var router = AppRouter.shared
    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var selected: UUID?
    @State private var adjusting: ScanPage?
    @State private var searchable = true
    @State private var format: ScanFormat = .pdf
    @State private var pageSize: ScanPageSize = .original
    @State private var fit: ScanFit = .fit
    @State private var name = ""
    @State private var renaming = false
    @State private var draftName = ""
    @State private var confirmClear = false
    @State private var showResult = false

    private var current: ScanPage? {
        session.pages.first { $0.id == selected } ?? session.pages.last
    }

    private var editing: Bool { !session.pages.isEmpty || session.detecting > 0 }

    var body: some View {
        Group {
            if editing { editor } else { emptyState }
        }
        .background(Theme.page)
        .navigationTitle(editing ? "Scan · \(session.pages.count) page\(session.pages.count == 1 ? "" : "s")" : "Scan to PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(editing ? .hidden : .visible, for: .tabBar)
        .toolbar {
            if editing {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { confirmClear = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { draftName = name; renaming = true } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Rename")
                }
            }
        }
        .confirmationDialog("Clear this scan?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all pages", role: .destructive) { session.pages.removeAll(); name = ""; selected = nil }
        } message: { Text("The pages you scanned will be removed.") }
        .alert("File name", isPresented: $renaming) {
            TextField(defaultName, text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { name = draftName.trimmingCharacters(in: .whitespaces) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(onFinish: { imgs in
                showCamera = false
                session.add(imgs, detect: false)
            }, onCancel: { showCamera = false })
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 30, matching: .images)
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
        .onChange(of: router.scanStart) { _, start in handleStart(start) }
        .onAppear { handleStart(router.scanStart) }
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

    private func handleStart(_ start: AppRouter.ScanStart?) {
        guard let start else { return }
        router.scanStart = nil
        switch start {
        case .camera: if VNDocumentCameraViewController.isSupported { showCamera = true }
        case .photos: showPhotos = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "doc.viewfinder").font(.system(size: 64, weight: .light)).foregroundStyle(Theme.red)
            Text("Scan a document").font(.title2.weight(.semibold))
            Text("Use the camera, or pick a photo you already took. Kertas finds the page edges and straightens it like a flatbed scan, however tilted it is.")
                .font(.subheadline).foregroundStyle(Theme.grey).multilineTextAlignment(.center).padding(.horizontal, 30)
            straightenNote.padding(.horizontal, 30)
            VStack(spacing: 10) {
                Button { showCamera = true } label: { Label("Use camera", systemImage: "camera") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!VNDocumentCameraViewController.isSupported)
                Button { showPhotos = true } label: { Label("Choose photos", systemImage: "photo.on.rectangle") }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 30)
            Spacer()
        }
    }

    private var straightenNote: some View {
        Label("Text is straightened automatically on Save", systemImage: "sparkles")
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(Color(hex: 0x791F1F))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Editor (fits one screen)

    private var editor: some View {
        VStack(spacing: 10) {
            straightenNote

            ZStack {
                if let p = current, let r = p.result {
                    Image(uiImage: r).resizable().scaledToFit()
                        .background(Color.white)
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                } else {
                    ProgressView(current == nil ? "Finding page edges" : "").tint(Theme.red)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let p = current { filterRow(p) }

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(session.pages.enumerated()), id: \.element.id) { i, page in
                            Button { selected = page.id } label: {
                                Image(uiImage: page.result ?? page.original).resizable().scaledToFill()
                                    .frame(width: 32, height: 42).clipped()
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(page.id == current?.id ? Theme.red : Theme.line, lineWidth: page.id == current?.id ? 2 : 0.5))
                            }
                            .contextMenu {
                                if i > 0 { Button("Move left") { session.pages.swapAt(i, i - 1) } }
                                if i < session.pages.count - 1 { Button("Move right") { session.pages.swapAt(i, i + 1) } }
                            }
                        }
                        if session.detecting > 0 { ProgressView().frame(width: 32, height: 42) }
                        Menu {
                            Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                            Button { showPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Theme.grey.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3]))
                                .frame(width: 32, height: 42)
                                .overlay(Image(systemName: "plus").foregroundStyle(Theme.grey))
                        }
                        .accessibilityLabel("Add page")
                    }
                    .padding(.vertical, 2)
                }
                if let p = current {
                    iconButton("crop", "Corners") { adjusting = p }
                    iconButton("rotate.right", "Rotate") { session.update(p.id) { $0.turns += 1 } }
                    iconButton("trash", "Delete page", tint: Theme.red) {
                        session.pages.removeAll { $0.id == p.id }
                        selected = session.pages.last?.id
                    }
                }
            }
            .frame(height: 48)

            HStack(spacing: 8) {
                Menu {
                    Picker("Save as", selection: $format) { ForEach(ScanFormat.allCases) { Text($0.rawValue).tag($0) } }
                } label: { menuBox("Save as", format.rawValue) }
                Menu {
                    Picker("Page size", selection: $pageSize) { ForEach(ScanPageSize.allCases) { Text($0.rawValue).tag($0) } }
                    if pageSize != .original {
                        Section("Fit") {
                            Picker("Fit", selection: $fit) {
                                ForEach(ScanFit.allCases) { f in Text("\(f.rawValue) (\(f.note))").tag(f) }
                            }
                        }
                    }
                } label: { menuBox("Size", pageSize == .original ? "Original" : "\(pageSize.rawValue) · \(fit == .fit ? "Fit" : (fit == .fill ? "Fill" : "Stretch"))") }
                Menu {
                    Picker("Text", selection: $searchable) {
                        Text("Searchable").tag(true)
                        Text("Image only").tag(false)
                    }
                } label: { menuBox("Text", format == .pdf ? (searchable ? "Searchable" : "Image only") : "n/a") }
                .disabled(format != .pdf)
            }

            Button { save() } label: {
                Label("Save \(format.rawValue)\(session.pages.count > 1 ? " (\(session.pages.count) pages)" : "")", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(session.pages.isEmpty || session.pages.contains { $0.result == nil })
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private func filterRow(_ p: ScanPage) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ScanFilter.allCases) { f in
                    Button { session.update(p.id) { $0.filter = f } } label: {
                        Text(f.rawValue).font(.footnote.weight(.medium))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .foregroundStyle(p.filter == f ? .white : Theme.ink)
                            .background(p.filter == f ? Theme.red : Theme.chip, in: Capsule())
                    }
                }
                Button { session.update(p.id) { $0.straighten.toggle() } } label: {
                    Label("Straighten", systemImage: p.straighten ? "checkmark.circle.fill" : "circle")
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(p.straighten ? Theme.red : Theme.ink)
                        .background(p.straighten ? Theme.redSoft : Theme.chip, in: Capsule())
                }
                if session.pages.count > 1 {
                    Button("Use on all") {
                        for page in session.pages where page.id != p.id {
                            session.update(page.id) { $0.filter = p.filter; $0.straighten = p.straighten }
                        }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    private func iconButton(_ icon: String, _ label: String, tint: Color = Theme.ink, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 0.5))
        }
        .accessibilityLabel(label)
    }

    private func menuBox(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text(value).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 0.5))
    }

    private var defaultName: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        return "Scan " + f.string(from: Date())
    }

    private func save() {
        let fileName = name.isEmpty ? defaultName : name
        let ocr = searchable, size = pageSize, fit = fit, format = format
        let images = session.pages.map { $0.result ?? $0.original }
        state.run("Saving your \(format.rawValue)") { rep in
            try ScanExport.save(images, name: fileName, format: format, size: size, fit: fit, searchable: ocr, progress: rep)
        }
    }
}
