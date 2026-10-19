import Foundation
import CoreFoundation

public enum DocumentError: LocalizedError {
    case tooLarge, empty, unreadableEncoding, unsupported, noPDFText

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件超过 20 MB，请拆分后再打开。"
        case .empty: return "文件中没有可朗读的文字。"
        case .unreadableEncoding: return "无法识别文本编码，或文件不是有效文本。请尝试指定编码重新读取；有损转换造成的文字丢失无法自动恢复。"
        case .unsupported: return "暂不支持此文件。请选择 TXT、Markdown、RTF、HTML、DOCX、PDF 或其他纯文本文件。"
        case .noPDFText: return "这个 PDF 没有可提取的文字。扫描版 PDF 需要先进行文字识别。"
        }
    }
}

public enum TextEncoding: String, CaseIterable, Codable, Sendable, Identifiable {
    case automatic, utf8, gb18030, big5, utf16LE, utf16BE, utf32LE, utf32BE
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: return "自动识别"
        case .utf8: return "UTF-8"
        case .gb18030: return "GB18030 / GBK / GB2312"
        case .big5: return "Big5（繁体中文）"
        case .utf16LE: return "UTF-16 LE"
        case .utf16BE: return "UTF-16 BE"
        case .utf32LE: return "UTF-32 LE"
        case .utf32BE: return "UTF-32 BE"
        }
    }
    public var stringEncoding: String.Encoding? {
        switch self {
        case .automatic: return nil
        case .utf8: return .utf8
        case .gb18030: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .big5: return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case .utf16LE: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .utf32LE: return .utf32LittleEndian
        case .utf32BE: return .utf32BigEndian
        }
    }
}

public struct DecodedText: Sendable {
    public let text: String
    public let encoding: TextEncoding
    public var needsUTF8Conversion: Bool { encoding != .utf8 }
}

public enum TextDecoder {
    public static let maximumBytes = 20 * 1024 * 1024

    public static func decode(_ data: Data) throws -> String { try decodeDetected(data).text }

    public static func decodeDetected(_ data: Data, encoding requested: TextEncoding = .automatic) throws -> DecodedText {
        guard data.count <= maximumBytes else { throw DocumentError.tooLarge }
        guard !data.isEmpty else { throw DocumentError.empty }
        if requested != .automatic { return try decoded(data, encoding: requested) }
        let prefix = [UInt8](data.prefix(4))
        let bom: TextEncoding?
        if prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { bom = .utf32LE }
        else if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { bom = .utf32BE }
        else if prefix.starts(with: [0xFF, 0xFE]) { bom = .utf16LE }
        else if prefix.starts(with: [0xFE, 0xFF]) { bom = .utf16BE }
        else { bom = nil }
        if let bom { return try decoded(data, encoding: bom) }
        if prefix.starts(with: [0xEF, 0xBB, 0xBF]) { return try decoded(data, encoding: .utf8) }

        // NULs are usually binary data, except for structurally plausible UTF-16/32 text.
        if data.contains(0) {
            let sample = Array(data.prefix(8192))
            let unicodeCandidates: [TextEncoding] = [.utf32LE, .utf32BE, .utf16LE, .utf16BE]
            let candidates = unicodeCandidates.compactMap { encoding -> DecodedText? in
                let width = (encoding == .utf32LE || encoding == .utf32BE) ? 4 : 2
                guard data.count % width == 0, sample.count >= width * 2 else { return nil }
                if width == 4 {
                    let pairs = sample.count / 4
                    let zeros = (0..<pairs).filter { index in
                        let base = index * 4
                        return encoding == .utf32LE ? sample[base + 2] == 0 && sample[base + 3] == 0 : sample[base] == 0 && sample[base + 1] == 0
                    }.count
                    guard zeros * 10 >= pairs * 8 else { return nil }
                }
                guard let value = try? decoded(data, encoding: encoding), plausibleUnicodeText(value.text) else { return nil }
                return value
            }
            if let best = candidates.max(by: { quality($0.text) < quality($1.text) }) { return best }
            throw DocumentError.unreadableEncoding
        }
        if String(data: data, encoding: .utf8) != nil { return try decoded(data, encoding: .utf8) }

        let candidates = [TextEncoding.gb18030, .big5].compactMap { encoding -> DecodedText? in
            guard let value = try? decoded(data, encoding: encoding),
                  String(data: data, encoding: encoding.stringEncoding!)?.data(using: encoding.stringEncoding!) == data else { return nil }
            return value
        }
        guard var best = candidates.first else { throw DocumentError.unreadableEncoding }
        // Preserve the GB family preference on close scores; Big5 often decodes as PUA-heavy GB text.
        for candidate in candidates.dropFirst() where quality(candidate.text) > quality(best.text) + 0.15 { best = candidate }
        return best
    }

    private static func decoded(_ data: Data, encoding: TextEncoding) throws -> DecodedText {
        guard let value = encoding.stringEncoding, let text = String(data: data, encoding: value) else {
            throw DocumentError.unreadableEncoding
        }
        return DecodedText(text: try cleaned(text), encoding: encoding)
    }

    private static let commonChinese = Set("的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政日社义事平形相全表间样与关各重新内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无军很情者最立代想已通并提直题程展五果料象员位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计她手角期根论运农指几九区强放决西被干做必战先回则任取据处理世车神病听阴脉先生章卷回节篇第一简体繁體這為與說來時個們裡後發開過國學無會書讀見歡萬還經對從頭愛東聲長實現點動當讓進難隻種應樣幾問題師術歲".unicodeScalars)

    private static func quality(_ text: String) -> Double {
        let scalars = Array(text.unicodeScalars.prefix(16384))
        guard !scalars.isEmpty else { return -100 }
        var score = 0.0
        for scalar in scalars {
            if commonChinese.contains(scalar) { score += 2 }
            else if scalar.value < 128 { score += scalar == "\n" ? 1 : 0.1 }
            switch scalar.properties.generalCategory {
            case .privateUse, .unassigned: score -= 5
            default: break
            }
        }
        return score / Double(scalars.count)
    }

    private static func plausibleUnicodeText(_ text: String) -> Bool {
        let sample = Array(text.unicodeScalars.prefix(8192))
        guard !sample.isEmpty, !sample.contains(where: { $0.properties.generalCategory == .unassigned || $0.properties.generalCategory == .privateUse }) else { return false }
        let readable = sample.filter { scalar in
            scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar.properties.isWhitespace ||
                scalar.properties.generalCategory == .otherSymbol || scalar.properties.generalCategory == .otherPunctuation
        }.count
        return readable * 10 >= sample.count * 8
    }

    public static func cleaned(_ input: String) throws -> String {
        let text = input.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError.empty }
        let hasInvalidControl = text.unicodeScalars.contains {
            ($0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t") || $0.value == 0xFFFE || $0.value == 0xFFFF
        }
        guard !hasInvalidControl else { throw DocumentError.unreadableEncoding }
        return text
    }
}

public struct SpeechSegment: Equatable, Sendable {
    public let text: String
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

/// Ranges use UTF-16, matching AVSpeechSynthesizer and NSTextView.
/// Every segment preserves the source verbatim, including emoji and whitespace.
public enum SpeechSegmenter {
    public static func segments(in text: String, from requestedOffset: Int = 0, limit: Int = 600) -> [SpeechSegment] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        var offset = max(0, min(requestedOffset, source.length))
        if offset < source.length {
            offset = source.rangeOfComposedCharacterSequence(at: offset).location
        }
        var result: [SpeechSegment] = []
        let target = max(16, limit)
        let boundaries = CharacterSet(charactersIn: "。！？；.!?;\n")
        while offset < source.length {
            var end = min(offset + target, source.length)
            if end < source.length {
                let search = NSRange(location: offset + target / 2, length: end - offset - target / 2)
                let boundary = source.rangeOfCharacter(from: boundaries, options: .backwards, range: search)
                if boundary.location != NSNotFound {
                    end = NSMaxRange(boundary)
                } else {
                    let composed = source.rangeOfComposedCharacterSequence(at: end)
                    end = composed.location > offset ? composed.location : NSMaxRange(composed)
                }
            }
            let range = NSRange(location: offset, length: end - offset)
            result.append(SpeechSegment(text: source.substring(with: range), range: range))
            offset = end
        }
        return result
    }
}
