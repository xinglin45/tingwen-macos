import AppKit
import AVFoundation
import Carbon
import CoreText
import ReaderCore

/// Opt-in integration checks, run inside the real app bundle: ListenText --verify /path/report.json
@MainActor
enum AppVerification {
    static func run(model: ReaderModel, reportURL: URL, bookURL: URL? = nil) async {
        var checks: [[String: Any]] = []
        let savedRate = model.rate
        let savedVolume = model.volume
        let savedVoice = model.selectedVoiceID
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ListenText-Verification-\(UUID().uuidString)")
        func record(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(["name": name, "passed": passed, "detail": detail])
        }
        func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 12) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return condition()
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            model.rate = 0.5
            model.volume = 0
            model.selectedVoiceID = ""
            await model.refreshVoices()
            record("installed-system-voice", model.systemVoiceID != nil, model.systemVoiceID ?? "none")
            record("global-shortcut-registration", model.shortcutAvailable, model.shortcut.display)

            let normalized = ["黎潋（高音质）", "Lilian (Premium)", "Ava (Enhanced)", "月（高音质）（高音质）", "声音2", "瀚（优化音质）"]
                .map(VoiceCatalog.normalizedName)
            record("localized-voice-quality-labels", normalized == ["黎潋", "Lilian", "Ava", "月", "声音2", "瀚"])
            let recommended = VoiceCatalog.recommendations
            record("four-recommended-voice-categories", recommended.count == 4 && Set(recommended.map(\.id)).count == 4)
            let suite = "ListenText-FavoriteVerification-\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: suite) {
                defer { defaults.removePersistentDomain(forName: suite) }
                let store = VoiceFavoritesStore(defaults: defaults)
                let first = recommended[0].voice, second = recommended[1].voice
                let added = store.toggle(first)
                let reloaded = VoiceFavoritesStore(defaults: defaults).load()
                record("favorite-persists-on-reload", added == [first] && reloaded == added)
                let both = store.toggle(second)
                record("favorite-keeps-uninstalled-voice-metadata", both == [first, second] && store.load().last?.label == second.label)
                let removed = store.toggle(first)
                record("favorite-removes-only-target", removed == [second] && store.load() == [second])
                store.save([second, second])
                record("favorite-deduplicates-identifiers", store.load() == [second])
            } else { record("favorites-storage", false, "Cannot create isolated defaults") }
            let previousFavorites = model.favoriteVoices
            let sample = VoiceChoice(id: "verification-\(UUID().uuidString)", name: "收藏验证", language: "zh-CN", quality: "")
            let wasFavorite = model.isVoiceFavorite(sample.id)
            model.toggleVoiceFavorite(sample)
            let changed = model.isVoiceFavorite(sample.id) != wasFavorite
            model.toggleVoiceFavorite(sample)
            record("favorite-model-add-remove", changed && model.favoriteVoices == previousFavorites)
            if let missing = recommended.map(\.voice).first(where: { !model.isVoiceInstalled($0.id) }) {
                let previous = model.selectedVoiceID
                model.selectVoice(missing)
                record("uninstalled-voice-cannot-be-selected", model.selectedVoiceID == previous)
            }
            if let available = model.voices.first {
                model.selectVoice(available)
                record("installed-voice-selection", model.selectedVoiceID == available.id)
                model.selectedVoiceID = ""
            }

            let documentText = "这是中文文档。Hello reader. 🌙"
            for (ext, type) in [("rtf", NSAttributedString.DocumentType.rtf), ("docx", .officeOpenXML)] {
                let document = NSAttributedString(string: documentText)
                let data = try document.data(from: NSRange(location: 0, length: document.length), documentAttributes: [.documentType: type])
                let url = folder.appendingPathComponent("document.\(ext)")
                try data.write(to: url)
                let extracted = try await DocumentImporter.load(url)
                record("import-\(ext)", extracted.contains(documentText), extracted)
            }
            let htmlURL = folder.appendingPathComponent("document.html")
            try Data("<html><body><h1>中文标题</h1><p>你好 &amp; Hello 🌙</p><script>隐藏代码</script></body></html>".utf8).write(to: htmlURL)
            let htmlText = try await DocumentImporter.load(htmlURL)
            record("import-html", htmlText.contains("中文标题") && htmlText.contains("你好 & Hello 🌙") && !htmlText.contains("隐藏代码"), htmlText)

            let pdfURL = folder.appendingPathComponent("document.pdf")
            var rect = CGRect(x: 0, y: 0, width: 400, height: 200)
            if let context = CGContext(pdfURL as CFURL, mediaBox: &rect, nil) {
                context.beginPDFPage(nil)
                context.textPosition = CGPoint(x: 25, y: 100)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello reader PDF", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
                CTLineDraw(line, context)
                context.endPDFPage()
                context.closePDF()
                let extracted = try await DocumentImporter.load(pdfURL)
                record("import-pdf", extracted.contains("Hello reader PDF"), extracted)
            } else { record("import-pdf", false, "Cannot create fixture") }

            let url = folder.appendingPathComponent("speech.txt")
            try String(repeating: "这是一段用于验证的文字。我们检查暂停以后能否继续朗读，并且让进度正确前进。\n", count: 8).write(to: url, atomically: true, encoding: .utf8)
            await model.load(url)
            record("import-txt", model.hasText && model.errorMessage == nil)
            model.togglePlayback()
            let started = await waitFor({ model.position > 5 && model.state == .playing })
            record("speech-callbacks-and-progress", started, "position=\(model.position), state=\(model.state.rawValue), error=\(model.errorMessage ?? "none")")
            model.togglePlayback()
            try? await Task.sleep(for: .milliseconds(400))
            let pausedPosition = model.position
            try? await Task.sleep(for: .milliseconds(1200))
            record("pause-preserves-position", model.state == .paused && model.position == pausedPosition, "position=\(model.position)")
            record("pause-saves-library-speech-checkpoint", model.libraryEntries.first { $0.id == model.currentLibraryID }?.checkpoint?.offset == pausedPosition)
            model.togglePlayback()
            let resumed = await waitFor({ model.position > pausedPosition && model.state == .playing })
            record("resume-continues", resumed, "position=\(model.position)")
            model.seek(to: 0.5)
            let seekWorked = await waitFor({ model.progress >= 0.5 && model.state == .playing })
            record("seek-during-playback", seekWorked, "progress=\(model.progress)")
            model.stop()
            let stoppedPosition = model.position
            try? await Task.sleep(for: .milliseconds(500))
            record("stop-ignores-stale-callbacks", model.state == .ready && model.position == stoppedPosition)
            model.restart()
            record("restart-resets-position", model.position == 0 && model.state == .ready)

            // Exercise the registered Carbon handler without posting keys to other apps.
            var event: EventRef?
            let status = CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeUserEvent), &event)
            if status == noErr, let event {
                var id = EventHotKeyID(signature: 0x4C535458, id: 1)
                SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
                SendEventToEventTarget(event, GetEventDispatcherTarget())
                ReleaseEvent(event)
                let delivered = await waitFor({ model.state == .playing }, seconds: 2)
                record("global-shortcut-handler", delivered)
                model.stop()
            } else { record("global-shortcut-handler", false, "Cannot create Carbon event") }

            try "完成。".write(to: url, atomically: true, encoding: .utf8)
            await model.load(url)
            model.togglePlayback()
            let completed = await waitFor({ model.state == .finished }, seconds: 12)
            record("natural-completion", completed && model.progress == 1, "progress=\(model.progress)")

            try "第1章 开始\n甲。\n第2章 继续\n乙。".write(to: url, atomically: true, encoding: .utf8)
            await model.load(url)
            record("chapter-detection", model.chapters.count == 2 && model.selectedChapterID == 0)
            model.selectChapter(1)
            record("chapter-only-display", model.displayedText.contains("乙") && !model.displayedText.contains("甲"))
            model.seekInChapter(to: 0.5)
            record("chapter-relative-seek", abs(model.chapterProgress - 0.5) < 0.1 && model.selectedChapterID == 1)
            model.selectChapter(0)
            model.togglePlayback()
            let nextChapter = await waitFor({ model.selectedChapterID == 1 && model.state == .playing })
            record("automatic-next-chapter", nextChapter && model.displayedText.contains("乙"))
            let bookFinished = await waitFor({ model.state == .finished })
            record("finish-after-last-chapter", bookFinished && model.progress == 1)
            model.searchQuery = "乙"
            let found = await waitFor({ !model.isSearching && !model.searchResults.isEmpty })
            if found, let result = model.searchResults.first {
                model.showSearchResult(result)
                let highlighted = model.searchHighlights.first.map { (model.displayedText as NSString).substring(with: $0) }
                record("search-opens-matching-chapter", model.selectedChapterID == 1 && model.focusRequest != nil && model.state == .ready)
                record("search-highlights-correct-text", highlighted == "乙" && model.position == result.matches.first?.location)
            } else { record("chapter-search", false, "No results") }
            model.searchQuery = "甲"
            model.searchQuery = "不存在的关键词"
            let noStaleResults = await waitFor({ !model.isSearching && model.searchResults.isEmpty })
            record("search-cancels-stale-results", noStaleResults && model.searchHighlights.isEmpty)
            model.searchQuery = ""
            record("clear-search-removes-highlights", model.searchHighlights.isEmpty && model.searchResults.isEmpty)

            if let bookURL {
                await model.load(bookURL)
                record("real-book-import-and-chapters", model.errorMessage == nil && model.chapters.count > 1,
                       "chapters=\(model.chapters.count), characters=\(model.characterCount)")
                model.searchQuery = "多半"
                let bookSearch = await waitFor({ !model.isSearching && !model.searchResults.isEmpty }, seconds: 20)
                record("real-book-full-text-search", bookSearch,
                       "matchingChapters=\(model.searchResults.count), matches=\(model.searchMatchCount)")
                if let result = model.searchResults.first {
                    model.showSearchResult(result)
                    let valid = model.searchHighlights.allSatisfy { (model.displayedText as NSString).substring(with: $0) == "多半" }
                    record("real-book-result-navigation-and-highlights", model.selectedChapterID == result.chapterID && valid && !model.searchHighlights.isEmpty)
                }
            }
            try await verifyLibrary(folder: folder, record: record)
        } catch { record("unexpected-error", false, error.localizedDescription) }
        model.stop()
        model.rate = savedRate
        model.volume = savedVolume
        model.selectedVoiceID = savedVoice
        try? FileManager.default.removeItem(at: folder)
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "passed": checks.allSatisfy { $0["passed"] as? Bool == true },
            "checks": checks
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: reportURL, options: .atomic)
        }
        NSApp.terminate(nil)
    }

    private static func verifyLibrary(folder: URL, record: (String, Bool, String) -> Void) async throws {
        let libraryURL = folder.appendingPathComponent("library-test/state.json")
        let store = ReadingLibraryStore(url: libraryURL)
        let firstURL = folder.appendingPathComponent("第一本.txt")
        let secondURL = folder.appendingPathComponent("第二本.txt")
        let invalidURL = folder.appendingPathComponent("不支持.bin")
        let content = "第1章 起点\n这是第一章的文字。\n第2章 续读\n上次播放的位置应该正确恢复🌙。" +
            (1...12).map { "第\($0)段续读检查内容。" }.joined()
        try content.write(to: firstURL, atomically: true, encoding: .utf8)
        try "另一本文本，应该拥有独立的进度。".write(to: secondURL, atomically: true, encoding: .utf8)
        try Data([0, 1, 2]).write(to: invalidURL)
        let reader = ReaderModel(libraryURL: libraryURL, registerShortcut: false)
        await reader.addFiles([firstURL, invalidURL, secondURL])
        record("library-multiple-import-and-failed-file-exclusion", reader.libraryEntries.count == 2 && reader.currentLibraryID != nil && reader.state == .ready, "")
        reader.errorMessage = nil
        guard let firstID = reader.libraryEntries.first(where: { $0.path == firstURL.path })?.id,
              let secondID = reader.libraryEntries.first(where: { $0.path == secondURL.path })?.id else {
            record("library-fixtures", false, "Missing entries"); return
        }
        reader.selectChapter(1)
        reader.seekInChapter(to: 0.42)
        let savedPosition = reader.position
        reader.selectChapter(0)
        reader.searchQuery = "这是"
        try? await Task.sleep(for: .milliseconds(500))
        if let result = reader.searchResults.first { reader.showSearchResult(result) }
        reader.stop()
        record("library-browsing-does-not-overwrite-playback", try store.load().entries.first { $0.id == firstID }?.checkpoint?.offset == savedPosition, "")

        let reopened = ReaderModel(libraryURL: libraryURL, registerShortcut: false)
        await reopened.restoreLastDocument()
        record("library-relaunch-restores-file-chapter-position-without-speaking",
               reopened.currentLibraryID == firstID && reopened.selectedChapterID == 1 && reopened.position == savedPosition &&
               reopened.state == .ready && reopened.focusRequest != nil && reopened.localResumeRange.length > 0, "position=\(reopened.position)")
        await reopened.openLibraryEntry(secondID)
        reopened.seek(to: 0.3)
        let secondPosition = reopened.position
        await reopened.openLibraryEntry(firstID)
        let independentSnapshot = try store.load()
        record("library-independent-file-progress", reopened.position == savedPosition &&
               independentSnapshot.entries.first { $0.id == secondID }?.checkpoint?.offset == secondPosition, "")
        await reopened.addFiles([firstURL])
        record("library-deduplicates-and-retains-progress", reopened.libraryEntries.count == 2 && reopened.position == savedPosition, "")

        let movedURL = folder.appendingPathComponent("重命名后的第一本.txt")
        try FileManager.default.moveItem(at: firstURL, to: movedURL)
        reopened.refreshLibraryAvailability()
        await reopened.openLibraryEntry(firstID)
        record("library-bookmark-follows-rename", reopened.fileURL.map(LibraryFiles.canonical)?.path == LibraryFiles.canonical(movedURL).path && reopened.position == savedPosition && !reopened.unavailableEntryIDs.contains(firstID), "path=\(reopened.fileURL?.path ?? "none"), position=\(reopened.position), error=\(reopened.errorMessage ?? "none")")
        try "这是占用旧路径的另一份文件。".write(to: firstURL, atomically: true, encoding: .utf8)
        await reopened.addFiles([firstURL])
        let newID = reopened.currentLibraryID
        record("library-new-file-at-old-path-keeps-separate-record", newID != firstID && reopened.libraryEntries.count == 3, "")
        if let newID, newID != firstID { reopened.removeLibraryEntry(newID) }
        await reopened.openLibraryEntry(firstID)
        let oldContent = content
        let newContent = "新增前言。\n" + oldContent
        try newContent.write(to: movedURL, atomically: true, encoding: .utf8)
        await reopened.openLibraryEntry(firstID)
        record("library-changed-content-restores-anchor", reopened.position == savedPosition + ("新增前言。\n" as NSString).length && reopened.libraryNotice != nil, "position=\(reopened.position), expected=\(savedPosition + ("新增前言。\n" as NSString).length), notice=\(reopened.libraryNotice ?? "none")")

        try FileManager.default.removeItem(at: secondURL)
        reopened.refreshLibraryAvailability()
        await reopened.openLibraryEntry(secondID)
        record("library-missing-file-keeps-entry-and-current-document", reopened.unavailableEntryIDs.contains(secondID) && reopened.libraryEntries.count == 2 && reopened.currentLibraryID == firstID, "")
        reopened.errorMessage = nil
        let replacement = folder.appendingPathComponent("重新定位的第二本.txt")
        try "另一本文本，应该拥有独立的进度。".write(to: replacement, atomically: true, encoding: .utf8)
        await reopened.load(replacement, restoringID: secondID)
        record("library-relink-retains-id-and-progress", reopened.currentLibraryID == secondID && reopened.position == secondPosition && reopened.libraryEntries.count == 2 && !reopened.unavailableEntryIDs.contains(secondID), "")
        reopened.removeLibraryEntry(secondID)
        record("library-remove-closes-current-and-preserves-original", !reopened.hasText && reopened.currentLibraryID == nil && reopened.libraryEntries.count == 1 && FileManager.default.fileExists(atPath: replacement.path), "")
        await reopened.openLibraryEntry(firstID)
        reopened.clearLibrary()
        let clearedSnapshot = try store.load()
        record("library-clear-persists-and-preserves-original", reopened.libraryEntries.isEmpty && !reopened.hasText && clearedSnapshot.entries.isEmpty && FileManager.default.fileExists(atPath: movedURL.path), "")
        reader.stop(); reopened.stop()
    }
}
