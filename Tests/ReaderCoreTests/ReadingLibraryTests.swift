import XCTest
@testable import ReaderCore

final class ReadingLibraryTests: XCTestCase {
    func testCheckpointKeepsUnicodeBoundariesAndFinishedPosition() {
        let text = "第1章 测试\n你好👨‍👩‍👧‍👦世界。"
        let chapters = ChapterParser.chapters(in: text)
        let emoji = (text as NSString).range(of: "👨‍👩‍👧‍👦")
        let checkpoint = ReadingCheckpoint(text: text, chapters: chapters, offset: emoji.location + 3)
        XCTAssertEqual(checkpoint.offset, emoji.location)
        XCTAssertEqual(checkpoint.restore(in: text, chapters: chapters, unchanged: true).offset, emoji.location)
        let finished = ReadingCheckpoint(text: text, chapters: chapters, offset: Int.max, finished: true)
        XCTAssertEqual(finished.offset, (text as NSString).length)
        XCTAssertTrue(finished.finished)
        XCTAssertEqual(ReadingCheckpoint(text: "", chapters: [], offset: -20).offset, 0)
    }

    func testChangedFileRestoresAnchorInsteadOfOldAbsoluteOffset() {
        let text = "第1章 开始\n开头。\n第2章 续读\n这是上次正在播放的内容🌙。这段内容具有唯一性。"
        let offset = (text as NSString).range(of: "正在播放").location
        let checkpoint = ReadingCheckpoint(text: text, chapters: ChapterParser.chapters(in: text), offset: offset)
        let changed = "前言：新增的内容。\n" + text.replacingOccurrences(of: "这是上次", with: "额外插入的句子。这是上次")
        let restored = checkpoint.restore(in: changed, chapters: ChapterParser.chapters(in: changed), unchanged: false)
        XCTAssertTrue(restored.exact)
        XCTAssertEqual(restored.offset, (changed as NSString).range(of: "正在播放").location)
    }

    func testMissingAndAmbiguousAnchorsFallBackToChapterStart() {
        let text = "第1章 开始\n甲。\n第2章 续读\n" + String(repeating: "a", count: 70)
        let chapters = ChapterParser.chapters(in: text)
        let checkpoint = ReadingCheckpoint(text: text, chapters: chapters, offset: (text as NSString).range(of: "a").location)
        let repeated = checkpoint.restore(in: text, chapters: chapters, unchanged: false)
        XCTAssertFalse(repeated.exact)
        XCTAssertEqual(repeated.offset, chapters[1].range.location)
        let changed = "第1章 开始\n甲。\n第2章 续读\n完全不同的文字。"
        let result = checkpoint.restore(in: changed, chapters: ChapterParser.chapters(in: changed), unchanged: false)
        XCTAssertFalse(result.exact)
        XCTAssertEqual(result.offset, ChapterParser.chapters(in: changed)[1].range.location)
    }

    func testLibraryRoundTripIndependentProgressAndRemoval() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ReadingLibraryStore(url: folder.appendingPathComponent("nested/library.json"))
        XCTAssertTrue(try store.load().entries.isEmpty)
        let text = "第1章 开始\n你好，这是保存阅读进度的测试。"
        var first = LibraryEntry(name: "a.txt", path: "/test/a.txt", bookmark: Data([1, 2]), fileIdentity: "1:2", contentDigest: "a")
        first.checkpoint = ReadingCheckpoint(text: text, chapters: ChapterParser.chapters(in: text), offset: 9)
        first.lastReadAt = Date(timeIntervalSince1970: 100)
        var second = LibraryEntry(name: "b.txt", path: "/test/b.txt", fileIdentity: "1:3", contentDigest: "b")
        second.checkpoint = ReadingCheckpoint(text: text, chapters: ChapterParser.chapters(in: text), offset: 15)
        second.lastReadAt = Date(timeIntervalSince1970: 200)
        var library = ReadingLibrary()
        library.entries = [first, second]; library.lastOpenedID = first.id
        try store.save(library)
        XCTAssertEqual(try ReadingLibraryStore(url: store.url).load(), library)
        XCTAssertEqual(library.sortedEntries.map(\.id), [second.id, first.id])
        XCTAssertEqual(library.existingID(path: "/new/location.txt", fileIdentity: "1:2"), first.id)
        XCTAssertEqual(library.existingID(path: first.path, fileIdentity: nil), first.id)
        library.remove(first.id)
        try store.save(library)
        XCTAssertNil(try store.load().lastOpenedID)
        XCTAssertEqual(try store.load().entries.map(\.id), [second.id])
        try store.save(ReadingLibrary())
        XCTAssertTrue(try store.load().entries.isEmpty)
    }

    func testCorruptOrFutureLibraryIsRejectedWithoutChangingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let invalid = Data("not valid JSON".utf8)
        try invalid.write(to: url)
        let store = ReadingLibraryStore(url: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        var future = ReadingLibrary(); future.schemaVersion = 99
        try store.save(future)
        XCTAssertThrowsError(try store.load())
    }
}
