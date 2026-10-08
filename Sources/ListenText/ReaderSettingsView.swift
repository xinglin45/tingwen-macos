import SwiftUI

struct ReaderSettingsView: View {
    private enum Page: String, CaseIterable { case voices = "朗读声音", playback = "播放与快捷键" }
    private enum VoiceList: String, CaseIterable { case recommended = "推荐", favorites = "收藏", installed = "全部已安装" }
    @ObservedObject var model: ReaderModel
    let onShortcut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .voices
    @State private var voiceList: VoiceList = .recommended
    @State private var voiceQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("朗读设置").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }
            }.padding(24)
            Picker("设置分类", selection: $page) {
                ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
            if page == .voices { voicePage }
            else { playbackPage }
        }.frame(width: 620, height: 660)
    }

    private var voicePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("当前声音", selection: $model.selectedVoiceID) {
                    Text("跟随系统声音").tag("")
                    ForEach(model.voices) { Text("\($0.label) · \($0.language)").tag($0.id) }
                    if !model.selectedVoiceID.isEmpty && !model.isVoiceInstalled(model.selectedVoiceID) {
                        Text("所选声音不可用").tag(model.selectedVoiceID)
                    }
                }.accessibilityIdentifier("current-voice")
                if let current = model.voices.first(where: { $0.id == (model.selectedVoiceID.isEmpty ? model.systemVoiceID : model.selectedVoiceID) }) {
                    favoriteButton(current)
                }
            }
            Text(model.selectedVoiceID.isEmpty ? "跟随系统：\(model.currentVoiceLabel)" : "正在使用：\(model.currentVoiceLabel)")
                .font(.caption).foregroundStyle(.secondary)
            if !model.followsSystemSelection && model.selectedVoiceID.isEmpty {
                Text("未能读取系统选择，当前使用语言默认声音。可手动选择所需声音。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Picker("声音列表", selection: $voiceList) {
                    ForEach(VoiceList.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("voice-list-tabs")
                if voiceList == .favorites {
                    Text("\(model.favoriteVoices.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if voiceList != .recommended {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("按名称、语言搜索声音", text: $voiceQuery).textFieldStyle(.plain)
                        .accessibilityIdentifier("voice-search")
                    if !voiceQuery.isEmpty {
                        Button { voiceQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清除声音搜索")
                    }
                }.padding(9).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if voiceList == .recommended {
                        ForEach(VoiceCatalog.recommendations) { recommendation in
                            voiceRow(recommendation.choice(in: model.voices), subtitle: recommendation.category)
                        }
                    } else {
                        if listedVoices.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: voiceList == .favorites ? "star" : "magnifyingglass")
                                    .font(.system(size: 28)).foregroundStyle(.secondary)
                                Text(voiceList == .favorites && model.favoriteVoices.isEmpty ? "还没有收藏的声音" : "没有匹配的声音")
                                if voiceList == .favorites && model.favoriteVoices.isEmpty {
                                    Text("点击声音旁的空心星标，即可加入收藏。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity).padding(.vertical, 48)
                        }
                        ForEach(listedVoices) { voiceRow($0, subtitle: "\($0.detail) · \($0.language)") }
                    }
                }.padding(2)
            }.frame(maxHeight: .infinity)
            if let target = model.voiceDownloadTarget {
                downloadHint(target)
            } else {
                Text("☆ 未收藏　★ 已收藏 · 未安装声音可先收藏，点击“前往下载”打开系统设置。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("管理系统声音", action: model.openSystemVoiceSettings)
                Spacer()
                Text("\(model.voices.count) 个已安装声音").font(.caption).foregroundStyle(.secondary)
                Button("刷新声音") { Task { await model.refreshVoices() } }
            }
        }.padding(.horizontal, 24).padding(.bottom, 24)
    }

    private var listedVoices: [VoiceChoice] {
        let source = voiceList == .favorites ? model.favoriteVoices : model.voices
        let query = voiceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { "\($0.label) \($0.language) \($0.detail)".localizedCaseInsensitiveContains(query) }
    }

    private func voiceRow(_ voice: VoiceChoice, subtitle: String) -> some View {
        let installed = model.isVoiceInstalled(voice.id)
        let selected = model.selectedVoiceID == voice.id
        return HStack(spacing: 12) {
            favoriteButton(voice)
            VStack(alignment: .leading, spacing: 5) {
                Text(voice.label).font(.system(size: 14, weight: .semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if installed {
                Button { model.selectVoice(voice) } label: {
                    Label(selected ? "使用中" : "使用", systemImage: selected ? "checkmark.circle.fill" : "speaker.wave.2")
                }.disabled(selected).accessibilityIdentifier("use-\(voice.id)")
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    Button { model.openVoiceDownload(voice) } label: { Label("前往下载", systemImage: "arrow.down.circle") }
                        .accessibilityIdentifier("download-\(voice.id)")
                    Text("未安装").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(12)
            .background(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
    }

    private func favoriteButton(_ voice: VoiceChoice) -> some View {
        let saved = model.isVoiceFavorite(voice.id)
        return Button { model.toggleVoiceFavorite(voice) } label: {
            Image(systemName: saved ? "star.fill" : "star")
                .font(.system(size: 17)).foregroundStyle(saved ? Color.yellow : Color.secondary)
                .frame(width: 28, height: 28)
        }.buttonStyle(.plain)
            .help(saved ? "移除收藏" : "收藏声音")
            .accessibilityLabel("\(saved ? "移除收藏" : "收藏")：\(voice.label)")
            .accessibilityIdentifier("favorite-\(voice.id)")
    }

    private func downloadHint(_ voice: VoiceChoice) -> some View {
        let installed = model.isVoiceInstalled(voice.id)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: installed ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(installed ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(installed ? "\(voice.label) 已安装，可以点击“使用”。" : "下载 \(voice.label)")
                    .font(.caption).fontWeight(.medium)
                if !installed {
                    Text("在系统“阅读与朗读”中，点击“系统声音”旁的 ⓘ，找到 \(voice.name)（\(voice.detail)）并下载高音质版本。回到听文后自动刷新；系统若未提供此版本，则暂不可用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { model.dismissVoiceDownload() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("关闭下载提示")
        }.padding(10).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var playbackPage: some View {
        Form {
            Section("播放") {
                HStack {
                    Text("语速")
                    Slider(value: $model.rate, in: 0.25...0.7, step: 0.01,
                           onEditingChanged: { if !$0 { model.applySpeechSettings() } }).accessibilityLabel("语速")
                    Button("标准") { model.rate = 0.5; model.applySpeechSettings() }
                }
                HStack {
                    Text("音量")
                    Slider(value: $model.volume, in: 0...1,
                           onEditingChanged: { if !$0 { model.applySpeechSettings() } }).accessibilityLabel("音量")
                    Text("\(Int(model.volume * 100))%").monospacedDigit().frame(width: 42)
                }
            }
            Section("全局播放 / 暂停快捷键") {
                Button(action: onShortcut) {
                    HStack { Text(model.shortcut.display).font(.system(.body, design: .monospaced)); Spacer(); Text("修改…") }
                }
                Text(model.shortcutAvailable ? "应用运行时，在其他 App 中也有效。" : "快捷键不可用，请更换组合键。")
                    .font(.caption).foregroundStyle(model.shortcutAvailable ? Color.secondary : Color.orange)
            }
        }.formStyle(.grouped)
    }
}
