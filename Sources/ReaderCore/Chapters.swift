import Foundation

public struct DocumentChapter: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let range: NSRange

    public func text(in document: String) -> String {
        (document as NSString).substring(with: range)
    }
}

public enum ChapterParser {
    public static func chapters(in text: String) -> [DocumentChapter] {
        let source = text as NSString
        guard source.length > 0 else { return [] }
        let number = "[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+"
        let patterns = [
            "第[ \\t　]*\(number)[ \\t　]*[章回节卷部篇](?:[ \\t　:：、.．\\-]+[^\\r\\n]{0,100})?",
            "(?:chapter|part|book)[ \\t]+(?:[0-9]+|[IVXLCDM]+)(?=$|[ \\t:：.、\\-])[^\\r\\n]{0,100}",
            "(?:序章|序言|前言|楔子|引子|尾声|终章|后记|番外(?:\(number))?)(?:[ \\t:：、\\-][^\\r\\n]{0,100})?"
        ]
        let expression = try! NSRegularExpression(
            pattern: "^[ \\t　]*(?:#{1,6}[ \\t]+)?(?:\(patterns.joined(separator: "|")))[ \\t　]*$",
            options: [.anchorsMatchLines, .caseInsensitive])
        var headings = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        if headings.isEmpty {
            let markdown = try! NSRegularExpression(pattern: "^[ \\t]*#{1,6}[ \\t]+[^\\r\\n]{1,100}$", options: .anchorsMatchLines)
            headings = markdown.matches(in: text, range: NSRange(location: 0, length: source.length))
        }
        guard let first = headings.first else {
            return [DocumentChapter(id: 0, title: "全文", range: NSRange(location: 0, length: source.length))]
        }
        var entries: [(title: String, start: Int)] = []
        let preamble = source.substring(to: first.range.location)
        if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(("作品信息 / 前言", 0))
        }
        for heading in headings {
            var title = source.substring(with: heading.range).trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            let start = entries.isEmpty ? 0 : heading.range.location
            entries.append((title, start))
        }
        return entries.enumerated().map { index, entry in
            let end = index + 1 < entries.count ? entries[index + 1].start : source.length
            return DocumentChapter(id: index, title: entry.title, range: NSRange(location: entry.start, length: end - entry.start))
        }
    }

    public static func chapterIndex(at offset: Int, in chapters: [DocumentChapter]) -> Int? {
        guard !chapters.isEmpty else { return nil }
        var lower = 0, upper = chapters.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if chapters[middle].range.location <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }
}

public struct ChapterSearchResult: Identifiable, Equatable, Sendable {
    public var id: Int { chapterID }
    public let chapterID: Int
    public let title: String
    /// Matches are absolute UTF-16 ranges in the complete document.
    public let matches: [NSRange]
    public let excerpt: String
}

public enum ChapterSearch {
    public static func results(for query: String, in text: String, chapters: [DocumentChapter],
                               isCancelled: () -> Bool = { false }) -> [ChapterSearchResult] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return [] }
        let source = text as NSString
        var results: [ChapterSearchResult] = []
        for chapter in chapters {
            if isCancelled() { return [] }
            var matches: [NSRange] = []
            var cursor = chapter.range.location
            let end = NSMaxRange(chapter.range)
            while cursor < end {
                if isCancelled() { return [] }
                let match = source.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive],
                                         range: NSRange(location: cursor, length: end - cursor))
                guard match.location != NSNotFound, match.length > 0 else { break }
                matches.append(match)
                cursor = NSMaxRange(match)
            }
            guard let first = matches.first else { continue }
            let start = max(chapter.range.location, first.location - 24)
            let snippetEnd = min(end, NSMaxRange(first) + 56)
            let snippetRange = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: snippetEnd - start))
            let excerpt = source.substring(with: snippetRange)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(ChapterSearchResult(chapterID: chapter.id, title: chapter.title, matches: matches, excerpt: excerpt))
        }
        return results
    }
}
