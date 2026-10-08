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
}
