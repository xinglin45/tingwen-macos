import XCTest
import CoreFoundation
@testable import ReaderCore

final class TextDocumentTests: XCTestCase {
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
