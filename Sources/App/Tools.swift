import SwiftUI

enum ToolCategory: String, CaseIterable, Identifiable {
    case organise = "Organise"
    case optimise = "Optimise"
    case convert = "Convert"
    case edit = "Edit"
    case security = "Security"
    case ai = "AI"
    var id: String { rawValue }
}

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case scan, merge, split, removePages, extractPages, organize
    case compress, repair, ocr
    case jpgToPdf, wordToPdf, pptToPdf, excelToPdf, htmlToPdf, pdfToJpg, extractImages, pdfToText
    case edit, rotate, crop, pageNumbers, watermark, forms
    case sign, protect, unlock, redact, compare
    case summarize, translate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Scan to PDF"
        case .merge: return "Merge PDF"
        case .split: return "Split PDF"
        case .removePages: return "Remove pages"
        case .extractPages: return "Extract pages"
        case .organize: return "Organise PDF"
        case .compress: return "Compress PDF"
        case .repair: return "Repair PDF"
        case .ocr: return "OCR PDF"
        case .jpgToPdf: return "JPG to PDF"
        case .wordToPdf: return "Word to PDF"
        case .pptToPdf: return "PowerPoint to PDF"
        case .excelToPdf: return "Excel to PDF"
        case .htmlToPdf: return "HTML to PDF"
        case .pdfToJpg: return "PDF to JPG"
        case .extractImages: return "Extract images"
        case .pdfToText: return "PDF to text"
        case .edit: return "Edit PDF"
        case .rotate: return "Rotate PDF"
        case .crop: return "Crop PDF"
        case .pageNumbers: return "Page numbers"
        case .watermark: return "Add watermark"
        case .forms: return "PDF forms"
        case .sign: return "Sign PDF"
        case .protect: return "Protect PDF"
        case .unlock: return "Unlock PDF"
        case .redact: return "Redact PDF"
        case .compare: return "Compare PDF"
        case .summarize: return "AI summariser"
        case .translate: return "Translate PDF"
        }
    }

    var subtitle: String {
        switch self {
        case .scan: return "Camera or photo, straightened like a flatbed scan"
        case .merge: return "Combine several PDFs into one, in the order you want"
        case .split: return "Split by page ranges, every few pages or every page"
        case .removePages: return "Pick pages to delete from a PDF"
        case .extractPages: return "Pull chosen pages into a new PDF"
        case .organize: return "Reorder, rotate and delete pages"
        case .compress: return "Make the file smaller while keeping it readable"
        case .repair: return "Rebuild a damaged PDF and recover its pages"
        case .ocr: return "Make a scanned PDF searchable and copyable"
        case .jpgToPdf: return "Turn photos and images into a PDF"
        case .wordToPdf: return "Convert DOC and DOCX files to PDF"
        case .pptToPdf: return "Convert PPT and PPTX slides to PDF"
        case .excelToPdf: return "Convert XLS and XLSX sheets to PDF"
        case .htmlToPdf: return "Save a web page or HTML file as PDF"
        case .pdfToJpg: return "Turn every page into a JPG image"
        case .extractImages: return "Save the pictures inside a PDF"
        case .pdfToText: return "Get the text out as plain text or Markdown"
        case .edit: return "Change text with a matching font, add text, images, drawings and notes"
        case .rotate: return "Rotate all pages or just the ones you pick"
        case .crop: return "Trim the margins of your pages"
        case .pageNumbers: return "Add page numbers where you want them"
        case .watermark: return "Stamp text or an image over your pages"
        case .forms: return "Fill in a PDF form"
        case .sign: return "Sign with your finger and place it on the page"
        case .protect: return "Lock a PDF with a password"
        case .unlock: return "Remove the password from a PDF"
        case .redact: return "Black out text and remove it for good"
        case .compare: return "See what changed between two versions"
        case .summarize: return "Summarise a PDF with on-device AI"
        case .translate: return "Translate a PDF on your iPhone"
        }
    }

    var icon: String {
        switch self {
        case .scan: return "doc.viewfinder"
        case .merge: return "square.on.square"
        case .split: return "scissors"
        case .removePages: return "trash"
        case .extractPages: return "arrow.up.doc"
        case .organize: return "square.grid.2x2"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .repair: return "wrench.and.screwdriver"
        case .ocr: return "text.viewfinder"
        case .jpgToPdf: return "photo"
        case .wordToPdf: return "doc.richtext"
        case .pptToPdf: return "rectangle.on.rectangle.angled"
        case .excelToPdf: return "tablecells"
        case .htmlToPdf: return "globe"
        case .pdfToJpg: return "photo.on.rectangle"
        case .extractImages: return "photo.stack"
        case .pdfToText: return "text.alignleft"
        case .edit: return "pencil.and.outline"
        case .rotate: return "rotate.right"
        case .crop: return "crop"
        case .pageNumbers: return "number"
        case .watermark: return "drop"
        case .forms: return "list.bullet.rectangle"
        case .sign: return "signature"
        case .protect: return "lock"
        case .unlock: return "lock.open"
        case .redact: return "rectangle.fill.on.rectangle.fill"
        case .compare: return "doc.on.doc"
        case .summarize: return "sparkles"
        case .translate: return "character.bubble"
        }
    }

    var category: ToolCategory {
        switch self {
        case .scan, .merge, .split, .removePages, .extractPages, .organize: return .organise
        case .compress, .repair, .ocr: return .optimise
        case .jpgToPdf, .wordToPdf, .pptToPdf, .excelToPdf, .htmlToPdf, .pdfToJpg, .extractImages, .pdfToText: return .convert
        case .edit, .rotate, .crop, .pageNumbers, .watermark, .forms: return .edit
        case .sign, .protect, .unlock, .redact, .compare: return .security
        case .summarize, .translate: return .ai
        }
    }

    var color: Color {
        switch self {
        case .wordToPdf: return Color(hex: 0x2B5DB8)
        case .excelToPdf: return Color(hex: 0x1F8A4C)
        case .pptToPdf: return Color(hex: 0xD2502A)
        case .htmlToPdf: return Color(hex: 0xBA7517)
        case .jpgToPdf, .pdfToJpg, .extractImages: return Color(hex: 0xE0A21B)
        case .pdfToText: return Color(hex: 0x378ADD)
        default:
            switch category {
            case .organise: return Color(hex: 0xE5322D)
            case .optimise: return Color(hex: 0x4E9A2B)
            case .convert: return Color(hex: 0xBA7517)
            case .edit: return Color(hex: 0x7F5FD8)
            case .security: return Color(hex: 0x3A4A5C)
            case .ai: return Color(hex: 0xD4537E)
            }
        }
    }
}

struct ToolIcon: View {
    let tool: Tool
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: tool.icon)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(tool.color)
            .frame(width: size * 1.9, height: size * 1.9)
            .background(tool.color.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.45))
    }
}
