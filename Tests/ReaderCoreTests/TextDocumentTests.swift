import XCTest
import CoreFoundation
@testable import ReaderCore

final class TextDocumentTests: XCTestCase {
    func testDetectedLegacyEncodingAndWindowsLineEndings() throws {
        let text = "第一章拍花造畜\r\n我是个江湖术士，号称阴脉先生。\r\n第二章阴沟里翻船\r\n中文文本。"
        let data = try XCTUnwrap(text.data(using: TextEncoding.gb18030.stringEncoding!))
        let decoded = try TextDecoder.decodeDetected(data)
        XCTAssertEqual(decoded.encoding, .gb18030)
        XCTAssertTrue(decoded.needsUTF8Conversion)
        XCTAssertEqual(decoded.text, text.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertEqual(ChapterParser.chapters(in: decoded.text).count, 2)
    }

    func testBig5IsNotMisreadAsGB18030() throws {
        let text = "第一章花開月圓\n這是繁體中文小說，歡迎閱讀。\n第二章繼續閱讀\n中文文字。"
        let data = try XCTUnwrap(text.data(using: TextEncoding.big5.stringEncoding!))
        let decoded = try TextDecoder.decodeDetected(data)
        XCTAssertEqual(decoded.encoding, .big5)
        XCTAssertEqual(decoded.text, text)
        XCTAssertEqual(try TextDecoder.decodeDetected(data, encoding: .big5).text, text)
    }

    func testUnicodeWithoutBOMAndManualOverride() throws {
        let text = "第一章中文\nHello 你好🌙。"
        for encoding in [TextEncoding.utf16LE, .utf16BE, .utf32LE, .utf32BE] {
            let data = try XCTUnwrap(text.data(using: encoding.stringEncoding!))
            XCTAssertEqual(try TextDecoder.decodeDetected(data).text, text)
            XCTAssertEqual(try TextDecoder.decodeDetected(data, encoding: encoding).encoding, encoding)
        }
        let chineseOnly = "中文文字"
        let data = try XCTUnwrap(chineseOnly.data(using: .utf16LittleEndian))
        XCTAssertEqual(try TextDecoder.decodeDetected(data, encoding: .utf16LE).text, chineseOnly)
    }

    func testInvalidDeclaredEncodingIsRejectedInsteadOfLossyReplacement() {
        XCTAssertThrowsError(try TextDecoder.decodeDetected(Data([0xEF, 0xBB, 0xBF, 0xFF])))
        XCTAssertThrowsError(try TextDecoder.decodeDetected(Data([0xFF]), encoding: .utf8))
        XCTAssertThrowsError(try TextDecoder.decodeDetected(Data([0xFF, 0xFE, 0x41])))
        XCTAssertThrowsError(try TextDecoder.decodeDetected(Data([0, 1, 2, 3])))
    }

    func testUTF8AndLineEndings() throws {
        let data = Data("\u{FEFF}你好\r\n世界\rHello 🌙".utf8)
        XCTAssertEqual(try TextDecoder.decode(data), "你好\n世界\nHello 🌙")
    }

    func testUTF16AndUTF32BOM() throws {
        for encoding in [String.Encoding.utf16, .utf32] {
            XCTAssertEqual(try TextDecoder.decode("月光与文字 🌙".data(using: encoding)!), "月光与文字 🌙")
        }
    }

    func testGB18030() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        XCTAssertEqual(try TextDecoder.decode("这是一篇中文文章。".data(using: encoding)!), "这是一篇中文文章。")
    }

    func testUTF8FormatCharactersAndJoinedEmojiArePreserved() throws {
        // Copy-pasted books can contain zero-width and directionality marks.
        // Foundation's controlCharacters includes these valid Unicode format scalars.
        let text = "章节\u{200E}\n中文\u{200C}文本\u{200D}。\u{2060}\u{00AD}\n\u{2066}Hello\u{2069} 👨‍👩‍👧‍👦"
        XCTAssertEqual(try TextDecoder.decode(Data(text.utf8)), text)
    }

    func testGB18030FormatCharactersArePreserved() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let text = "章节\u{200E}\n中文\u{200C}文本。"
        XCTAssertEqual(try TextDecoder.decode(XCTUnwrap(text.data(using: encoding))), text)
    }

    func testRejectsEmptyBinaryAndOversizedFiles() {
        for data in [Data(), Data(" \n\t".utf8), Data([0, 1, 2, 3]), Data([65, 1, 66]), Data(repeating: 65, count: TextDecoder.maximumBytes + 1)] {
            XCTAssertThrowsError(try TextDecoder.decode(data))
        }
    }

    func testSegmentsPreserveOriginalAndUTF16Ranges() {
        let text = String(repeating: "这是一段文字🌙。Hello, world! 👨‍👩‍👧‍👦 你好。\n", count: 100)
        let segments = SpeechSegmenter.segments(in: text, limit: 60)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        var offset = 0
        for segment in segments {
            XCTAssertEqual(segment.range.location, offset)
            XCTAssertEqual(segment.range.length, (segment.text as NSString).length)
            XCTAssertNotNil(Range(segment.range, in: text))
            offset = NSMaxRange(segment.range)
        }
        XCTAssertEqual(offset, (text as NSString).length)
    }

    func testLongTextWithoutPunctuation() {
        let text = String(repeating: "a👨‍👩‍👧‍👦b🌙", count: 1000)
        let segments = SpeechSegmenter.segments(in: text, limit: 17)
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertTrue(segments.allSatisfy { !$0.text.contains("�") && Range($0.range, in: text) != nil })
    }

    func testSeekInsideEmojiAndBounds() {
        let text = "你好🌙，继续朗读。"
        XCTAssertEqual(SpeechSegmenter.segments(in: text, from: 3).first?.range.location, 2)
        XCTAssertEqual(SpeechSegmenter.segments(in: text, from: -10).map(\.text).joined(), text)
        XCTAssertTrue(SpeechSegmenter.segments(in: text, from: 1000).isEmpty)
        XCTAssertTrue(SpeechSegmenter.segments(in: "").isEmpty)
    }

    func testHTMLKeepsReadableStructureAndSkipsCode() throws {
        let html = "<html><head><title>标题不朗读</title><style>body{color:red}</style></head><body><h1>你好</h1><p>第一段 &amp; 第二段<br>换行</p><script>alert('不朗读')</script><img src='https://example.invalid/image.png'><p>结束🌙</p></body></html>"
        let result = try HTMLTextExtractor.extract(Data(html.utf8))
        XCTAssertTrue(result.contains("你好\n第一段 & 第二段\n换行\n结束🌙"))
        XCTAssertFalse(result.contains("不朗读"))
        XCTAssertFalse(result.contains("alert"))
    }
}
