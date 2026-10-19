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
        let gap = #"[\p{Zs}\t\x{200B}\x{200E}\x{200F}\x{2060}\x{FEFF}]*"#
        let number = #"[0-9０-９零〇一二三四五六七八九十百千万两壹贰叁肆伍陆柒捌玖拾佰仟]+"#
        let digit = String(number.dropLast())
        let chineseNumber = "\(digit)(?:\(gap)\(digit))*"
        let patterns = [
            "第\(gap)\(chineseNumber)\(gap)(?:[章回节卷篇]|部(?!分))[^\\r\\n]{0,100}",
            "(?:chapter|part|book)\(gap)(?:[0-9０-９]+|[IVXLCDM]+)(?=$|[ \\t:：.、\\-]|[^A-Za-z0-9])[^\\r\\n]{0,100}",
            "(?:序章|序言|前言|楔子|引子|尾声|终章|后记|番外(?:\(number))?)(?=$|[ \\t:：、\\-】\\]）)》」』])[^\\r\\n]{0,100}"
        ]
        let wrapperOpen = #"[【\[（(《「『]"#
        let wrapperClose = #"[】\]）)》」』]"#
        let prefix = "^\(gap)(?:#{1,6}[ \\t]+)?(?:\(wrapperOpen)\(gap))?(?:正文[ \\t　]+)?"
        let suffix = "(?:\(wrapperClose))?\(gap)$"
        let expression = try! NSRegularExpression(pattern: "\(prefix)(?:\(patterns.joined(separator: "|")))\(suffix)",
                                                  options: [.anchorsMatchLines, .caseInsensitive])
        let fullRange = NSRange(location: 0, length: source.length)
        var headings = expression.matches(in: text, range: fullRange).filter {
            // A numbered reference in a body sentence should not become a chapter.
            let title = source.substring(with: $0.range)
            guard title.contains("。"), normalizedTitle(title).hasPrefix("第") else { return true }
            // Preserve explicitly separated headings that the previous parser already supported.
            return title.range(of: "第\(gap)\(chineseNumber)\(gap)(?:[章回节卷篇]|部(?!分))[\\p{Zs}\\t:：]+",
                               options: .regularExpression) != nil
        }
        let weak = try! NSRegularExpression(
            pattern: "\(prefix)(\(number))[ \\t　.．、:：]+([^\\r\\n]{1,80})\(suffix)",
            options: .anchorsMatchLines)
        let numbered = weak.matches(in: text, range: fullRange).filter {
            let title = source.substring(with: $0.range(at: 2))
            return !title.contains("。") && title.first?.isNumber != true
        }
        // Bare numbers are accepted only as a consecutive sequence, not isolated lists/dates.
        if headings.isEmpty, numbered.count >= 2 {
            let values = numbered.map { numericValue(source.substring(with: $0.range(at: 1))) }
            var coherent: [NSTextCheckingResult] = []
            for index in numbered.indices {
                guard let value = values[index], value >= 0, value < 1_000_000 else { continue }
                let previous = index > 0 ? values[index - 1] : nil
                let next = index + 1 < values.count ? values[index + 1] : nil
                func hasBody(between first: Int, and second: Int) -> Bool {
                    let start = NSMaxRange(numbered[first].range)
                    let range = NSRange(location: start, length: numbered[second].range.location - start)
                    return !source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if (previous == value - 1 && hasBody(between: index - 1, and: index)) ||
                   (next == value + 1 && hasBody(between: index, and: index + 1)) { coherent.append(numbered[index]) }
            }
            headings += coherent
            headings.sort { $0.range.location < $1.range.location }
        }
        if headings.isEmpty {
            let markdown = try! NSRegularExpression(pattern: "^\(gap)#{1,6}[ \\t]+[^\\r\\n]{1,100}$", options: .anchorsMatchLines)
            headings = markdown.matches(in: text, range: fullRange)
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
            let title = normalizedTitle(source.substring(with: heading.range))
            let start = entries.isEmpty ? 0 : heading.range.location
            entries.append((title, start))
        }
        return entries.enumerated().map { index, entry in
            let end = index + 1 < entries.count ? entries[index + 1].start : source.length
            return DocumentChapter(id: index, title: entry.title, range: NSRange(location: entry.start, length: end - entry.start))
        }
    }

    private static func normalizedTitle(_ line: String) -> String {
        var title = String(line.unicodeScalars.filter { $0.properties.generalCategory != .format })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        title = title.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        for (open, close) in [("【", "】"), ("[", "]"), ("（", "）"), ("(", ")"), ("《", "》"), ("「", "」"), ("『", "』")] {
            if title.hasPrefix(open), title.hasSuffix(close) {
                title = String(title.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return title
    }

    private static func numericValue(_ text: String) -> Int? {
        let normalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        if let value = Int(normalized) { return value }
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "壹": 1, "二": 2, "贰": 2, "两": 2,
            "三": 3, "叁": 3, "四": 4, "肆": 4, "五": 5, "伍": 5, "六": 6, "陆": 6, "七": 7, "柒": 7,
            "八": 8, "捌": 8, "九": 9, "玖": 9]
        let units: [Character: Int] = ["十": 10, "拾": 10, "百": 100, "佰": 100, "千": 1000, "仟": 1000, "万": 10000]
        var total = 0, section = 0, digit = 0
        for character in normalized {
            if let number = digits[character] { digit = number }
            else if let unit = units[character] {
                if unit == 10000 { total += max(1, section + digit) * unit; section = 0 }
                else { section += max(1, digit) * unit }
                digit = 0
            }
            else { return nil }
        }
        return total + section + digit
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
