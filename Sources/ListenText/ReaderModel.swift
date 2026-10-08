import AppKit
import AVFoundation
import Combine
import ReaderCore

@MainActor
final class ReaderModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum State: String { case ready = "准备就绪", playing = "正在朗读", paused = "已暂停", finished = "朗读完成" }

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

    override init() {
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
        shortcutAvailable = globalShortcut.register(shortcut)
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
        panel.title = "选择要朗读的文件"
        panel.message = "支持 TXT、Markdown、RTF、HTML、DOCX、PDF 和常见纯文本文件（最大 20 MB）。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.load(url) }
        }
        if let window = NSApp.keyWindow, window.identifier?.rawValue == "reader" {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func openExample() {
        guard let url = Bundle.main.url(forResource: "示例文本", withExtension: "txt") else { return }
        Task { await load(url) }
    }

    func load(_ url: URL) async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let loaded = try await DocumentImporter.load(url)
            let index = await Task.detached(priority: .userInitiated) {
                (ChapterParser.chapters(in: loaded), (loaded as NSString).length, loaded.count)
            }.value
            guard generation == loadGeneration else { return }
            stop()
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
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func togglePlayback() {
        guard !isLoading, !showShortcutSheet else { return }
        guard hasText else { NSApp.activate(ignoringOtherApps: true); openPanel(); return }
        switch state {
        case .playing:
            state = .paused
            if didStartCurrentUtterance { _ = synthesizer.pauseSpeaking(at: .immediate) }
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
    }

    func seek(to fraction: Double) {
        let wasPlaying = isPlaying
        stop()
        let requested = Int(Double(textLength) * min(1, max(0, fraction)))
        position = requested < textLength ? documentSource.rangeOfComposedCharacterSequence(at: requested).location : requested
        if let index = ChapterParser.chapterIndex(at: position, in: chapters) { displayChapter(index) }
        spokenRange = NSRange(location: position, length: 0)
        if wasPlaying { beginReading(from: position) }
    }

    func seekInChapter(to fraction: Double) {
        guard let chapter = currentChapter else { return }
        let wasPlaying = isPlaying
        stop()
        let requested = chapter.range.location + Int(Double(chapter.range.length) * min(1, max(0, fraction)))
        position = requested < textLength ? documentSource.rangeOfComposedCharacterSequence(at: requested).location : requested
        spokenRange = NSRange(location: position, length: 0)
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
    }

    func moveChapter(by amount: Int) {
        guard let id = selectedChapterID else { return }
        selectChapter(id + amount)
    }

    func restartChapter() {
        if let id = selectedChapterID { selectChapter(id) }
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
            self.errorMessage = "系统停止了朗读，请重新播放。若仍无声音，请检查声音资源和音频输出设备。"
        }
    }
}

struct TextFocusRequest: Equatable {
    let id = UUID()
    let range: NSRange
}
