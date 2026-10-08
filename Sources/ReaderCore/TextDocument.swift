import Foundation
import CoreFoundation

public enum DocumentError: LocalizedError {
    case tooLarge, empty, unreadableEncoding, unsupported, noPDFText

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "文件超过 20 MB，请拆分后再打开。"
        case .empty: return "文件中没有可朗读的文字。"
        case .unreadableEncoding: return "无法识别文本编码，或文件不是文本。请另存为 UTF-8 后重试。"
        case .unsupported: return "暂不支持此文件。请选择 TXT、Markdown、RTF、HTML、DOCX、PDF 或其他纯文本文件。"
        case .noPDFText: return "这个 PDF 没有可提取的文字。扫描版 PDF 需要先进行文字识别。"
        }
    }
}

public enum TextDecoder {
    public static let maximumBytes = 20 * 1024 * 1024

    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumBytes else { throw DocumentError.tooLarge }
        let bytes = [UInt8](data.prefix(4))
        let encoding: String.Encoding?
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { encoding = .utf32LittleEndian }
        else if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { encoding = .utf32BigEndian }
        else if bytes.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian }
        else if bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian }
        else { encoding = nil }

        var text: String?
        if let encoding { text = String(data: data, encoding: encoding) }
        else if !data.contains(0) {
            text = String(data: data, encoding: .utf8)
            if text == nil {
                let gb18030 = String.Encoding(rawValue:
                    CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                text = String(data: data, encoding: gb18030)
            }
        }
        guard let text else { throw DocumentError.unreadableEncoding }
        return try cleaned(text)
    }

    public static func cleaned(_ input: String) throws -> String {
        let text = input.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DocumentError.empty }
        // CharacterSet.controlCharacters also contains Unicode format characters
        // (Cf), including direction marks and emoji joiners. Those are valid text.
        let hasInvalidControl = text.unicodeScalars.contains {
            $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t"
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
