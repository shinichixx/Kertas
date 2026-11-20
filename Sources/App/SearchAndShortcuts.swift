import Foundation
import CoreSpotlight
import UniformTypeIdentifiers
import AppIntents

/// Puts every Kertas tool into iPhone search, with English and Malay keywords.
enum SpotlightIndex {
    private static let version = 1

    static func keywords(_ tool: Tool) -> [String] {
        let common = ["kertas", "pdf", "ilovepdf", "pdf tools", "pdf editor"]
        let own: [String]
        switch tool {
        case .scan: own = ["scan", "scanner", "document scanner", "camscanner", "scan document", "imbas", "imbasan", "kamera", "camera"]
        case .merge: own = ["merge", "combine", "join", "gabung", "cantum"]
        case .split: own = ["split", "separate", "pisah", "bahagi"]
        case .removePages: own = ["remove pages", "delete pages", "buang muka surat"]
        case .extractPages: own = ["extract", "pages", "ambil muka surat"]
        case .organize: own = ["organise", "organize", "reorder", "susun"]
        case .compress: own = ["compress", "reduce size", "smaller", "mampat", "kecilkan"]
        case .repair: own = ["repair", "fix", "damaged", "baiki"]
        case .ocr: own = ["ocr", "text recognition", "searchable", "copy text", "scan"]
        case .jpgToPdf: own = ["jpg to pdf", "image to pdf", "photo to pdf", "picture", "gambar", "convert"]
        case .wordToPdf: own = ["word to pdf", "docx", "convert"]
        case .pptToPdf: own = ["powerpoint to pdf", "pptx", "slides", "convert"]
        case .excelToPdf: own = ["excel to pdf", "xlsx", "spreadsheet", "convert"]
        case .htmlToPdf: own = ["html to pdf", "web page", "website", "convert"]
        case .pdfToJpg: own = ["pdf to jpg", "pdf to image", "convert", "gambar"]
        case .extractImages: own = ["extract images", "pictures", "gambar"]
        case .pdfToText: own = ["pdf to text", "markdown", "txt", "copy text"]
        case .edit: own = ["edit", "edit pdf", "change text", "font", "sunting", "ubah"]
        case .rotate: own = ["rotate", "putar"]
        case .crop: own = ["crop", "trim", "potong"]
        case .pageNumbers: own = ["page number", "page numbers", "nombor muka surat"]
        case .watermark: own = ["watermark", "stamp", "confidential", "tera air"]
        case .forms: own = ["form", "fill", "borang", "isi"]
        case .sign: own = ["sign", "signature", "esign", "tandatangan"]
        case .protect: own = ["protect", "password", "lock", "encrypt", "kata laluan", "kunci"]
        case .unlock: own = ["unlock", "remove password", "decrypt", "buka kunci"]
        case .redact: own = ["redact", "black out", "hide", "sembunyi"]
        case .compare: own = ["compare", "difference", "diff", "banding"]
        case .summarize: own = ["summarise", "summarize", "summary", "ai", "ringkasan"]
        case .translate: own = ["translate", "translation", "terjemah", "malay", "english", "chinese"]
        }
        return own + common
    }

    static func indexTools() {
        let key = "spotlightIndexVersion"
        guard UserDefaults.standard.integer(forKey: key) < version else { return }
        var items: [CSSearchableItem] = Tool.allCases.map { tool in
            let attrs = CSSearchableItemAttributeSet(contentType: .content)
            attrs.title = tool.title
            attrs.contentDescription = tool.subtitle
            attrs.keywords = keywords(tool)
            attrs.displayName = tool.title
            return CSSearchableItem(uniqueIdentifier: "tool.\(tool.rawValue)", domainIdentifier: "tools", attributeSet: attrs)
        }
        let photo = CSSearchableItemAttributeSet(contentType: .content)
        photo.title = "Scan from photo"
        photo.contentDescription = "Straighten a document in a photo you already took"
        photo.keywords = ["scan", "scanner", "photo", "gambar", "imbas", "straighten", "kertas", "pdf"]
        items.append(CSSearchableItem(uniqueIdentifier: "tool.scanPhoto", domainIdentifier: "tools", attributeSet: photo))
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: ["tools"]) { _ in
            CSSearchableIndex.default().indexSearchableItems(items) { error in
                if error == nil { UserDefaults.standard.set(version, forKey: key) }
            }
        }
    }
}

// MARK: - Quick actions for Spotlight, Siri and Shortcuts

struct ScanDocumentIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan document"
    static var description = IntentDescription("Open the Kertas scanner with the camera.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.start(scan: .camera)
        return .result()
    }
}

struct ScanPhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan from photo"
    static var description = IntentDescription("Straighten a document in a photo.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        AppRouter.shared.start(scan: .photos)
        return .result()
    }
}

struct MergeIntent: AppIntent {
    static var title: LocalizedStringResource = "Merge PDF"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.open(.merge); return .result() }
}

struct CompressIntent: AppIntent {
    static var title: LocalizedStringResource = "Compress PDF"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.open(.compress); return .result() }
}

struct SignIntent: AppIntent {
    static var title: LocalizedStringResource = "Sign PDF"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.open(.sign); return .result() }
}

struct EditIntent: AppIntent {
    static var title: LocalizedStringResource = "Edit PDF"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.open(.edit); return .result() }
}

struct OCRIntent: AppIntent {
    static var title: LocalizedStringResource = "OCR PDF"
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.open(.ocr); return .result() }
}

struct KertasShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanDocumentIntent(), phrases: ["Scan with \(.applicationName)", "Scan a document in \(.applicationName)", "\(.applicationName) scan"],
                    shortTitle: "Scan document", systemImageName: "doc.viewfinder")
        AppShortcut(intent: ScanPhotoIntent(), phrases: ["Scan a photo with \(.applicationName)", "Straighten a photo in \(.applicationName)"],
                    shortTitle: "Scan from photo", systemImageName: "photo.badge.checkmark")
        AppShortcut(intent: MergeIntent(), phrases: ["Merge PDF in \(.applicationName)", "Combine PDFs with \(.applicationName)"],
                    shortTitle: "Merge PDF", systemImageName: "square.on.square")
        AppShortcut(intent: CompressIntent(), phrases: ["Compress PDF in \(.applicationName)", "Make a PDF smaller with \(.applicationName)"],
                    shortTitle: "Compress PDF", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: SignIntent(), phrases: ["Sign PDF in \(.applicationName)", "Sign a document with \(.applicationName)"],
                    shortTitle: "Sign PDF", systemImageName: "signature")
        AppShortcut(intent: EditIntent(), phrases: ["Edit PDF in \(.applicationName)"],
                    shortTitle: "Edit PDF", systemImageName: "pencil.and.outline")
        AppShortcut(intent: OCRIntent(), phrases: ["OCR PDF in \(.applicationName)", "Make a PDF searchable with \(.applicationName)"],
                    shortTitle: "OCR PDF", systemImageName: "text.viewfinder")
    }
}
