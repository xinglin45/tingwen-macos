import Foundation

public struct ReadingCheckpoint: Codable, Equatable, Sendable {
    public let offset: Int
    public let textLength: Int
    public let chapterIndex: Int
    public let chapterTitle: String
    public let anchor: String
    public let finished: Bool

    public init(text: String, chapters: [DocumentChapter], offset: Int, finished: Bool = false) {
        self.init(source: text as NSString, chapters: chapters, offset: offset, finished: finished)
    }

    public init(source: NSString, chapters: [DocumentChapter], offset: Int, finished: Bool = false) {
        let bounded = min(source.length, max(0, offset))
        self.offset = bounded < source.length ? source.rangeOfComposedCharacterSequence(at: bounded).location : bounded
        textLength = source.length
        chapterIndex = ChapterParser.chapterIndex(at: self.offset, in: chapters) ?? 0
        chapterTitle = chapters.indices.contains(chapterIndex) ? chapters[chapterIndex].title : "全文"
        self.finished = finished
        if self.offset < source.length {
            let end = chapters.indices.contains(chapterIndex) ? NSMaxRange(chapters[chapterIndex].range) : source.length
            let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: self.offset, length: min(64, end - self.offset)))
            anchor = source.substring(with: range)
        } else { anchor = "" }
    }

    /// Recover only a unique anchor in the original chapter. Ambiguous matches fall back safely.
    public func restore(in text: String, chapters: [DocumentChapter], unchanged: Bool) -> (offset: Int, exact: Bool) {
        let source = text as NSString
        guard source.length > 0, !chapters.isEmpty else { return (0, false) }
        if unchanged {
            let bounded = min(source.length, max(0, offset))
            return (bounded < source.length ? source.rangeOfComposedCharacterSequence(at: bounded).location : bounded, true)
        }
        let titleMatches = chapters.filter { $0.title == chapterTitle }
        let chapter = titleMatches.count == 1 ? titleMatches[0] : chapters[min(chapters.count - 1, max(0, chapterIndex))]
        if titleMatches.count == 1, !anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let match = source.range(of: anchor, options: .literal, range: chapter.range)
            if match.location != NSNotFound {
                let nextStart = match.location + 1
                let next = source.range(of: anchor, options: .literal,
                    range: NSRange(location: nextStart, length: NSMaxRange(chapter.range) - nextStart))
                if next.location == NSNotFound { return (match.location, true) }
            }
        }
        return (chapter.range.location, false)
    }
}

public struct LibraryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var fileIdentity: String?
    public var contentDigest: String
    public var checkpoint: ReadingCheckpoint?
    public let addedAt: Date
    public var lastOpenedAt: Date
    public var lastReadAt: Date?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil,
                fileIdentity: String? = nil, contentDigest: String, now: Date = Date()) {
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark
        self.fileIdentity = fileIdentity; self.contentDigest = contentDigest
        addedAt = now; lastOpenedAt = now
    }

    public var progress: Double {
        guard let checkpoint, checkpoint.textLength > 0 else { return 0 }
        return min(1, max(0, Double(checkpoint.offset) / Double(checkpoint.textLength)))
    }
}

public struct ReadingLibrary: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var entries: [LibraryEntry] = []
    public var lastOpenedID: UUID?
    public init() {}

    public var sortedEntries: [LibraryEntry] {
        entries.sorted {
            let first = $0.lastReadAt ?? $0.lastOpenedAt, second = $1.lastReadAt ?? $1.lastOpenedAt
            return first == second ? $0.id.uuidString < $1.id.uuidString : first > second
        }
    }

    public func existingID(path: String, fileIdentity: String?) -> UUID? {
        entries.first { $0.path == path || (fileIdentity != nil && $0.fileIdentity == fileIdentity) }?.id
    }

    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if lastOpenedID == id { lastOpenedID = nil }
    }
}

public struct ReadingLibraryStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> ReadingLibrary {
        guard FileManager.default.fileExists(atPath: url.path) else { return ReadingLibrary() }
        let library = try JSONDecoder().decode(ReadingLibrary.self, from: Data(contentsOf: url))
        guard library.schemaVersion == 1, Set(library.entries.map(\.id)).count == library.entries.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return library
    }

    public func save(_ library: ReadingLibrary) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}
