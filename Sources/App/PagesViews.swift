import SwiftUI
import PDFKit

/// Thumbnails for a document, made in the background and cached.
final class ThumbStore: ObservableObject {
    @Published var images: [Int: UIImage] = [:]
    private var requested = Set<Int>()
    let doc: PDFDocument
    init(doc: PDFDocument) { self.doc = doc }

    func load(_ i: Int, width: CGFloat = 220) {
        guard !requested.contains(i), let page = doc.page(at: i) else { return }
        requested.insert(i)
        DispatchQueue.global(qos: .userInitiated).async {
            let img = PageRenderer.image(page, width: width)
            DispatchQueue.main.async { self.images[i] = img }
        }
    }
}

struct PageThumb: View {
    @ObservedObject var store: ThumbStore
    let index: Int
    var turns = 0
    var body: some View {
        ZStack {
            if let img = store.images[index] {
                Image(uiImage: img).resizable().scaledToFit()
                    .rotationEffect(.degrees(Double(turns) * 90))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            } else {
                Rectangle().fill(Color.white).overlay(ProgressView())
            }
        }
        .onAppear { store.load(index) }
    }
}

struct PagesToolView: View {
    enum Mode { case remove, extract, organize, rotate }
    let mode: Mode
    var preset: URL?

    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var store: ThumbStore?
    @State private var selected = Set<Int>()
    @State private var order: [Int] = []
    @State private var turns: [Int: Int] = [:]
    @State private var separate = false

    private var tool: Tool {
        switch mode { case .remove: return .removePages; case .extract: return .extractPages; case .organize: return .organize; case .rotate: return .rotate }
    }

    var body: some View {
        ToolPage(tool: tool, state: state) {
            if store == nil { InputPicker(urls: $inputs) }
            if let store {
                header(store)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 14) {
                    ForEach(Array(order.enumerated()), id: \.element) { pos, i in
                        cell(store, pos: pos, index: i)
                    }
                }
                footer(store)
            }
        }
        .preset(preset, into: $inputs)
        .onChange(of: inputs) { _, urls in load(urls.first) }
        .onAppear { if store == nil { load(inputs.first) } }
    }

    @ViewBuilder private func header(_ store: ThumbStore) -> some View {
        HStack {
            Text(inputs.first?.lastPathComponent ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer()
            Button("Change file") { self.store = nil; inputs = [] }.font(.footnote)
        }
        switch mode {
        case .remove: Text("Tap the pages to remove.").font(.caption).foregroundStyle(.secondary)
        case .extract: Text("Tap the pages to keep in the new PDF.").font(.caption).foregroundStyle(.secondary)
        case .organize: Text("Use the arrows to move pages, rotate them, or delete them.").font(.caption).foregroundStyle(.secondary)
        case .rotate:
            HStack {
                Button { rotateSelected(-1) } label: { Label("Left", systemImage: "rotate.left") }.buttonStyle(SecondaryButtonStyle())
                Button { rotateSelected(1) } label: { Label("Right", systemImage: "rotate.right") }.buttonStyle(SecondaryButtonStyle())
            }
            Text(selected.isEmpty ? "Rotates every page. Tap pages to rotate just those." : "Rotates the \(selected.count) selected page\(selected.count == 1 ? "" : "s").")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func cell(_ store: ThumbStore, pos: Int, index i: Int) -> some View {
        let isOn = selected.contains(i)
        return VStack(spacing: 6) {
            PageThumb(store: store, index: i, turns: turns[i] ?? 0)
                .frame(height: 120)
                .overlay(alignment: .topTrailing) {
                    if mode != .organize && isOn {
                        Image(systemName: mode == .remove ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(.title3).foregroundStyle(.white, mode == .remove ? Theme.red : tool.color).padding(4)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(isOn && mode != .organize ? tool.color : .clear, lineWidth: 2))
                .opacity(mode == .remove && isOn ? 0.45 : 1)
                .onTapGesture {
                    guard mode != .organize else { return }
                    if isOn { selected.remove(i) } else { selected.insert(i) }
                }
            if mode == .organize {
                HStack(spacing: 10) {
                    Button { move(pos, -1) } label: { Image(systemName: "chevron.left") }.disabled(pos == 0)
                    Button { turns[i, default: 0] += 1 } label: { Image(systemName: "rotate.right") }
                    Button { order.remove(at: pos) } label: { Image(systemName: "trash") }.tint(Theme.red).disabled(order.count == 1)
                    Button { move(pos, 1) } label: { Image(systemName: "chevron.right") }.disabled(pos == order.count - 1)
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }
            Text("\(i + 1)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func footer(_ store: ThumbStore) -> some View {
        switch mode {
        case .remove:
            Button("Remove \(selected.count) page\(selected.count == 1 ? "" : "s")") { save(store) }
                .buttonStyle(PrimaryButtonStyle(color: tool.color))
                .disabled(selected.isEmpty || selected.count == store.doc.pageCount)
        case .extract:
            Toggle("Each page as its own PDF", isOn: $separate)
            Button("Extract \(selected.count) page\(selected.count == 1 ? "" : "s")") { save(store) }
                .buttonStyle(PrimaryButtonStyle(color: tool.color))
                .disabled(selected.isEmpty)
        case .organize, .rotate:
            Button("Save PDF") { save(store) }.buttonStyle(PrimaryButtonStyle(color: tool.color))
        }
    }

    private func move(_ pos: Int, _ d: Int) {
        let j = pos + d
        guard j >= 0, j < order.count else { return }
        withAnimation { order.swapAt(pos, j) }
    }

    private func rotateSelected(_ d: Int) {
        let targets = selected.isEmpty ? Set(order) : selected
        for i in targets { turns[i, default: 0] += d }
    }

    private func load(_ url: URL?) {
        guard let url else { store = nil; return }
        do {
            let doc = try PDFLoader.open(url)
            store = ThumbStore(doc: doc)
            order = Array(0..<doc.pageCount)
            selected = []
            turns = [:]
        } catch {
            state.error = error.localizedDescription
            inputs = []
        }
    }

    private func save(_ store: ThumbStore) {
        let doc = store.doc
        let base = FileStore.baseName(inputs.first ?? URL(fileURLWithPath: "PDF"))
        let mode = mode, selected = selected, order = order, turns = turns, separate = separate
        state.run("Saving") { rep in
            func apply(_ out: PDFDocument, _ indexes: [Int]) {
                for (k, i) in indexes.enumerated() {
                    if let t = turns[i], let p = out.page(at: k) { p.rotation = ((p.rotation + t * 90) % 360 + 360) % 360 }
                }
            }
            switch mode {
            case .remove:
                let keep = order.filter { !selected.contains($0) }
                let url = try FileStore.save(PDFOps.subset(doc, pages: keep), base: base + " edited")
                return ToolOutput(urls: [url], message: "\(keep.count) pages left")
            case .extract:
                let pick = order.filter { selected.contains($0) }
                if separate {
                    let folder = FileStore.folder(named: base + " pages")
                    for i in pick {
                        try PDFOps.subset(doc, pages: [i]).dataRepresentation()?.write(to: folder.appendingPathComponent("\(base) page \(i + 1).pdf"))
                    }
                    FileStore.notify()
                    return ToolOutput(urls: [folder], message: "\(pick.count) PDFs in a folder")
                }
                let url = try FileStore.save(PDFOps.subset(doc, pages: pick), base: base + " extract")
                return ToolOutput(urls: [url], message: "\(pick.count) pages")
            case .organize, .rotate:
                let out = PDFOps.subset(doc, pages: order)
                apply(out, order)
                let url = try FileStore.save(out, base: base + (mode == .rotate ? " rotated" : " organised"))
                return ToolOutput(urls: [url], message: "\(order.count) pages")
            }
        }
    }
}

// MARK: Crop

struct CropView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var doc: PDFDocument?
    @State private var pageImage: UIImage?
    @State private var pageIndex = 0
    @State private var rect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var allPages = true

    var body: some View {
        ToolPage(tool: .crop, state: state) {
            if doc == nil { InputPicker(urls: $inputs) }
            if let doc {
                HStack {
                    Button { show(pageIndex - 1) } label: { Image(systemName: "chevron.left") }.disabled(pageIndex == 0)
                    Spacer()
                    Text("Page \(pageIndex + 1) of \(doc.pageCount)").font(.subheadline)
                    Spacer()
                    Button { show(pageIndex + 1) } label: { Image(systemName: "chevron.right") }.disabled(pageIndex >= doc.pageCount - 1)
                }
                if let img = pageImage {
                    CropBoxEditor(image: img, rect: $rect)
                        .aspectRatio(img.size, contentMode: .fit)
                }
                Toggle("Crop every page the same way", isOn: $allPages)
                Button("Crop PDF") {
                    let r = rect, all = allPages, idx = pageIndex, base = FileStore.baseName(inputs[0])
                    state.run("Cropping") { _ in
                        let pages = all ? Array(0..<doc.pageCount) : [idx]
                        let out = PDFOps.crop(doc, rect: r, pages: pages)
                        let url = try FileStore.save(out, base: base + " cropped")
                        return ToolOutput(urls: [url])
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.crop.color))
            }
        }
        .preset(preset, into: $inputs)
        .onChange(of: inputs) { _, urls in load(urls.first) }
        .onAppear { if doc == nil { load(inputs.first) } }
    }

    private func load(_ url: URL?) {
        guard let url else { doc = nil; return }
        do { doc = try PDFLoader.open(url); show(0) } catch { state.error = error.localizedDescription; inputs = [] }
    }

    private func show(_ i: Int) {
        guard let doc, let page = doc.page(at: i) else { return }
        pageIndex = i
        pageImage = PageRenderer.image(page, width: 900)
    }
}

struct CropBoxEditor: View {
    let image: UIImage
    @Binding var rect: CGRect

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width, H = geo.size.height
            let r = CGRect(x: rect.minX * W, y: rect.minY * H, width: rect.width * W, height: rect.height * H)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable()
                Path { p in p.addRect(CGRect(x: 0, y: 0, width: W, height: H)); p.addRect(r) }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle().stroke(Tool.crop.color, lineWidth: 2).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                handle(at: CGPoint(x: r.minX, y: r.minY)) { p in
                    let x = min(max(p.x / W, 0), rect.maxX - 0.05), y = min(max(p.y / H, 0), rect.maxY - 0.05)
                    rect = CGRect(x: x, y: y, width: rect.maxX - x, height: rect.maxY - y)
                }
                handle(at: CGPoint(x: r.maxX, y: r.maxY)) { p in
                    let x = max(min(p.x / W, 1), rect.minX + 0.05), y = max(min(p.y / H, 1), rect.minY + 0.05)
                    rect = CGRect(x: rect.minX, y: rect.minY, width: x - rect.minX, height: y - rect.minY)
                }
                handle(at: CGPoint(x: r.maxX, y: r.minY)) { p in
                    let x = max(min(p.x / W, 1), rect.minX + 0.05), y = min(max(p.y / H, 0), rect.maxY - 0.05)
                    rect = CGRect(x: rect.minX, y: y, width: x - rect.minX, height: rect.maxY - y)
                }
                handle(at: CGPoint(x: r.minX, y: r.maxY)) { p in
                    let x = min(max(p.x / W, 0), rect.maxX - 0.05), y = max(min(p.y / H, 1), rect.minY + 0.05)
                    rect = CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: y - rect.minY)
                }
            }
            .coordinateSpace(name: "crop")
        }
    }

    private func handle(at p: CGPoint, onDrag: @escaping (CGPoint) -> Void) -> some View {
        Circle().fill(Color.white).overlay(Circle().stroke(Tool.crop.color, lineWidth: 3))
            .frame(width: 24, height: 24)
            .position(p)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("crop")).onChanged { onDrag($0.location) })
    }
}
