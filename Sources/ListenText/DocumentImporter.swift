import AppKit
import PDFKit
import ReaderCore

@MainActor
enum DocumentImporter {
    static let plainExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "jsonl", "log",
        "xml", "yaml", "yml", "toml", "ini", "conf", "srt", "vtt", "swift", "py", "js", "css"
    ]
    static let richTypes: [String: NSAttributedString.DocumentType] = [
        "rtf": .rtf, "docx": .officeOpenXML
    ]

    static func load(_ url: URL) async throws -> String {
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
            return try await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(data: data), !document.isLocked,
                      let text = document.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DocumentError.noPDFText
                }
                return try TextDecoder.cleaned(text)
            }.value
        }
        if ext == "html" || ext == "htm" {
            return try await Task.detached(priority: .userInitiated) { try HTMLTextExtractor.extract(data) }.value
        }
        if let type = richTypes[ext] {
            let text = try NSAttributedString(data: data, options: [
                .documentType: type
            ], documentAttributes: nil).string
            return try TextDecoder.cleaned(text)
        }
        return try TextDecoder.decode(data)
    }
}
