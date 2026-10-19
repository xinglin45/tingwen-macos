import AppKit
import AVFoundation
import Combine
import ReaderCore
import CryptoKit

@MainActor
final class ReaderModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum State: String { case ready = "准备就绪", playing = "正在朗读", paused = "已暂停", finished = "朗读完成" }

    @Published private(set) var libraryEntries: [LibraryEntry] = []
    @Published private(set) var unavailableEntryIDs: Set<UUID> = []
    @Published private(set) var currentLibraryID: UUID?
    @Published private(set) var isAddingFiles = false
    @Published private(set) var sourceEncodingLabel: String?
    @Published private(set) var libraryNotice: String?
    @Published private(set) var resumeMarkerOffset: Int?
    @Published var showClearLibraryConfirmation = false
    @Published private(set) var text = ""
    @Published private(set) var fileURL: URL?
    @Published private(set) var state: State = .ready
    @Published private(set) var isLoading = false
    @Published private(set) var chapters: [DocumentChapter] = []
    @Published private(set) var selectedChapterID: Int?
    @Published private(set) var displayedText = ""
    @Published private(set) var displayedTextID = UUID()
    @Published private(set) var textLength = 0
    @Published private(set) var characterCount = 0
    @Published private(set) var searchResults: [ChapterSearchResult] = []
    @Published private(set) var searchHighlights: [NSRange] = []
    @Published private(set) var isSearching = false
    @Published private(set) var focusRequest: TextFocusRequest?
    @Published var searchQuery = "" { didSet { scheduleSearch() } }
    @Published private(set) var voices: [VoiceChoice] = []
    @Published private(set) var favoriteVoices: [VoiceChoice] = []
    @Published private(set) var voiceDownloadTarget: VoiceChoice?
    @Published private(set) var systemVoiceLabel = "正在读取系统声音…"
    @Published private(set) var systemVoiceID: String?
    @Published private(set) var followsSystemSelection = true
    @Published private(set) var spokenRange = NSRange(location: 0, length: 0)
    @Published private(set) var position = 0
    @Published private(set) var shortcut: KeyboardShortcut
    @Published private(set) var shortcutAvailable = false
    @Published var errorMessage: String?
    @Published var showShortcutSheet = false
    @Published var followsReading = true
    @Published var selectionOffset = 0
    @Published var selectedVoiceID: String {
        didSet {
            UserDefaults.standard.set(selectedVoiceID, forKey: "voiceID")
            applySpeechSettings()
        }
    }
    @Published var rate: Double {
        didSet { UserDefaults.standard.set(rate, forKey: "rate") }
    }
    @Published var volume: Double {
        didSet { UserDefaults.standard.set(volume, forKey: "volume") }
    }

    private let libraryStore: ReadingLibraryStore
    private var library = ReadingLibrary()
    private var canSaveLibrary = true
    private var playbackCheckpoint: ReadingCheckpoint?
    private var pendingCheckpoint = false
    private var lastCheckpointSave = Date.distantPast
    private var currentDigest = ""
    private var didRestoreLibrary = false
    private let synthesizer = AVSpeechSynthesizer()
    private let globalShortcut = GlobalShortcut()
    private let voiceFavoritesStore = VoiceFavoritesStore()
    private var utterance: AVSpeechUtterance?
    private var segments: [SpeechSegment] = []
    private var segmentIndex = 0
    private var loadGeneration = UUID()
    private var refreshingVoices = false
    private var didStartCurrentUtterance = false
    private var currentVoiceID: String?
    private var documentSource: NSString = ""
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()

    var hasText: Bool { !text.isEmpty }
    var isPlaying: Bool { state == .playing }
    var title: String { fileURL?.lastPathComponent ?? "你的下一篇，听着读。" }
    var progress: Double { textLength == 0 ? 0 : Double(position) / Double(textLength) }
    var currentChapter: DocumentChapter? {
        guard let id = selectedChapterID, chapters.indices.contains(id) else { return nil }
        return chapters[id]
    }
    var chapterProgress: Double {
        guard let chapter = currentChapter, chapter.range.length > 0 else { return 0 }
        return min(1, max(0, Double(position - chapter.range.location) / Double(chapter.range.length)))
    }
    var localSpokenRange: NSRange {
        guard let chapter = currentChapter, spokenRange.length > 0 else { return NSRange(location: 0, length: 0) }
        let intersection = NSIntersectionRange(chapter.range, spokenRange)
        guard intersection.length > 0 else { return NSRange(location: 0, length: 0) }
        return NSRange(location: intersection.location - chapter.range.location, length: intersection.length)
    }
    var searchMatchCount: Int { searchResults.reduce(0) { $0 + $1.matches.count } }
    var currentVoiceLabel: String {
        if selectedVoiceID.isEmpty { return systemVoiceLabel }
        return voices.first { $0.id == selectedVoiceID }?.label ?? "所选声音不可用"
    }

    override convenience init() { self.init(libraryURL: LibraryFiles.storeURL) }

    init(libraryURL: URL, registerShortcut: Bool = true) {
        libraryStore = ReadingLibraryStore(url: libraryURL)
        let defaults = UserDefaults.standard
        selectedVoiceID = defaults.string(forKey: "voiceID") ?? ""
        rate = defaults.object(forKey: "rate") == nil ? 0.5 : min(0.7, max(0.25, defaults.double(forKey: "rate")))
        volume = defaults.object(forKey: "volume") == nil ? 1 : min(1, max(0, defaults.double(forKey: "volume")))
        if let data = defaults.data(forKey: "shortcut"), let saved = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            shortcut = saved
        } else { shortcut = .standard }
        super.init()
        favoriteVoices = voiceFavoritesStore.load()
        synthesizer.delegate = self
        globalShortcut.action = { [weak self] in self?.togglePlayback() }
        if registerShortcut { shortcutAvailable = globalShortcut.register(shortcut) }
        do {
            library = try libraryStore.load()
            libraryEntries = library.sortedEntries
            refreshLibraryAvailability()
        } catch {
            canSaveLibrary = false
            errorMessage = "无法读取书架记录。原记录已保留，请检查文件：\(libraryStore.url.path)\n\(error.localizedDescription)"
        }
        Task { await refreshVoices() }
    }

    func refreshVoices() async {
        guard !refreshingVoices else { return }
        refreshingVoices = true
        let snapshot = await Task.detached(priority: .userInitiated) { VoiceCatalog.load() }.value
        voices = snapshot.choices
        favoriteVoices = favoriteVoices.map { saved in voices.first { $0.id == saved.id } ?? saved }
        voiceFavoritesStore.save(favoriteVoices)
        systemVoiceLabel = snapshot.defaultLabel
        systemVoiceID = snapshot.defaultID
        followsSystemSelection = snapshot.followsSelection
        refreshingVoices = false
    }

    func isVoiceInstalled(_ id: String) -> Bool { voices.contains { $0.id == id } }

    func isVoiceFavorite(_ id: String) -> Bool { favoriteVoices.contains { $0.id == id } }

    func toggleVoiceFavorite(_ voice: VoiceChoice) {
        favoriteVoices = voiceFavoritesStore.toggle(voice)
    }

    func selectVoice(_ voice: VoiceChoice) {
        guard isVoiceInstalled(voice.id) else { return }
        selectedVoiceID = voice.id
    }

    func openVoiceDownload(_ voice: VoiceChoice) {
        voiceDownloadTarget = voice
        openSystemVoiceSettings()
    }

    func dismissVoiceDownload() { voiceDownloadTarget = nil }

    func openSystemVoiceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"),
           NSWorkspace.shared.open(url) { return }
        errorMessage = "无法打开系统声音设置。请前往系统设置 → 辅助功能 → 阅读与朗读 → 系统声音。"
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "添加文本到书架"
        panel.message = "支持 TXT、Markdown、RTF、HTML、DOCX、PDF 和常见纯文本文件（最大 20 MB）。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        let encodingPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 230, height: 28))
        encodingPicker.addItems(withTitles: TextEncoding.allCases.map(\.label))
        let accessory = NSStackView(views: [NSTextField(labelWithString: "文本编码："), encodingPicker])
        accessory.orientation = .horizontal
        accessory.spacing = 10
        accessory.frame = NSRect(x: 0, y: 0, width: 350, height: 32)
        panel.accessoryView = accessory
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in await self?.addFiles(urls, encoding: TextEncoding.allCases[encodingPicker.indexOfSelectedItem]) }
        }
        if let window = NSApp.keyWindow, window.identifier?.rawValue == "reader" {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func openExample() {
        guard let url = Bundle.main.url(forResource: "示例文本", withExtension: "txt") else { return }
        Task { await load(url, remember: false) }
    }

    @discardableResult
    func load(_ url: URL, remember: Bool = true, restoringID: UUID? = nil, encoding: TextEncoding? = nil) async -> Bool {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let knownID = restoringID ?? existingLibraryID(for: url)
            let savedEncoding = library.entries.first { $0.id == knownID }?.encodingOverride.flatMap(TextEncoding.init(rawValue:))
            let requestedEncoding = encoding ?? savedEncoding ?? .automatic
            let imported = try await DocumentImporter.read(url, encoding: requestedEncoding, conversionDirectory: remember ? conversionDirectory : nil)
            let loaded = imported.text
            let index = await Task.detached(priority: .userInitiated) {
                (ChapterParser.chapters(in: loaded), (loaded as NSString).length, loaded.count, Self.digest(loaded))
            }.value
            guard generation == loadGeneration else { return false }
            stop()
            let entry = remember ? try registerFile(url, textDigest: index.3, imported: imported, encoding: requestedEncoding, replacingID: restoringID, opening: true) : nil
            currentLibraryID = entry?.id
            currentDigest = index.3
            playbackCheckpoint = entry?.checkpoint
            pendingCheckpoint = false
            resumeMarkerOffset = nil
            sourceEncodingLabel = imported.sourceEncoding?.label
            libraryNotice = imported.convertedUTF8URL != nil ? "已将 \(imported.sourceEncoding?.label ?? "原编码") 文本自动转为 UTF-8，原文件保持不变。" : nil
            text = loaded
            documentSource = loaded as NSString
            textLength = index.1
            characterCount = index.2
            chapters = index.0
            selectedChapterID = nil
            searchQuery = ""
            displayChapter(0)
            fileURL = url
            selectionOffset = 0
            position = 0
            spokenRange = NSRange(location: 0, length: 0)
            state = .ready
            errorMessage = nil
            if let checkpoint = entry?.checkpoint {
                let unchanged = entry?.contentDigest == currentDigest
                let restored = checkpoint.restore(in: loaded, chapters: chapters, unchanged: unchanged)
                position = restored.offset
                if let chapter = ChapterParser.chapterIndex(at: position, in: chapters) { displayChapter(chapter) }
                selectionOffset = position
                resumeMarkerOffset = position < textLength ? position : nil
                if let chapter = currentChapter {
                    focusRequest = TextFocusRequest(range: NSRange(location: min(chapter.range.length, max(0, position - chapter.range.location)), length: 0))
                }
                state = unchanged && checkpoint.finished ? .finished : .ready
                if !unchanged {
                    let restoreNotice = restored.exact ? "文件内容已更新，已找到上次播放的位置。" : "文件内容已变化，无法准确恢复；已定位到对应章节开头。"
                    libraryNotice = [libraryNotice, restoreNotice].compactMap { $0 }.joined(separator: " ")
                    playbackCheckpoint = ReadingCheckpoint(text: loaded, chapters: chapters, offset: position)
                    pendingCheckpoint = true
                    flushReadingProgress()
                } else if checkpoint.chapterTitle != currentChapter?.title || checkpoint.chapterIndex != selectedChapterID {
                    // A parser update can discover new chapters without changing the document.
                    // Refresh chapter metadata while preserving the absolute position and reading date.
                    let updated = ReadingCheckpoint(source: documentSource, chapters: chapters, offset: position, finished: checkpoint.finished)
                    playbackCheckpoint = updated
                    if let id = currentLibraryID, let index = library.entries.firstIndex(where: { $0.id == id }) {
                        var next = library
                        next.entries[index].checkpoint = updated
                        do { try saveLibrary(next) }
                        catch { libraryNotice = "章节进度信息保存失败：\(error.localizedDescription)" }
                    }
                }
            }
            return true
        } catch {
            guard generation == loadGeneration else { return false }
            errorMessage = error.localizedDescription
            if let restoringID { unavailableEntryIDs.insert(restoringID) }
            return false
        }
    }

    func togglePlayback() {
        guard !isLoading, !showShortcutSheet else { return }
        guard hasText else { NSApp.activate(ignoringOtherApps: true); openPanel(); return }
        switch state {
        case .playing:
            state = .paused
            if didStartCurrentUtterance { _ = synthesizer.pauseSpeaking(at: .immediate) }
            flushReadingProgress()
        case .paused:
            state = .playing
            if utterance == nil { beginReading(from: position) }
            else if synthesizer.isPaused { _ = synthesizer.continueSpeaking() }
        case .ready, .finished:
            if state == .finished { position = 0 }
            beginReading(from: position)
        }
    }

    func stop() {
        flushReadingProgress()
        utterance = nil // Ignore late callbacks from cancelled speech.
        _ = synthesizer.stopSpeaking(at: .immediate)
        state = .ready
        spokenRange = NSRange(location: position, length: 0)
    }

    func restart() {
        stop()
        displayChapter(0)
        position = 0
        selectionOffset = 0
        spokenRange = NSRange(location: 0, length: 0)
        focusRequest = TextFocusRequest(range: NSRange(location: 0, length: 0))
        captureReadingProgress(immediate: true)
    }

    func seek(to fraction: Double) {
        let wasPlaying = isPlaying
        stop()
        let requested = Int(Double(textLength) * min(1, max(0, fraction)))
        position = requested < textLength ? documentSource.rangeOfComposedCharacterSequence(at: requested).location : requested
        if let index = ChapterParser.chapterIndex(at: position, in: chapters) { displayChapter(index) }
        spokenRange = NSRange(location: position, length: 0)
        captureReadingProgress(immediate: true)
        if wasPlaying { beginReading(from: position) }
    }

    func seekInChapter(to fraction: Double) {
        guard let chapter = currentChapter else { return }
        let wasPlaying = isPlaying
        stop()
        let requested = chapter.range.location + Int(Double(chapter.range.length) * min(1, max(0, fraction)))
        position = requested < textLength ? documentSource.rangeOfComposedCharacterSequence(at: requested).location : requested
        spokenRange = NSRange(location: position, length: 0)
        captureReadingProgress(immediate: true)
        if wasPlaying { beginReading(from: position) }
    }

    func selectChapter(_ id: Int) {
        guard chapters.indices.contains(id) else { return }
        stop()
        displayChapter(id)
        position = chapters[id].range.location
        selectionOffset = position
        spokenRange = NSRange(location: position, length: 0)
        focusRequest = TextFocusRequest(range: NSRange(location: 0, length: 0))
        resumeMarkerOffset = nil
    }

    func moveChapter(by amount: Int) {
        guard let id = selectedChapterID else { return }
        selectChapter(id + amount)
    }

    func restartChapter() {
        if let id = selectedChapterID { selectChapter(id); captureReadingProgress(immediate: true) }
    }

    func setSelection(_ offset: Int, chapterID: Int?) {
        guard chapterID == selectedChapterID, let chapter = currentChapter else { return }
        selectionOffset = chapter.range.location + min(chapter.range.length, max(0, offset))
    }

    func readFromChapterSelection(_ offset: Int, chapterID: Int?) {
        guard chapterID == selectedChapterID, let chapter = currentChapter else { return }
        readFromSelection(chapter.range.location + min(chapter.range.length, max(0, offset)))
    }

    func showSearchResult(_ result: ChapterSearchResult) {
        guard searchResults.contains(where: { $0.id == result.id }), let first = result.matches.first else { return }
        selectChapter(result.chapterID)
        position = first.location
        selectionOffset = first.location
        spokenRange = NSRange(location: position, length: 0)
        focusRequest = TextFocusRequest(range: NSRange(location: first.location - chapters[result.chapterID].range.location,
                                                     length: first.length))
    }

    private func displayChapter(_ index: Int) {
        guard chapters.indices.contains(index), selectedChapterID != index else { return }
        selectedChapterID = index
        displayedText = documentSource.substring(with: chapters[index].range)
        displayedTextID = UUID()
        selectionOffset = chapters[index].range.location
        focusRequest = nil
        updateSearchHighlights()
    }

    private func updateSearchHighlights() {
        guard let chapter = currentChapter else { searchHighlights = []; return }
        searchHighlights = (searchResults.first { $0.chapterID == chapter.id }?.matches ?? []).map {
            NSRange(location: $0.location - chapter.range.location, length: $0.length)
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let generation = UUID()
        searchGeneration = generation
        searchResults = []
        searchHighlights = []
        focusRequest = nil
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasText, !query.isEmpty else { isSearching = false; return }
        isSearching = true
        let text = text, chapters = chapters
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) {
                ChapterSearch.results(for: query, in: text, chapters: chapters, isCancelled: { Task.isCancelled })
            }
            let results = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
            self.searchResults = results
            self.isSearching = false
            self.updateSearchHighlights()
        }
    }

    func readFromSelection(_ offset: Int) {
        stop()
        beginReading(from: offset)
    }

    func applySpeechSettings() {
        guard utterance != nil else { return }
        let wasPlaying = isPlaying
        stop()
        if wasPlaying { beginReading(from: position) }
        else { state = .paused }
    }

    private func beginReading(from offset: Int) {
        guard hasText else { return }
        utterance = nil
        _ = synthesizer.stopSpeaking(at: .immediate)
        if !selectedVoiceID.isEmpty, AVSpeechSynthesisVoice(identifier: selectedVoiceID) == nil {
            errorMessage = "所选声音已不可用。请重新选择声音，或选择“跟随系统声音”。"
            state = .ready
            return
        }
        currentVoiceID = selectedVoiceID.isEmpty ? VoiceCatalog.systemVoice().0?.identifier : selectedVoiceID
        let offset = min(textLength, max(0, offset))
        guard let chapterIndex = ChapterParser.chapterIndex(at: offset, in: chapters) else { return }
        displayChapter(chapterIndex)
        let chapter = chapters[chapterIndex]
        position = offset
        segments = SpeechSegmenter.segments(in: displayedText, from: offset - chapter.range.location).map {
            SpeechSegment(text: $0.text, range: NSRange(location: chapter.range.location + $0.range.location, length: $0.range.length))
        }
        segmentIndex = 0
        state = .playing
        captureReadingProgress(immediate: true)
        speakNext()
    }

    private func speakNext() {
        while segmentIndex < segments.count, segments[segmentIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            position = NSMaxRange(segments[segmentIndex].range)
            segmentIndex += 1
        }
        guard segmentIndex < segments.count else {
            utterance = nil
            guard state == .playing else { return }
            if let id = selectedChapterID, id + 1 < chapters.count {
                beginReading(from: chapters[id + 1].range.location)
                return
            }
            position = textLength
            spokenRange = NSRange(location: textLength, length: 0)
            state = .finished
            captureReadingProgress(immediate: true)
            return
        }
        guard state == .playing else { utterance = nil; return }
        let segment = segments[segmentIndex]
        position = segment.range.location
        let next = AVSpeechUtterance(string: segment.text)
        if let id = currentVoiceID { next.voice = AVSpeechSynthesisVoice(identifier: id) }
        next.rate = Float(rate)
        next.volume = Float(volume)
        utterance = next
        didStartCurrentUtterance = false
        synthesizer.speak(next)
    }


    nonisolated private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func saveLibrary(_ next: ReadingLibrary) throws {
        guard canSaveLibrary else { throw CocoaError(.fileReadCorruptFile) }
        try libraryStore.save(next)
        let unusedCopies = Set(library.entries.compactMap(\.convertedUTF8Path)).subtracting(next.entries.compactMap(\.convertedUTF8Path))
        library = next
        libraryEntries = next.sortedEntries
        for path in unusedCopies {
            let file = URL(fileURLWithPath: path)
            if LibraryFiles.canonical(file.deletingLastPathComponent()) == LibraryFiles.canonical(conversionDirectory),
               file.lastPathComponent.range(of: "^[a-f0-9]{64}\\.txt$", options: .regularExpression) != nil {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private var conversionDirectory: URL { libraryStore.url.deletingLastPathComponent().appendingPathComponent("ConvertedTexts", isDirectory: true) }

    private func existingLibraryID(for url: URL) -> UUID? {
        let canonical = LibraryFiles.canonical(url)
        let identity = LibraryFiles.identity(canonical)
        return library.entries.first { entry in
            if let identity, entry.fileIdentity == identity { return true }
            guard entry.path == canonical.path else { return false }
            let resolved = LibraryFiles.resolve(bookmark: entry.bookmark, path: entry.path)
            return LibraryFiles.canonical(resolved).path == canonical.path
        }?.id
    }

    private func registerFile(_ url: URL, textDigest: String, imported: ImportedDocument,
                              encoding: TextEncoding, replacingID: UUID? = nil, opening: Bool) throws -> LibraryEntry {
        let canonical = LibraryFiles.canonical(url)
        let identity = LibraryFiles.identity(canonical)
        let existingID = existingLibraryID(for: url)
        if let replacingID, let existingID, replacingID != existingID {
            throw LibraryError.alreadyAdded
        }
        let id = replacingID ?? existingID
        var entry = id.flatMap { id in library.entries.first { $0.id == id } } ??
            LibraryEntry(name: canonical.lastPathComponent, path: canonical.path, contentDigest: textDigest)
        // Keep the previous digest until its checkpoint has been restored against the new text.
        entry.name = canonical.lastPathComponent
        entry.path = canonical.path
        entry.fileIdentity = identity
        entry.bookmark = LibraryFiles.bookmark(url)
        entry.sourceEncoding = imported.sourceEncoding?.rawValue
        entry.encodingOverride = encoding == .automatic ? nil : encoding.rawValue
        entry.convertedUTF8Path = imported.convertedUTF8URL?.path
        if opening { entry.lastOpenedAt = Date() }
        var next = library
        if let index = next.entries.firstIndex(where: { $0.id == entry.id }) { next.entries[index] = entry }
        else { next.entries.append(entry) }
        if opening { next.lastOpenedID = entry.id }
        try saveLibrary(next)
        unavailableEntryIDs.remove(entry.id)
        return entry
    }

    func addFiles(_ urls: [URL], encoding: TextEncoding? = nil) async {
        guard !isAddingFiles else { return }
        isAddingFiles = true
        defer { isAddingFiles = false }
        var opened = false
        var failures: [String] = []
        for url in urls {
            if !opened {
                if await load(url, encoding: encoding) { opened = true }
                else { failures.append("\(url.lastPathComponent)：\(errorMessage ?? "无法读取")") }
            } else {
                let accessed = url.startAccessingSecurityScopedResource()
                do {
                    let knownID = existingLibraryID(for: url)
                    let savedEncoding = library.entries.first { $0.id == knownID }?.encodingOverride.flatMap(TextEncoding.init(rawValue:))
                    let requestedEncoding = encoding ?? savedEncoding ?? .automatic
                    let imported = try await DocumentImporter.read(url, encoding: requestedEncoding, conversionDirectory: conversionDirectory)
                    let digest = await Task.detached { Self.digest(imported.text) }.value
                    _ = try registerFile(url, textDigest: digest, imported: imported, encoding: requestedEncoding, opening: false)
                } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
        }
        if !failures.isEmpty { errorMessage = "部分文件未能添加：\n" + failures.joined(separator: "\n") }
    }

    func restoreLastDocument() async {
        guard !didRestoreLibrary else { return }
        didRestoreLibrary = true
        guard !hasText, !isLoading, !isAddingFiles, let id = library.lastOpenedID else { return }
        await openLibraryEntry(id)
    }

    func openLibraryEntry(_ id: UUID, encoding: TextEncoding? = nil) async {
        guard let entry = library.entries.first(where: { $0.id == id }) else { return }
        if currentLibraryID == id { stop() } // Flush before reading this entry's saved checkpoint.
        let url = LibraryFiles.resolve(bookmark: entry.bookmark, path: entry.path)
        await load(url, restoringID: id, encoding: encoding)
    }

    func refreshLibraryAvailability() {
        unavailableEntryIDs = Set(library.entries.compactMap { entry in
            let url = LibraryFiles.resolve(bookmark: entry.bookmark, path: entry.path)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.isReadableFile(atPath: url.path) ? nil : entry.id
        })
    }

    func relocateLibraryEntry(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "重新定位书架文件"
        panel.message = "选择对应文件，保留原有阅读记录。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.load(url, restoringID: id) }
        }
    }

    func removeLibraryEntry(_ id: UUID) {
        guard !isLoading, !isAddingFiles else { return }
        if currentLibraryID == id { stop() }
        var next = library
        next.remove(id)
        do {
            try saveLibrary(next)
            unavailableEntryIDs.remove(id)
            if currentLibraryID == id { closeDocument() }
        } catch { errorMessage = "无法移除书架记录：\(error.localizedDescription)" }
    }

    func clearLibrary() {
        guard !isLoading, !isAddingFiles else { return }
        stop()
        do {
            try saveLibrary(ReadingLibrary())
            unavailableEntryIDs = []
            closeDocument()
        } catch { errorMessage = "无法清空书架：\(error.localizedDescription)" }
    }

    private func closeDocument() {
        loadGeneration = UUID()
        currentLibraryID = nil
        playbackCheckpoint = nil
        pendingCheckpoint = false
        fileURL = nil
        text = ""
        documentSource = ""
        chapters = []
        selectedChapterID = nil
        displayedText = ""
        displayedTextID = UUID()
        textLength = 0
        characterCount = 0
        searchQuery = ""
        spokenRange = NSRange(location: 0, length: 0)
        position = 0
        selectionOffset = 0
        resumeMarkerOffset = nil
        libraryNotice = nil
        sourceEncodingLabel = nil
    }

    func showConvertedCopy(_ entry: LibraryEntry) {
        guard let path = entry.convertedUTF8Path, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "UTF-8 副本暂不可用，请重新打开原文件以自动生成。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func captureReadingProgress(immediate: Bool = false) {
        guard currentLibraryID != nil, hasText else { return }
        resumeMarkerOffset = nil
        playbackCheckpoint = ReadingCheckpoint(source: documentSource, chapters: chapters, offset: position, finished: state == .finished)
        pendingCheckpoint = true
        if immediate || Date().timeIntervalSince(lastCheckpointSave) >= 2 { flushReadingProgress() }
    }

    func flushReadingProgress() {
        guard pendingCheckpoint, let id = currentLibraryID, let checkpoint = playbackCheckpoint,
              let index = library.entries.firstIndex(where: { $0.id == id }) else { return }
        var next = library
        next.entries[index].checkpoint = checkpoint
        next.entries[index].contentDigest = currentDigest
        next.entries[index].lastReadAt = Date()
        do {
            try saveLibrary(next)
            pendingCheckpoint = false
            lastCheckpointSave = Date()
        } catch {
            // Keep the pending checkpoint for retry; do not overwrite the previous disk record.
            if libraryNotice == nil { libraryNotice = "阅读进度保存失败：\(error.localizedDescription)" }
        }
    }

    var localResumeRange: NSRange {
        guard let offset = resumeMarkerOffset, let chapter = currentChapter,
              offset >= chapter.range.location, offset < NSMaxRange(chapter.range) else { return NSRange(location: 0, length: 0) }
        let range = documentSource.rangeOfComposedCharacterSequence(at: offset)
        return NSRange(location: range.location - chapter.range.location, length: range.length)
    }

    func dismissLibraryNotice() { libraryNotice = nil }

    func saveShortcut(_ candidate: KeyboardShortcut) -> Bool {
        guard globalShortcut.register(candidate) else { return false }
        shortcut = candidate
        shortcutAvailable = true
        if let data = try? JSONEncoder().encode(candidate) { UserDefaults.standard.set(data, forKey: "shortcut") }
        return true
    }

    func suspendShortcut() { globalShortcut.suspend(); shortcutAvailable = false }
    func restoreShortcut() { shortcutAvailable = globalShortcut.register(shortcut) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.didStartCurrentUtterance = true
            if self.state == .paused { _ = synthesizer.pauseSpeaking(at: .immediate) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance, self.segmentIndex < self.segments.count,
                  range.location != NSNotFound, range.length > 0,
                  NSMaxRange(range) <= (utterance.speechString as NSString).length else { return }
            let absolute = NSRange(location: self.segments[self.segmentIndex].range.location + range.location, length: range.length)
            self.position = absolute.location
            self.spokenRange = absolute
            self.captureReadingProgress()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance, self.segmentIndex < self.segments.count else { return }
            self.position = NSMaxRange(self.segments[self.segmentIndex].range)
            self.utterance = nil
            self.segmentIndex += 1
            self.speakNext()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.utterance === utterance else { return }
            self.utterance = nil
            self.state = .ready
            self.flushReadingProgress()
            self.errorMessage = "系统停止了朗读，请重新播放。若仍无声音，请检查声音资源和音频输出设备。"
        }
    }
}

struct TextFocusRequest: Equatable {
    let id = UUID()
    let range: NSRange
}

private enum LibraryError: LocalizedError {
    case alreadyAdded
    var errorDescription: String? { "所选文件已经在书架中，请打开已有条目，或选择另一个文件。" }
}
