import SwiftUI
import PDFKit
import PencilKit
import PhotosUI

struct EditEntryView: View {
    let mode: EditMode
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var doc: PDFDocument?

    var body: some View {
        Group {
            if let doc, let url = inputs.first {
                EditorView(doc: doc, url: url, mode: mode)
            } else {
                ToolPage(tool: mode.tool, state: state) {
                    InputPicker(urls: $inputs)
                    if mode == .full {
                        Text("Tip: for a scanned PDF, run OCR PDF first so its text can be edited.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .preset(preset, into: $inputs)
        .onChange(of: inputs) { _, urls in load(urls.first) }
        .onAppear { if doc == nil { load(inputs.first) } }
    }

    private func load(_ url: URL?) {
        guard let url else { doc = nil; return }
        do { doc = try PDFLoader.open(url) } catch { state.error = error.localizedDescription; inputs = [] }
    }
}

struct EditorView: View {
    let mode: EditMode
    @StateObject private var model: EditModel
    @StateObject private var state = ToolState()
    @ObservedObject private var fonts = FontLibrary.shared
    @Environment(\.dismiss) private var dismiss

    @State private var editing: UUID?
    @State private var showSignature = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @State private var toast: String?
    @State private var redactQuery = ""
    @State private var showResult = false
    @State private var eraser = false

    init(doc: PDFDocument, url: URL, mode: EditMode) {
        self.mode = mode
        _model = StateObject(wrappedValue: EditModel(doc: doc, url: url, mode: mode))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.tool == .redact {
                HStack {
                    TextField("Find words to black out", text: $redactQuery).textFieldStyle(.roundedBorder).submitLabel(.search)
                        .onSubmit(runRedactSearch)
                    Button("Black out", action: runRedactSearch).disabled(redactQuery.isEmpty)
                }
                .padding(.horizontal).padding(.vertical, 8)
            }
            canvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.page)
            bottomBar
        }
        .navigationTitle(mode.tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }.bold()
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast).font(.footnote).foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.ink.opacity(0.9), in: Capsule()).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay { if state.busy { BusyOverlay(text: state.text, fraction: state.fraction) } }
        .sheet(item: Binding(get: { editing.map(IDBox.init) }, set: { editing = $0?.id })) { box in
            TextEditSheet(model: model, itemID: box.id)
        }
        .sheet(isPresented: $showSignature) {
            SignatureSheet { img in placeSignature(img) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            Task {
                if let d = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: d) {
                    await MainActor.run { placeImage(img.normalized(maxSide: 2000), width: 0.4); photoItem = nil }
                }
            }
        }
        .sheet(isPresented: $showResult, onDismiss: {
            if state.output != nil { state.output = nil; dismiss() }
        }) {
            NavigationStack {
                if let out = state.output {
                    ResultView(tool: mode.tool, output: out) { showResult = false }
                        .navigationTitle("Saved").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .onChange(of: state.output != nil) { _, has in if has { showResult = true } }
        .alert("Couldn't save", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(state.error ?? "") }
        .onAppear { fonts.warmUp() }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let ps = model.pageSize
            let avail = CGSize(width: geo.size.width - 24, height: geo.size.height - 24)
            let s = min(avail.width / ps.width, avail.height / ps.height)
            let frame = CGSize(width: ps.width * s, height: ps.height * s)
            ZStack(alignment: .topLeading) {
                Group {
                    if let img = model.pageImage {
                        Image(uiImage: img).resizable()
                    } else {
                        Color.white.overlay(ProgressView())
                    }
                }
                .frame(width: frame.width, height: frame.height)

                Color.white.opacity(0.001)
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if dragStart == nil { dragStart = v.startLocation }
                            dragNow = v.location
                        }
                        .onEnded { v in
                            finishDrag(start: v.startLocation, end: v.location, frame: frame)
                            dragStart = nil; dragNow = nil
                        })

                ForEach(model.pageItems) { item in
                    ItemView(item: item, frame: frame, scale: s, selected: model.selected == item.id,
                             interactive: model.tool != .draw,
                             onSelect: { model.selected = item.id },
                             onEdit: { if [.text, .replace, .note].contains(item.kind) { editing = item.id } },
                             onMove: { d in
                                 model.snapshot()
                                 model.update(item.id) { $0.rect = $0.rect.offsetBy(dx: d.width / frame.width, dy: d.height / frame.height) }
                             },
                             onResize: { d in
                                 model.snapshot()
                                 model.update(item.id) { it in
                                     let w = max(it.rect.width + d.width / frame.width, 0.02)
                                     if it.kind == .text {
                                         it.size = max(4, it.size * w / max(it.rect.width, 0.001))
                                     } else {
                                         var h = max(it.rect.height + d.height / frame.height, 0.01)
                                         if it.kind == .image, let img = it.image {
                                             h = w * (img.size.height / img.size.width) * (frame.width / frame.height)
                                         }
                                         it.rect.size = CGSize(width: w, height: h)
                                     }
                                 }
                                 model.fitText(item.id)
                             },
                             onDelete: { model.delete(item.id) })
                }

                if let a = dragStart, let b = dragNow, [.highlight, .whiteout, .redact].contains(model.tool) {
                    let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                    Rectangle()
                        .fill(previewFill)
                        .overlay(Rectangle().stroke(Theme.red, style: StrokeStyle(lineWidth: 1, dash: [4])))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }

                InkCanvas(model: model, page: model.pageIndex, size: frame, color: model.inkColor, width: model.inkWidth, eraser: eraser)
                    .id(model.pageIndex)
                    .frame(width: frame.width, height: frame.height)
                    .allowsHitTesting(model.tool == .draw)
            }
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    private var previewFill: Color {
        switch model.tool {
        case .highlight: return Color.yellow.opacity(0.4)
        case .redact: return Color.black.opacity(0.7)
        default: return Color.white.opacity(0.9)
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button { model.go(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.pageIndex == 0)
                Spacer()
                Text(model.tool.hint).font(.caption).foregroundStyle(Theme.grey).multilineTextAlignment(.center).lineLimit(2)
                Spacer()
                Button { model.go(1) } label: { Image(systemName: "chevron.right") }.disabled(model.pageIndex >= model.doc.pageCount - 1)
            }
            .padding(.horizontal)
            Text("Page \(model.pageIndex + 1) of \(model.doc.pageCount)").font(.caption2).foregroundStyle(.secondary)

            if model.tool == .sign {
                Button { showSignature = true } label: { Label("Change signature", systemImage: "signature") }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.chip, in: Capsule())
                    .foregroundStyle(Theme.ink)
            }

            if model.tool == .draw {
                HStack(spacing: 14) {
                    ForEach([UIColor.black, UIColor(red: 0.1, green: 0.25, blue: 0.75, alpha: 1), UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1), UIColor(red: 0.1, green: 0.55, blue: 0.25, alpha: 1)], id: \.self) { c in
                        Circle().fill(Color(c)).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Theme.red, lineWidth: model.inkColor == c && !eraser ? 2 : 0).padding(-3))
                            .onTapGesture { model.inkColor = c; eraser = false }
                    }
                    Picker("", selection: $model.inkWidth) {
                        Text("Thin").tag(CGFloat(2)); Text("Mid").tag(CGFloat(4)); Text("Thick").tag(CGFloat(8))
                    }.pickerStyle(.segmented).frame(width: 150)
                    Button { eraser.toggle() } label: { Image(systemName: "eraser").foregroundStyle(eraser ? Theme.red : Theme.ink) }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(mode.tools) { t in
                        Button {
                            model.tool = t
                            model.selected = nil
                            if t == .image { showPhotoPicker = true }
                            if t == .sign {
                                if let img = SignatureStore.defaultImage { placeSignature(img) } else { showSignature = true }
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: t.icon).font(.system(size: 18))
                                Text(t.rawValue).font(.caption2)
                            }
                            .frame(minWidth: 62)
                            .padding(.vertical, 6)
                            .foregroundStyle(model.tool == t ? Theme.red : Theme.ink)
                            .background(model.tool == t ? Theme.redSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.vertical, 8)
        .background(Color.white)
    }

    // MARK: Actions

    private func show(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation { if toast == text { toast = nil } } }
    }

    private func finishDrag(start: CGPoint, end: CGPoint, frame: CGSize) {
        let isTap = hypot(end.x - start.x, end.y - start.y) < 6
        let p = CGPoint(x: end.x / frame.width, y: end.y / frame.height)
        model.selected = nil
        switch model.tool {
        case .editText:
            guard isTap else { return }
            editText(at: p)
        case .addText:
            guard isTap else { return }
            var item = EditItem(kind: .text, page: model.pageIndex, rect: CGRect(origin: p, size: .zero))
            item.text = ""
            item.size = 12
            item.family = "Helvetica"
            item.rect.size = model.measure(item)
            model.add(item)
            editing = item.id
        case .note:
            guard isTap else { return }
            let item = EditItem(kind: .note, page: model.pageIndex, rect: CGRect(x: p.x, y: p.y, width: 20 / model.pageSize.width, height: 20 / model.pageSize.height))
            model.add(item)
            editing = item.id
        case .highlight, .whiteout, .redact:
            guard !isTap else { return }
            let a = CGPoint(x: start.x / frame.width, y: start.y / frame.height)
            let r = CGRect(x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y))
            let kind: ItemKind = model.tool == .highlight ? .highlight : (model.tool == .redact ? .redact : .whiteout)
            model.add(EditItem(kind: kind, page: model.pageIndex, rect: r))
        default:
            break
        }
    }

    private func editText(at p: CGPoint) {
        if let existing = model.pageItems.first(where: { $0.kind == .replace && $0.rect.insetBy(dx: -0.005, dy: -0.005).contains(p) }) {
            editing = existing.id
            return
        }
        guard let page = model.page, let found = TextDetector.detect(page: page, at: p) else {
            show("No text there. For a scanned page, run OCR PDF first, or use Add text.")
            return
        }
        var item = EditItem(kind: .replace, page: model.pageIndex, rect: found.displayRect)
        item.text = found.text
        item.originalText = found.text
        item.detected = found.identity
        item.size = found.size
        item.color = found.color
        item.bold = found.identity.bold
        item.italic = found.identity.italic
        if let img = model.pageImage { item.patch = ColorSampler.surround(found.displayRect, in: img) }
        let ready = fonts.suggestions(for: found.identity).first { $0.kind == .ready }
        item.family = ready?.family ?? found.identity.family
        model.add(item)
        editing = item.id
    }

    private func placeImage(_ img: UIImage, width: CGFloat) {
        let ps = model.pageSize
        let h = width * (img.size.height / max(img.size.width, 1)) * (ps.width / ps.height)
        model.add(EditItem(kind: .image, page: model.pageIndex, rect: CGRect(x: 0.5 - width / 2, y: 0.5 - h / 2, width: width, height: h), image: img))
        model.tool = .select
    }

    /// Replaces the selected signature, or drops a new one in the middle of the page.
    private func placeSignature(_ img: UIImage) {
        if let id = model.selected, let item = model.items.first(where: { $0.id == id }), item.kind == .image {
            model.snapshot()
            let ps = model.pageSize
            model.update(id) { it in
                it.image = img
                it.rect.size.height = it.rect.width * (img.size.height / max(img.size.width, 1)) * (ps.width / ps.height)
            }
        } else {
            placeImage(img, width: 0.35)
        }
        model.tool = .sign
    }

    private func runRedactSearch() {
        let n = model.redactMatches(redactQuery)
        show(n == 0 ? "\"\(redactQuery)\" wasn't found." : "Blacked out \(n) match\(n == 1 ? "" : "es").")
    }

    private func save() {
        let m = model
        let suffix: String
        switch mode { case .full: suffix = " edited"; case .sign: suffix = " signed"; case .redact: suffix = " redacted" }
        state.run("Saving") { rep in
            let data = m.render(progress: rep)
            let url = try FileStore.save(data, base: FileStore.baseName(m.url) + suffix, ext: "pdf")
            return ToolOutput(urls: [url])
        }
    }
}

struct IDBox: Identifiable { let id: UUID }

// MARK: - Items

struct ItemView: View {
    let item: EditItem
    let frame: CGSize
    let scale: CGFloat
    let selected: Bool
    let interactive: Bool
    var onSelect: () -> Void
    var onEdit: () -> Void
    var onMove: (CGSize) -> Void
    var onResize: (CGSize) -> Void
    var onDelete: () -> Void

    @State private var drag: CGSize = .zero
    @State private var grow: CGSize = .zero

    private var rect: CGRect {
        CGRect(x: item.rect.minX * frame.width, y: item.rect.minY * frame.height,
               width: item.rect.width * frame.width + grow.width, height: item.rect.height * frame.height + grow.height)
    }

    var body: some View {
        let r = rect
        content(r)
            .frame(width: max(r.width, 8), height: max(r.height, 8), alignment: .topLeading)
            .overlay {
                if selected {
                    Rectangle().stroke(Theme.red, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])).padding(-3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.white, Theme.red)
                    }
                    .offset(x: 14, y: -14)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected && item.kind != .replace && item.kind != .note {
                    Circle().fill(Color.white).overlay(Circle().stroke(Theme.red, lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .offset(x: 9, y: 9)
                        .gesture(DragGesture()
                            .onChanged { grow = $0.translation }
                            .onEnded { v in onResize(v.translation); grow = .zero })
                }
            }
            .overlay(alignment: .topLeading) {
                if selected && [.text, .replace, .note].contains(item.kind) {
                    Button("Edit", action: onEdit)
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.red, in: Capsule())
                        .offset(y: -26)
                }
            }
            .position(x: r.midX + drag.width, y: r.midY + drag.height)
            .allowsHitTesting(interactive)
            .onTapGesture(count: 2) { onSelect(); onEdit() }
            .onTapGesture { onSelect() }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { v in onSelectIfNeeded(); drag = v.translation }
                .onEnded { v in onMove(v.translation); drag = .zero })
    }

    private func onSelectIfNeeded() { if !selected { onSelect() } }

    @ViewBuilder private func content(_ r: CGRect) -> some View {
        switch item.kind {
        case .replace:
            let font = FontLibrary.shared.font(family: item.family, bold: item.bold, italic: item.italic, size: item.size * scale)
            let top = (item.rect.height * frame.height) + font.descender - font.ascender
            ZStack(alignment: .topLeading) {
                Color(item.patch)
                Text(item.text).font(Font(font)).foregroundColor(Color(item.color)).fixedSize()
                    .offset(y: top - (font.lineHeight - (font.ascender - font.descender)) / 2)
            }
        case .text:
            let font = FontLibrary.shared.font(family: item.family, bold: item.bold, italic: item.italic, size: item.size * scale)
            Text(item.text.isEmpty ? "Text" : item.text).font(Font(font)).foregroundColor(item.text.isEmpty ? .gray : Color(item.color))
                .fixedSize().padding(1)
        case .image:
            if let img = item.image { Image(uiImage: img).resizable() }
        case .highlight:
            Color.yellow.opacity(0.4).blendMode(.multiply)
        case .whiteout:
            Color.white.overlay(Rectangle().stroke(Theme.line, lineWidth: selected ? 0 : 0.5))
        case .redact:
            Color.black
        case .note:
            Image(systemName: "note.text").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                .frame(width: 20, height: 20).background(Color.yellow, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Ink

struct InkCanvas: UIViewRepresentable {
    let model: EditModel
    let page: Int
    let size: CGSize
    let color: UIColor
    let width: CGFloat
    let eraser: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        v.backgroundColor = .clear
        v.isOpaque = false
        v.drawingPolicy = .anyInput
        v.overrideUserInterfaceStyle = .light
        v.isScrollEnabled = false
        v.drawing = model.drawings[page] ?? PKDrawing()
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        v.tool = eraser ? PKEraserTool(.vector) : PKInkingTool(.pen, color: color, width: width)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: InkCanvas
        init(_ p: InkCanvas) { parent = p }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.model.drawings[parent.page] = canvasView.drawing
            parent.model.canvasSizes[parent.page] = canvasView.bounds.size
        }
    }
}
