import AppKit
import AVFoundation

struct VoiceChoice: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let language: String
    let quality: String
    var label: String { quality.isEmpty ? name : "\(name)（\(quality)）" }
    var detail: String { Locale(identifier: "zh_CN").localizedString(forIdentifier: language) ?? language }
}

struct VoiceRecommendation: Identifiable, Sendable {
    let id: String
    let category: String
    let voice: VoiceChoice

    func choice(in installed: [VoiceChoice]) -> VoiceChoice {
        installed.first { $0.id == voice.id } ?? voice
    }
}

/// Save metadata as well as identifiers so uninstalled favorites remain visible and removable.
struct VoiceFavoritesStore {
    let defaults: UserDefaults
    static let key = "favoriteVoices"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [VoiceChoice] {
        guard let data = defaults.data(forKey: Self.key),
              let records = try? JSONDecoder().decode([VoiceChoice].self, from: data) else { return [] }
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }

    func save(_ records: [VoiceChoice]) {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.key) }
    }

    func toggle(_ voice: VoiceChoice) -> [VoiceChoice] {
        var records = load()
        if records.contains(where: { $0.id == voice.id }) { records.removeAll { $0.id == voice.id } }
        else { records.append(voice) }
        save(records)
        return records
    }
}

enum VoiceCatalog {
    static let recommendations: [VoiceRecommendation] = [
        VoiceRecommendation(id: "zh-female", category: "中文 · 女声 · 普通话",
            voice: VoiceChoice(id: "com.apple.voice.premium.zh-CN.Lilian", name: "黎潋", language: "zh-CN", quality: "高音质")),
        VoiceRecommendation(id: "zh-male", category: "中文 · 男声 · 普通话 · Han",
            voice: VoiceChoice(id: "com.apple.voice.premium.zh-CN.Han", name: "瀚", language: "zh-CN", quality: "高音质")),
        VoiceRecommendation(id: "en-female", category: "英文 · 女声 · 美式英语",
            voice: VoiceChoice(id: "com.apple.voice.premium.en-US.Ava", name: "Ava", language: "en-US", quality: "高音质")),
        VoiceRecommendation(id: "en-male", category: "英文 · 男声 · 英式英语",
            voice: VoiceChoice(id: "com.apple.voice.premium.en-GB.Jamie", name: "Jamie", language: "en-GB", quality: "高音质"))
    ]

    static func normalizedName(_ name: String) -> String {
        // AVFoundation localizes quality suffixes according to the app's language.
        name.replacingOccurrences(of: #"\s*[（(](?:Premium|Enhanced|高音质|高音質|优化音质|優化音質|增强|增強)[）)]"#,
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Snapshot: Sendable {
        let choices: [VoiceChoice]
        let defaultID: String?
        let defaultLabel: String
        let followsSelection: Bool
    }

    static func load() -> Snapshot {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let (systemVoice, followsSelection) = systemVoice()
        var voices = installed
        if let systemVoice, !voices.contains(where: { $0.identifier == systemVoice.identifier }) {
            voices.append(systemVoice)
        }
        let choices = voices.map { voice in
            let baseName = normalizedName(voice.name)
            let name = voice.identifier.hasSuffix("zh-CN.Yue") ? "月" : baseName
            return VoiceChoice(id: voice.identifier, name: name, language: voice.language,
                        quality: voice.quality == .premium ? "高音质" : voice.quality == .enhanced ? "增强" : "")
        }.sorted {
            let a = $0.language.hasPrefix("zh"), b = $1.language.hasPrefix("zh")
            if a != b { return a }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        let label = choices.first { $0.id == systemVoice?.identifier }?.label ?? "系统默认声音"
        return Snapshot(choices: choices, defaultID: systemVoice?.identifier,
                        defaultLabel: label, followsSelection: followsSelection)
    }

    static func systemVoice() -> (AVSpeechSynthesisVoice?, Bool) {
        // macOS does not expose the Reading & Speech selection through AVFoundation.
        // Read the same preference used by Chromium, without modifying system settings.
        // This key can change between macOS releases; retain public-API fallbacks.
        let defaults = UserDefaults(suiteName: "com.apple.Accessibility")
        let entries = defaults?.array(forKey: "SpokenContentDefaultVoiceSelectionsByLanguage") ?? []
        let preferred = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "zh"
        var selections: [(String, String)] = []
        for index in entries.indices {
            if let info = entries[index] as? [String: Any], let id = info["voiceId"] as? String {
                let language = info["boundLanguage"] as? String ?? (index > 0 ? entries[index - 1] as? String : nil) ?? ""
                selections.append((language, id))
            }
        }
        let matches: (String) -> Bool = { $0 == preferred || (preferred == "zh" && $0 == "cmn") }
        let ordered = selections.filter { matches($0.0) } + selections.filter { !matches($0.0) }
        for (_, id) in ordered {
            if let voice = AVSpeechSynthesisVoice(identifier: id) { return (voice, true) }
        }
        if let voice = AVSpeechSynthesisVoice(identifier: NSSpeechSynthesizer.defaultVoice.rawValue) {
            return (voice, true)
        }
        return (AVSpeechSynthesisVoice(language: nil), false)
    }
}
