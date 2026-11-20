import Foundation
import PDFKit
import UIKit

extension Notification.Name {
    static let kertasFilesChanged = Notification.Name("kertasFilesChanged")
}

struct KertasError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum FileStore {
    static var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Private app data (fonts, signatures). Not shown in the Files app.
    static func support(_ sub: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static var inbox: URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("KertasInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = s.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Kertas" : String(cleaned.prefix(80))
    }

    static func uniqueURL(base: String, ext: String, in dir: URL = docs) -> URL {
        let clean = sanitize(base)
        var url = dir.appendingPathComponent(clean).appendingPathExtension(ext)
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(clean) \(i)").appendingPathExtension(ext)
            i += 1
        }
        return url
    }

    @discardableResult
    static func save(_ data: Data, base: String, ext: String, in dir: URL = docs) throws -> URL {
        let url = uniqueURL(base: base, ext: ext, in: dir)
        try data.write(to: url, options: .atomic)
        notify()
        return url
    }

    static func save(_ doc: PDFDocument, base: String) throws -> URL {
        guard let data = doc.dataRepresentation() else { throw KertasError("Couldn't write the PDF.") }
        return try save(data, base: base, ext: "pdf")
    }

    static func folder(named base: String) -> URL {
        let url = uniqueURL(base: base, ext: "", in: docs).deletingPathExtension()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: .kertasFilesChanged, object: nil) }
    }

    /// Copies a picked file into the app so it stays readable after the picker closes.
    static func importCopy(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = uniqueURL(base: url.deletingPathExtension().lastPathComponent,
                             ext: url.pathExtension.isEmpty ? "dat" : url.pathExtension, in: inbox)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            var coordError: NSError?
            var result: URL?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                if (try? FileManager.default.copyItem(at: readURL, to: dest)) != nil { result = dest }
            }
            return result
        }
    }

    /// Moves a file opened from another app into Documents.
    static func adopt(_ url: URL) -> URL? {
        guard let copy = importCopy(url) else { return nil }
        let dest = uniqueURL(base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension.isEmpty ? "pdf" : url.pathExtension)
        do {
            try FileManager.default.moveItem(at: copy, to: dest)
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            notify()
            return dest
        } catch { return nil }
    }

    static func list() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { $0.lastPathComponent != "Inbox" }.sorted { modified($0) > modified($1) }
    }

    static func pdfs() -> [URL] { list().filter { $0.pathExtension.lowercased() == "pdf" } }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    static func size(_ url: URL) -> Int64 {
        if isDirectory(url) {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + size($1) }
        }
        return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func baseName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}

enum PDFLoader {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw KertasError("\(url.lastPathComponent) can't be opened as a PDF. Try Repair PDF.")
        }
        if doc.isLocked {
            throw KertasError("\(url.lastPathComponent) has a password. Use Unlock PDF first.")
        }
        return doc
    }
}

/// Parses "1-3, 5, 8-" into zero-based page indexes. Pages are 1-based for the user.
enum PageRanges {
    static func parse(_ text: String, pageCount: Int) -> [[Int]]? {
        var groups: [[Int]] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if p.contains("-") {
                let bits = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard bits.count == 2 else { return nil }
                let a = Int(bits[0]) ?? 1
                let b = bits[1].isEmpty ? pageCount : (Int(bits[1]) ?? -1)
                guard a >= 1, b >= a, b <= pageCount else { return nil }
                groups.append(Array((a - 1)...(b - 1)))
            } else {
                guard let n = Int(p), n >= 1, n <= pageCount else { return nil }
                groups.append([n - 1])
            }
        }
        return groups.isEmpty ? nil : groups
    }

    static func label(_ indexes: [Int]) -> String {
        guard let f = indexes.first, let l = indexes.last else { return "" }
        return f == l ? "\(f + 1)" : "\(f + 1)-\(l + 1)"
    }
}
