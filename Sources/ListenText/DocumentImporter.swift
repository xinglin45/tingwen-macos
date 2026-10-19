import AppKit
import PDFKit
import ReaderCore
import CryptoKit

struct ImportedDocument: Sendable {
    let text: String
    var sourceEncoding: TextEncoding? = nil
    var convertedUTF8URL: URL? = nil
}

@MainActor
enum DocumentImporter {
    static let plainExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "log",
        "xml", "yaml", "yml", "toml", "ini", "conf", "srt", "vtt", "swift", "py", "js", "css"
    ]
    static let richTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "docx": .officeOpenXML
    ]

    static func load(_ url: URL) async throws -> String { try await read(url).text }

    static func read(_ url: URL, encoding: TextEncoding = .automatic, conversionDirectory: URL? = nil) async throws -> ImportedDocument {
        let ext = url.pathExtension.lowercased()
        guard plainExtensions.contains(ext) || ext.isEmpty || richTypes[ext] != nil || ["pdf", "html", "htm"].contains(ext) else {
            throw DocumentError.unsupported
        }
        let data = try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw DocumentError.unsupported }
            guard (values.fileSize ?? 0) <= TextDecoder.maximumBytes else { throw DocumentError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= TextDecoder.maximumBytes else { throw DocumentError.tooLarge }
            return data
        }.value
        if ext == "pdf" {
            let text = try await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(data: data), !document.isLocked,
                      let text = document.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DocumentError.noPDFText
                }
                return try TextDecoder.cleaned(text)
            }.value
            return ImportedDocument(text: text)
        }
        if ext == "html" || ext == "htm" {
            return try await Task.detached(priority: .userInitiated) {
                let decoded = try TextDecoder.decodeDetected(data, encoding: encoding)
                let text = try HTMLTextExtractor.extract(sourceText: decoded.text)
                return try imported(text: text, encoding: decoded.encoding, directory: conversionDirectory)
            }.value
        }
        if let type = richTypes[ext] {
            let text = try NSAttributedString(data: data, options: [
                .documentType: type
            ], documentAttributes: nil).string
            return ImportedDocument(text: try TextDecoder.cleaned(text))
        }
        return try await Task.detached(priority: .userInitiated) {
            let decoded = try TextDecoder.decodeDetected(data, encoding: encoding)
            return try imported(text: decoded.text, encoding: decoded.encoding, directory: conversionDirectory)
        }.value
    }

    private nonisolated static func imported(text: String, encoding: TextEncoding, directory: URL?) throws -> ImportedDocument {
        var result = ImportedDocument(text: text, sourceEncoding: encoding)
        if encoding != .utf8, let directory {
            let utf8 = Data(text.utf8)
            let digest = SHA256.hash(data: utf8).map { String(format: "%02x", $0) }.joined()
            let converted = directory.appendingPathComponent("\(digest).txt")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if (try? Data(contentsOf: converted)) != utf8 { try utf8.write(to: converted, options: .atomic) }
            result.convertedUTF8URL = converted
        }
        return result
    }
}
