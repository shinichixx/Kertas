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

    var body: some View {
        ToolPage(tool: .summarize, state: state) {
            if let reason = AIEngine.unavailableReason {
                Text(reason).font(.footnote).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Theme.redSoft, in: RoundedRectangle(cornerRadius: 10))
            }
            InputPicker(urls: $inputs)
            if let url = inputs.first {
                Picker("Style", selection: $style) { ForEach(SummaryStyle.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Text("Runs privately on your iPhone. Long PDFs take a while.").font(.caption).foregroundStyle(.secondary)
                Button("Summarise") {
                    let st = style
                    state.runMain("Reading the PDF") { rep in
                        let doc = try PDFLoader.open(url)
                        let pages = await Task.detached { OCR.documentText(doc, progress: rep) }.value
                        let text = pages.joined(separator: "\n")
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw KertasError("No text was found in this PDF.") }
                        let summary = try await AIEngine.summarize(text, style: st, progress: rep)
                        let pdf = PDFOps.textPDF(title: "Summary of " + FileStore.baseName(url), sections: [("", summary)])
                        let out = try FileStore.save(pdf, base: FileStore.baseName(url) + " summary", ext: "pdf")
                        return ToolOutput(urls: [out], text: summary)
                    }
                }
                .buttonStyle(PrimaryButtonStyle(color: Tool.summarize.color))
            }
        }
        .preset(preset, into: $inputs)
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
    @State private var config: TranslationSession.Configuration?
    @State private var pageTexts: [String] = []

    var body: some View {
        ToolPage(tool: .translate, state: state) {
            InputPicker(urls: $inputs)
            if inputs.first != nil {
                Card {
                    SectionLabel("Translate to")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(Choice.allCases) { c in
                            let ok = resolve(c) != nil
                            Button { choice = c } label: {
                                VStack(spacing: 2) {
                                    Text(c.rawValue).font(.subheadline.weight(.semibold))
                                    if let d = c.detail { Text(d).font(.caption2).foregroundStyle(.secondary) }
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
                    if loaded && resolve(.malay) == nil {
                        Text("Update to iOS 27 to translate into Malay.").font(.caption).foregroundStyle(Theme.red)
                    }
                    if choice == .enGB && britishSpelling {
                        Text("Translated to English, then spelt the British way (colour, organise, centre).").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The language of the PDF is detected for you. The first time, iOS may ask to download the language.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Translate") { start() }
                    .buttonStyle(PrimaryButtonStyle(color: Tool.translate.color))
                    .disabled(loaded && resolve(choice) == nil)
            }
        }
        .preset(preset, into: $inputs)
        .task {
            supported = await LanguageAvailability().supportedLanguages
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
        case .malay: return find("ms")
        case .chinese: return find("zh", script: "Hans") ?? find("zh", region: "CN") ?? find("zh")
        }
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
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let doc = try PDFLoader.open(url)
                let texts = OCR.documentText(doc, progress: rep)
                DispatchQueue.main.async {
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
            let out = try FileStore.save(pdf, base: base + " " + name(target), ext: "pdf")
            let joined = all.joined(separator: "\n\n")
            state.output = ToolOutput(urls: [out], text: String(joined.prefix(4000)) + (joined.count > 4000 ? "\n…" : ""), message: "Translated to \(name(target))")
        } catch {
            state.error = error.localizedDescription
        }
        state.busy = false
        pageTexts = []
    }
}
#endif
