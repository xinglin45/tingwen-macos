import XCTest
@testable import ReaderCore

final class ChapterTests: XCTestCase {
    func testChineseChaptersPreservePreambleAndFullDocument() {
        let text = "作品介绍🌙\n\n第1章 开始\n第一章正文。\n第 二 章 继续\n第二章正文。\n第３章 结束\n完。"
        let chapters = ChapterParser.chapters(in: text)
        XCTAssertEqual(chapters.map(\.title), ["作品信息 / 前言", "第1章 开始", "第 二 章 继续", "第３章 结束"])
        XCTAssertEqual(chapters.map { $0.text(in: text) }.joined(), text)
        XCTAssertEqual(chapters.map(\.id), Array(0..<4))
        for chapter in chapters {
            XCTAssertEqual(ChapterParser.chapterIndex(at: chapter.range.location, in: chapters), chapter.id)
            XCTAssertEqual(ChapterParser.chapterIndex(at: NSMaxRange(chapter.range) - 1, in: chapters), chapter.id)
            XCTAssertNotNil(Range(chapter.range, in: text))
        }
        XCTAssertEqual(ChapterParser.chapterIndex(at: (text as NSString).length, in: chapters), 3)
    }

    func testWhitespaceEnglishSpecialSectionsAndMarkdownFallback() {
        let text = "\n \n序章\n开场。\nChapter I: Start\nHello.\nCHAPTER 2 End\nBye.\n尾声\n结束。"
        let chapters = ChapterParser.chapters(in: text)
        XCTAssertEqual(chapters.map(\.title), ["序章", "Chapter I: Start", "CHAPTER 2 End", "尾声"])
        XCTAssertEqual(chapters.map { $0.text(in: text) }.joined(), text)
        let markdown = "# Overview\nText.\n## Details\nMore."
        XCTAssertEqual(ChapterParser.chapters(in: markdown).map(\.title), ["Overview", "Details"])
        let book = "# 第1章 开始\n## 章节内的小标题\n正文。\n# 第2章 继续\n正文。"
        XCTAssertEqual(ChapterParser.chapters(in: book).map(\.title), ["第1章 开始", "第2章 继续"])
    }

    func testNoHeadingsAndEmptyInput() {
        let text = "普通文章。提到了第1章，但不是独立标题。\n第二个人说话了。"
        let chapters = ChapterParser.chapters(in: text)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters.first?.title, "全文")
        XCTAssertEqual(chapters.first?.text(in: text), text)
        XCTAssertTrue(ChapterParser.chapters(in: "").isEmpty)
        XCTAssertNil(ChapterParser.chapterIndex(at: 0, in: []))
    }

    func testSearchGroupsMatchesByChapterAndPreservesUTF16Offsets() {
        let text = "第1章 🌙开始\n多半是这样，多半没错。\n第2章 继续\n这里没有。\n第3章 结束\n👨‍👩‍👧‍👦多半如此。"
        let chapters = ChapterParser.chapters(in: text)
        let results = ChapterSearch.results(for: "多半", in: text, chapters: chapters)
        XCTAssertEqual(results.map(\.chapterID), [0, 2])
        XCTAssertEqual(results.map { $0.matches.count }, [2, 1])
        for result in results {
            XCTAssertTrue(result.excerpt.contains("多半"))
            XCTAssertFalse(result.excerpt.contains("�"))
            for range in result.matches {
                XCTAssertEqual((text as NSString).substring(with: range), "多半")
                XCTAssertNotNil(Range(range, in: text))
                XCTAssertEqual(ChapterParser.chapterIndex(at: range.location, in: chapters), result.chapterID)
            }
        }
    }

    func testSearchIsLiteralCaseInsensitiveAndCancellable() {
        let text = "第1章 测试\nHello hello [a.b] Café cafe\u{301}。\n第2章 测试\n结束。"
        let chapters = ChapterParser.chapters(in: text)
        XCTAssertEqual(ChapterSearch.results(for: "HELLO", in: text, chapters: chapters).first?.matches.count, 2)
        XCTAssertEqual(ChapterSearch.results(for: "[a.b]", in: text, chapters: chapters).first?.matches.count, 1)
        XCTAssertEqual(ChapterSearch.results(for: "cafe", in: text, chapters: chapters).first?.matches.count, 2)
        XCTAssertTrue(ChapterSearch.results(for: "   ", in: text, chapters: chapters).isEmpty)
        XCTAssertTrue(ChapterSearch.results(for: "不存在", in: text, chapters: chapters).isEmpty)
        XCTAssertTrue(ChapterSearch.results(for: "hello", in: text, chapters: chapters, isCancelled: { true }).isEmpty)
    }
}
