import SwiftUI
import PDFKit
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

// MARK: Office to PDF

struct OfficeToPDFView: View {
    let tool: Tool
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var landscape = false

    private var types: [UTType] {
        let exts: [String]
        switch tool {
        case .wordToPdf: exts = ["docx", "doc", "rtf", "pages"]
        case .excelToPdf: exts = ["xlsx", "xls", "csv", "numbers"]
        default: exts = ["pptx", "ppt", "key"]
        }
        return exts.compactMap { UTType(filenameExtension: $0) }
    }

    var body: some View {
        ToolPage(tool: tool, state: state) {
            InputPicker(urls: $inputs, types: types, multiple: true, label: "Choose files")
            if !inputs.isEmpty {
                Card {
                    Toggle("Landscape pages", isOn: $landscape)
                    Text("Converted on your iPhone. Simple layouts come out well; complex ones may shift slightly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Convert to PDF") {
                    let files = inputs, land = landscape || tool == .pptToPdf
                    state.runMain("Converting") { rep in
                        var urls: [URL] = []
                        for (i, f) in files.enumerated() {
                            rep(Double(i) / Double(files.count), "Converting \(f.lastPathComponent)")
                            let data = try await WebConverter().convert(fileURL: f, landscape: land, settle: 1.5)
                            guard let d = PDFDocument(data: data), d.pageCount > 0 else { throw KertasError("\(f.lastPathComponent) couldn't be converted.") }
                            urls.append(try FileStore.save(data, base: FileStore.baseName(f), ext: "pdf"))
                        }
                        return ToolOutput(urls: urls)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: tool.color))
            }
        }
    }
}

// MARK: HTML to PDF

struct HTMLToPDFView: View {
    @StateObject private var state = ToolState()
    @State private var address = ""
    @State private var inputs: [URL] = []
    @State private var landscape = false

    var body: some View {
        ToolPage(tool: .htmlToPdf, state: state) {
            Card {
                SectionLabel("Web page address")
                TextField("https://www.example.com", text: $address)
                    .textFieldStyle(.roundedBorder).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SectionLabel("Or an HTML file")
                InputPicker(urls: $inputs, types: [.html], label: "Choose HTML file")
                Toggle("Landscape pages", isOn: $landscape)
            }
            Button("Convert to PDF") {
                let file = inputs.first, land = landscape
                var text = address.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && !text.lowercased().hasPrefix("http") { text = "https://" + text }
                let web = URL(string: text)
                state.runMain("Loading page") { rep in
                    let data = try await WebConverter().convert(fileURL: file, webURL: file == nil ? web : nil, landscape: land, settle: 2.0)
                    let name = file.map(FileStore.baseName) ?? (web?.host ?? "Web page")
                    let url = try FileStore.save(data, base: name, ext: "pdf")
                    return ToolOutput(urls: [url])
                }
            }
            .buttonStyle(PrimaryButtonStyle(color: Tool.htmlToPdf.color))
            .disabled(address.isEmpty && inputs.isEmpty)
        }
    }
}

// MARK: Compare

struct CompareView: View {
    @StateObject private var state = ToolState()
    @State private var first: [URL] = []
    @State private var second: [URL] = []
    @State private var result: TextDiff.Result?
    @State private var showNew = true

    var body: some View {
        ToolPage(tool: .compare, state: state) {
            if let r = result {
                HStack(spacing: 10) {
                    stat("\(r.removed)", "words removed", Color(hex: 0xA32D2D))
                    stat("\(r.added)", "words added", Color(hex: 0x3B6D11))
                }
                Picker("", selection: $showNew) { Text("Original").tag(false); Text("New version").tag(true) }.pickerStyle(.segmented)
                Card { Text(showNew ? r.new : r.old).font(.callout).textSelection(.enabled) }
                Button("Compare other files") { result = nil; first = []; second = [] }.buttonStyle(SecondaryButtonStyle())
            } else {
                SectionLabel("Original")
                InputPicker(urls: $first, label: "Choose original")
                SectionLabel("New version")
                InputPicker(urls: $second, label: "Choose new version")
                if let a = first.first, let b = second.first {
                    Button("Compare") {
                        state.run("Comparing") { rep in
                            let ta = OCR.documentText(try PDFLoader.open(a), progress: rep).joined(separator: "\n")
                            let tb = OCR.documentText(try PDFLoader.open(b), progress: rep).joined(separator: "\n")
                            rep(nil, "Finding differences")
                            let r = TextDiff.compare(ta, tb)
                            DispatchQueue.main.async { result = r }
                            throw CancelSilently()
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(color: Tool.compare.color))
                }
            }
        }
    }

    private func stat(_ n: String, _ label: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(n).font(.title2.weight(.semibold)).foregroundStyle(c)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Lets a tool finish without showing the standard result screen.
struct CancelSilently: Error {}

// MARK: Summarise

struct SummarizeView: View {
    var preset: URL?
    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var style: SummaryStyle = .bullets
    @State private var live = ""
    @State private var running = false
    @State private var stage = ""
    @State private var fraction: Double?
    @State private var job: Task<Void, Never>?
    @State private var ready = false

    var body: some View {
        ToolPage(tool: .summarize, state: state) {
            if let reason = AIEngine.unavailableReason {
                Text(reason).font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 10))
            } else {
                Label(ready ? "AI ready" : "Getting the AI ready…", systemImage: ready ? "checkmark.circle.fill" : "hourglass")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ready ? Color(hex: 0x3B6D11) : Theme.grey)
            }
            if !running { InputPicker(urls: $inputs) }
            if let url = inputs.first {
                Picker("Style", selection: $style) { ForEach(SummaryStyle.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .disabled(running)
                if running || !live.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(stage, systemImage: "sparkles").font(.caption.weight(.medium)).foregroundStyle(Color(hex: 0x993556))
                            Spacer()
                            if running { Button("Stop") { job?.cancel() }.font(.caption.weight(.semibold)) }
                        }
                        if let f = fraction { ProgressView(value: f).tint(Tool.summarize.color) }
                        else if running { ProgressView().progressViewStyle(.linear).tint(Tool.summarize.color) }
                        if !live.isEmpty {
                            Text(live).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Tool.summarize.color, lineWidth: 1.5))
                } else {
                    Text("Runs privately on your iPhone. The summary appears as it's written.").font(.caption).foregroundStyle(.secondary)
                    Button("Summarise") { start(url) }
                        .buttonStyle(PrimaryButtonStyle(color: Tool.summarize.color))
                        .disabled(AIEngine.unavailableReason != nil)
                }
            }
        }
        .preset(preset, into: $inputs)
        .task {
            await AIEngine.prewarm()
            ready = AIEngine.unavailableReason == nil
        }
        .onDisappear { job?.cancel() }
    }

    private func start(_ url: URL) {
        let st = style
        running = true
        live = ""
        stage = "Reading the PDF"
        fraction = nil
        let rep = ProgressReporter { f, t in fraction = f; stage = t }
        job = Task { @MainActor in
            var summary = ""
            do {
                let doc = try PDFLoader.open(url)
                let pages = await Task.detached { OCR.documentText(doc, progress: rep) }.value
                let text = pages.joined(separator: "\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KertasError("No text was found in this PDF.") }
                summary = try await AIEngine.summarizeLive(text, style: st, progress: rep) { partial in
                    live = partial
                    stage = "Writing the summary…"
                    fraction = nil
                }
            } catch is CancellationError {
                summary = live
            } catch {
                if Task.isCancelled { summary = live } else {
                    state.error = error.localizedDescription
                    running = false
                    return
                }
            }
            running = false
            guard !summary.isEmpty else { return }
            let pdf = PDFOps.textPDF(title: "Summary of " + FileStore.baseName(url), sections: [("", summary)])
            do {
                let out = try FileStore.save(pdf, base: FileStore.baseName(url) + " summary", ext: "pdf")
                state.output = ToolOutput(urls: [out], text: summary, message: Task.isCancelled ? "Stopped early, saved what was written" : nil)
            } catch { state.error = error.localizedDescription }
            live = ""
        }
    }
}

// MARK: Translate

struct TranslateView: View {
    var preset: URL?
    var body: some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            TranslateViewImpl(preset: preset)
        } else {
            Text("Translation needs iOS 18 or later.").padding()
        }
        #else
        Text("Translation isn't included in this build.").padding()
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
struct TranslateViewImpl: View {
    var preset: URL?

    enum Choice: String, CaseIterable, Identifiable {
        case enUS = "English (US)", enGB = "English (UK)", malay = "Malay", chinese = "Chinese"
        var id: String { rawValue }
        var detail: String? {
            switch self { case .malay: return "Malaysia"; case .chinese: return "Mandarin"; default: return nil }
        }
    }

    @StateObject private var state = ToolState()
    @State private var inputs: [URL] = []
    @State private var supported: [Locale.Language] = []
    @State private var loaded = false
    @State private var choice: Choice = .enUS
    @State private var target = Locale.Language(identifier: "en-US")
    @State private var britishSpelling = false
    /// How Malay is done on this iPhone.
    @State private var malay: MalayRoute = .checking
    enum MalayRoute: Equatable { case checking, apple(Locale.Language), ai, none }
    @State private var config: TranslationSession.Configuration?
    @State private var pageTexts: [String] = []
    @State private var keepDesign = true
    @State private var fallbackNote: String?
    @State private var showBoxes = false
    @State private var boxesURL: URL?
    @State private var blocks: [[TextBlock]] = []
    @State private var layoutDoc: PDFDocument?

    var body: some View {
        ToolPage(tool: .translate, state: state) {
            InputPicker(urls: $inputs)
            if inputs.first != nil {
                Card {
                    SectionLabel("Translate to")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Choice.allCases) { c in
                            let ok = available(c)
                            Button { choice = c } label: {
                                VStack(spacing: 2) {
                                    Text(c.rawValue).font(.subheadline.weight(.semibold))
                                    if c == .malay, case .ai = malay {
                                        Text("Malaysia · AI translation").font(.caption2).foregroundStyle(.secondary)
                                    } else if let d = c.detail { Text(d).font(.caption2).foregroundStyle(.secondary) }
                                }
                                .foregroundStyle(choice == c ? Color(hex: 0x72243E) : Theme.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(choice == c ? Color(hex: 0xFBEAF0) : Color.white, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(choice == c ? Tool.translate.color : Theme.line, lineWidth: choice == c ? 1.5 : 0.5))
                                .opacity(ok || !loaded ? 1 : 0.45)
                            }
                            .disabled(loaded && !ok)
                        }
                    }
                    if loaded, malay == .none {
                        Text("Malay needs Apple's translator or Apple Intelligence, and neither is available on this iPhone right now.")
                            .font(.caption).foregroundStyle(Theme.red)
                    }
                    if choice == .malay, case .ai = malay {
                        Text("iOS's translator doesn't offer Malay here, so Apple Intelligence translates it on your iPhone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if choice == .enGB && britishSpelling {
                        Text("Translated to English, then spelt the British way (colour, organise, centre).").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The language of the PDF is detected for you. The first time, iOS may ask to download the language.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Card {
                    SectionLabel("Output")
                    Picker("Output", selection: $keepDesign) {
                        Text("Keep original design").tag(true)
                        Text("Plain text document").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Text(keepDesign ? "Same layout, logo, fonts and colours, with the words translated in place."
                                    : "A clean reading copy with the translated text only.")
                        .font(.caption).foregroundStyle(.secondary)
                    if keepDesign {
                        Toggle("Show detected boxes", isOn: $showBoxes).font(.footnote)
                    }
                }
                Button("Translate") { start() }
                    .buttonStyle(PrimaryButtonStyle(color: Tool.translate.color))
                    .disabled(loaded && !available(choice))
            }
        }
        .preset(preset, into: $inputs)
        .task {
            supported = await LanguageAvailability().supportedLanguages
            if let ms = supported.first(where: { $0.languageCode?.identifier == "ms" }) {
                malay = .apple(ms)
            } else {
                // The list can leave out newer languages, so ask directly too.
                let ms = Locale.Language(identifier: "ms")
                let st = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: ms)
                if st != .unsupported { malay = .apple(ms) }
                else { malay = AIEngine.unavailableReason == nil ? .ai : .none }
            }
            loaded = true
            updateTarget()
        }
        .onChange(of: choice) { _, _ in updateTarget() }
        .translationTask(config) { session in
            await translate(session)
        }
    }

    /// The language iOS can actually translate into for each choice.
    private func resolve(_ c: Choice) -> Locale.Language? {
        func find(_ code: String, region: String? = nil, script: String? = nil) -> Locale.Language? {
            supported.first {
                $0.languageCode?.identifier == code
                    && (region == nil || $0.region?.identifier == region)
                    && (script == nil || $0.script?.identifier == script)
            }
        }
        switch c {
        case .enUS: return find("en", region: "US") ?? find("en")
        case .enGB: return find("en", region: "GB") ?? find("en", region: "US") ?? find("en")
        case .malay: if case .apple(let l) = malay { return l } else { return nil }
        case .chinese: return find("zh", script: "Hans") ?? find("zh", region: "CN") ?? find("zh")
        }
    }

    private func available(_ c: Choice) -> Bool {
        if c == .malay { if case .ai = malay { return true } }
        return resolve(c) != nil
    }

    private func updateTarget() {
        guard let lang = resolve(choice) else { return }
        target = lang
        britishSpelling = choice == .enGB && lang.region?.identifier != "GB"
    }

    private func name(_ l: Locale.Language) -> String {
        choice.rawValue
    }

    private func start() {
        guard let url = inputs.first else { return }
        state.busy = true
        state.text = "Reading the PDF"
        let rep = state.reporter
        let useAI: Bool = { if choice == .malay, case .ai = malay { return true }; return false }()
        let keepDesign = keepDesign
        let showBoxes = showBoxes
        fallbackNote = nil
        boxesURL = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try PDFLoader.open(url)
                var layoutFailed = false
                var found: [[TextBlock]] = []
                if keepDesign {
                    found = LayoutTranslator.extract(doc, progress: rep)
                    if !found.contains(where: { $0.contains { $0.needsTranslation } }) {
                        layoutFailed = true
                        DispatchQueue.main.async { fallbackNote = "Plain text: no text blocks were found on the page image." }
                    }
                    if showBoxes {
                        let data = LayoutTranslator.boxes(doc, blocks: found)
                        let boxURL = try? FileStore.save(data, base: FileStore.baseName(url) + " (detected boxes)", ext: "pdf")
                        DispatchQueue.main.async { boxesURL = boxURL }
                    }
                }
                if keepDesign && !layoutFailed {
                    let captured = found
                    DispatchQueue.main.async {
                        blocks = captured
                        layoutDoc = doc
                        if useAI { translateLayoutWithAI(url: url, rep: rep); return }
                        triggerSession()
                    }
                    return
                }
                let texts = OCR.documentText(doc, progress: rep)
                DispatchQueue.main.async {
                    if useAI { translateWithAI(texts, url: url, rep: rep); return }
                    pageTexts = texts
                    if config == nil {
                        config = TranslationSession.Configuration(source: nil, target: target)
                    } else {
                        config?.target = target
                        config?.invalidate()
                    }
                }
            } catch {
                DispatchQueue.main.async { state.error = error.localizedDescription; state.busy = false }
            }
        }
    }

    private func triggerSession() {
        if config == nil {
            config = TranslationSession.Configuration(source: nil, target: target)
        } else {
            config?.target = target
            config?.invalidate()
        }
    }

    @MainActor
    private func translateLayout(_ session: TranslationSession) async {
        guard let url = inputs.first else { return }
        do {
            let units = LayoutTranslator.units(blocks)
            for start in stride(from: 0, to: units.count, by: 40) {
                let slice = Array(start..<min(start + 40, units.count))
                state.fraction = Double(start) / Double(max(units.count, 1))
                state.text = "Translating \(start + 1)–\(start + slice.count) of \(units.count) pieces of text"
                let requests = slice.map { TranslationSession.Request(sourceText: units[$0].text, clientIdentifier: "\($0)") }
                let responses = try await session.translations(from: requests)
                for r in responses {
                    guard let id = r.clientIdentifier, let n = Int(id), n < units.count else { continue }
                    let text = britishSpelling ? BritishSpelling.convert(r.targetText) : r.targetText
                    LayoutTranslator.apply(text, to: units[n], in: &blocks)
                }
            }
            finishLayout(url: url, languageName: choice.rawValue)
        } catch {
            state.error = error.localizedDescription
            state.busy = false
        }
    }

    private func translateLayoutWithAI(url: URL, rep: ProgressReporter) {
        Task { @MainActor in
            do {
                let units = LayoutTranslator.units(blocks)
                let language = "Malay (Bahasa Melayu as used in Malaysia)"
                for start in stride(from: 0, to: units.count, by: 15) {
                    let slice = Array(start..<min(start + 15, units.count))
                    // Numbered list so one request covers many pieces.
                    let list = slice.enumerated().map { "\($0.offset + 1). \(units[$0.element].text)" }.joined(separator: "\n")
                    let reply = try await AIEngine.translate(list, into: language + ". Keep the same numbering, one numbered item per line",
                                                             progress: rep, label: "Translating \(start + 1)–\(start + slice.count) of \(units.count)")
                    var map: [Int: String] = [:]
                    for line in reply.components(separatedBy: "\n") {
                        let t = line.trimmingCharacters(in: .whitespaces)
                        guard let dot = t.firstIndex(of: "."), let n = Int(t[t.startIndex..<dot]) else { continue }
                        map[n] = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
                    }
                    for (k, u) in slice.enumerated() {
                        let text: String
                        if let m = map[k + 1], !m.isEmpty { text = m }
                        else { text = try await AIEngine.translate(units[u].text, into: language, progress: rep, label: "Translating \(u + 1) of \(units.count)") }
                        LayoutTranslator.apply(text, to: units[u], in: &blocks)
                    }
                }
                finishLayout(url: url, languageName: "Malay")
            } catch {
                state.error = error.localizedDescription
                state.busy = false
            }
        }
    }

    @MainActor
    private func finishLayout(url: URL, languageName: String) {
        guard let doc = layoutDoc else { state.busy = false; return }
        let all = blocks
        let rep = state.reporter
        state.fraction = nil
        state.text = "Laying out the translation"
        DispatchQueue.global(qos: .userInitiated).async {
            let data = LayoutTranslator.render(doc, blocks: all, progress: rep)
            let joined = all.flatMap { $0 }.compactMap(\.translated).joined(separator: "\n")
            DispatchQueue.main.async {
                do {
                    let out = try FileStore.save(data, base: FileStore.baseName(url) + " " + languageName + " (design)", ext: "pdf")
                    state.output = ToolOutput(urls: [out] + (boxesURL.map { [$0] } ?? []), text: String(joined.prefix(3000)) + (joined.count > 3000 ? "\n…" : ""),
                                              message: "Original design kept · translated to \(languageName)")
                } catch {
                    state.error = error.localizedDescription
                }
                state.busy = false
                blocks = []
                layoutDoc = nil
            }
        }
    }

    private func translateWithAI(_ texts: [String], url: URL, rep: ProgressReporter) {
        Task { @MainActor in
            do {
                var sections: [(String, String)] = []
                var all: [String] = []
                for (i, text) in texts.enumerated() {
                    let paras = paragraphs(text)
                    guard !paras.isEmpty else { continue }
                    let body = try await AIEngine.translate(paras.joined(separator: "\n\n"), into: "Malay (Bahasa Melayu as used in Malaysia)",
                                                            progress: rep, label: "Translating page \(i + 1) of \(texts.count)")
                    sections.append(("Halaman \(i + 1)", body))
                    all.append(body)
                }
                guard !all.isEmpty else { throw KertasError("No text was found in this PDF.") }
                let base = FileStore.baseName(url)
                let pdf = PDFOps.textPDF(title: base + " (Bahasa Melayu)", sections: sections)
                let out = try FileStore.save(pdf, base: base + " Malay (text)", ext: "pdf")
                let joined = all.joined(separator: "\n\n")
                state.output = ToolOutput(urls: [out], text: String(joined.prefix(4000)) + (joined.count > 4000 ? "\n…" : ""), message: fallbackNote ?? "Plain text · translated to Malay with Apple Intelligence")
            } catch {
                state.error = error.localizedDescription
            }
            state.busy = false
        }
    }

    /// Joins broken lines into paragraphs so each sentence is translated whole.
    private func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if !cur.isEmpty { out.append(cur); cur = "" }; continue }
            cur += cur.isEmpty ? line : " " + line
            if let last = line.last, ".!?:".contains(last) { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    @MainActor
    private func translate(_ session: TranslationSession) async {
        if !blocks.isEmpty { await translateLayout(session); return }
        guard !pageTexts.isEmpty, let url = inputs.first else { return }
        do {
            var sections: [(String, String)] = []
            var all: [String] = []
            for (i, text) in pageTexts.enumerated() {
                state.fraction = Double(i) / Double(pageTexts.count)
                state.text = "Translating page \(i + 1) of \(pageTexts.count)"
                let paras = paragraphs(text)
                guard !paras.isEmpty else { continue }
                let requests = paras.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: "\($0.offset)") }
                let responses = try await session.translations(from: requests)
                let ordered = responses.sorted { Int($0.clientIdentifier ?? "0") ?? 0 < Int($1.clientIdentifier ?? "0") ?? 0 }
                var body = ordered.map(\.targetText).joined(separator: "\n\n")
                if britishSpelling { body = BritishSpelling.convert(body) }
                sections.append(("Page \(i + 1)", body))
                all.append(body)
            }
            let base = FileStore.baseName(url)
            let pdf = PDFOps.textPDF(title: base + " (\(name(target)))", sections: sections)
            let out = try FileStore.save(pdf, base: base + " " + name(target) + " (text)", ext: "pdf")
            let joined = all.joined(separator: "\n\n")
            state.output = ToolOutput(urls: [out], text: String(joined.prefix(4000)) + (joined.count > 4000 ? "\n…" : ""), message: fallbackNote ?? "Plain text · translated to \(name(target))")
        } catch {
            state.error = error.localizedDescription
        }
        state.busy = false
        pageTexts = []
    }
}
#endif
