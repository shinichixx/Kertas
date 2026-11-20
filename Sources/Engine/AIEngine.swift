import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SummaryStyle: String, CaseIterable, Identifiable {
    case short = "Short", bullets = "Key points", detailed = "Detailed"
    var id: String { rawValue }
    var ask: String {
        switch self {
        case .short: return "Write a short summary in one paragraph of no more than 120 words."
        case .bullets: return "List the key points as short bullet points starting with \"• \". Keep numbers, dates, names and decisions."
        case .detailed: return "Write a detailed summary with a short heading for each main topic. Keep numbers, dates, names, actions and decisions."
        }
    }
}

enum AIEngine {
    /// Nil when available, otherwise the reason it can't run.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings to use the summariser."
                case .deviceNotEligible: return "This iPhone doesn't support Apple Intelligence."
                case .modelNotReady: return "Apple Intelligence is still downloading. Try again in a while."
                @unknown default: return "Apple Intelligence isn't available right now."
                }
            }
        }
        return "The summariser needs iOS 26 with Apple Intelligence."
        #else
        return "This build doesn't include the on-device AI. It needs to be built with Xcode 26."
        #endif
    }

    static func chunks(_ text: String, size: Int = 6000) -> [String] {
        var out: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n") {
            if current.count + para.count > size, !current.isEmpty {
                out.append(current); current = ""
            }
            if para.count > size {
                var rest = Substring(para)
                while rest.count > size { out.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + para
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(current) }
        return out
    }

    static func summarize(_ text: String, style: SummaryStyle, progress: ProgressReporter) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let reason = unavailableReason { throw KertasError(reason) }
            let instructions = "You summarise documents accurately. Only use facts found in the text. Reply in the same language as the document."
            var parts = chunks(text)
            guard !parts.isEmpty else { throw KertasError("There's no text to summarise.") }
            var round = 0
            while parts.count > 1 {
                round += 1
                var notes: [String] = []
                for (i, part) in parts.enumerated() {
                    progress(Double(i) / Double(parts.count), "Reading part \(i + 1) of \(parts.count)" + (round > 1 ? " (round \(round))" : ""))
                    let session = LanguageModelSession(instructions: instructions)
                    let r = try await session.respond(to: "Write concise notes covering every important point in this part of a document. Keep numbers, dates and names.\n\n" + part)
                    notes.append(r.content)
                }
                parts = chunks(notes.joined(separator: "\n"))
            }
            progress(nil, "Writing the summary")
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: style.ask + "\n\nDocument:\n" + parts[0])
            return r.content
        }
        #endif
        throw KertasError(unavailableReason ?? "The summariser isn't available.")
    }
}

extension AIEngine {
    /// Loads the model into memory ahead of use, so the first answer starts sooner.
    static func prewarm() async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), unavailableReason == nil {
            LanguageModelSession(instructions: "You summarise documents accurately.").prewarm()
        }
        #endif
    }

    /// Like `summarize`, but streams the final summary as it's written.
    @MainActor
    static func summarizeLive(_ text: String, style: SummaryStyle, progress: ProgressReporter, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let reason = unavailableReason { throw KertasError(reason) }
            let instructions = "You summarise documents accurately. Only use facts found in the text. Reply in the same language as the document."
            var parts = chunks(text)
            guard !parts.isEmpty else { throw KertasError("There's no text to summarise.") }
            var round = 0
            while parts.count > 1 {
                round += 1
                var notes: [String] = []
                for (i, part) in parts.enumerated() {
                    try Task.checkCancellation()
                    progress(Double(i) / Double(parts.count), "Reading part \(i + 1) of \(parts.count)" + (round > 1 ? " (round \(round))" : ""))
                    let session = LanguageModelSession(instructions: instructions)
                    let r = try await session.respond(to: "Write concise notes covering every important point in this part of a document. Keep numbers, dates and names.\n\n" + part)
                    notes.append(r.content)
                }
                parts = chunks(notes.joined(separator: "\n"))
            }
            try Task.checkCancellation()
            let session = LanguageModelSession(instructions: instructions)
            var latest = ""
            for try await snap in session.streamResponse(to: style.ask + "\n\nDocument:\n" + parts[0]) {
                latest = snap.content
                onPartial(latest)
                if Task.isCancelled { break }
            }
            return latest
        }
        #endif
        throw KertasError(unavailableReason ?? "The summariser isn't available.")
    }

    /// Translates with Apple Intelligence, for languages iOS's translator doesn't offer.
    static func translate(_ text: String, into language: String, progress: ProgressReporter, label: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let reason = unavailableReason { throw KertasError(reason) }
            var out: [String] = []
            let parts = chunks(text, size: 2500)
            for (i, part) in parts.enumerated() {
                progress(nil, label + (parts.count > 1 ? " (part \(i + 1) of \(parts.count))" : ""))
                let session = LanguageModelSession(instructions: "You are a professional translator. Translate everything the user gives you into \(language). Keep names, numbers, dates and line breaks. Reply with the translation only, no notes.")
                let r = try await session.respond(to: part)
                out.append(r.content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return out.joined(separator: "\n")
        }
        #endif
        throw KertasError(unavailableReason ?? "AI translation isn't available.")
    }
}

enum TextDiff {
    struct Result {
        var old: AttributedString
        var new: AttributedString
        var removed: Int
        var added: Int
    }

    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func compare(_ a: String, _ b: String) -> Result {
        let wa = Array(words(a).prefix(20000)), wb = Array(words(b).prefix(20000))
        let diff = wb.difference(from: wa)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        func build(_ w: [String], _ marks: Set<Int>, _ colour: (bg: UInt32, fg: UInt32)) -> AttributedString {
            var out = AttributedString()
            for (i, word) in w.enumerated() {
                var piece = AttributedString(word)
                if marks.contains(i) {
                    piece.swiftUI.backgroundColor = Color(hex: colour.bg)
                    piece.swiftUI.foregroundColor = Color(hex: colour.fg)
                }
                out += piece
                out += AttributedString(" ")
            }
            return out
        }
        return Result(old: build(wa, removed, (0xF7C1C1, 0x791F1F)),
                      new: build(wb, inserted, (0xC0DD97, 0x27500A)),
                      removed: removed.count, added: inserted.count)
    }
}
