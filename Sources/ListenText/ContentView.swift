import SwiftUI
import UniformTypeIdentifiers
import ReaderCore
import AVFoundation

struct ContentView: View {
    private enum SidebarTab: String, CaseIterable { case library = "书架", contents = "目录", search = "搜索" }
    @ObservedObject var model: ReaderModel
    @AppStorage("showsChapterSidebar") private var showsSidebar = true
    @State private var sidebarTab: SidebarTab = .library
    @State private var libraryQuery = ""
    @State private var showSettings = false
    @State private var seekValue = 0.0
    @State private var isSeeking = false
    @State private var isDropping = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                chapterSidebar.frame(width: 290)
                Divider()
            }
            VStack(spacing: 0) {
                documentHeader
                Divider()
                if model.hasText {
                    chapterHeader
                    Divider()
                }
                if let notice = model.libraryNotice {
                    HStack {
                        Text(notice).font(.callout)
                        Spacer()
                        Button(action: model.dismissLibraryNotice) { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel("关闭书架提示")
                    }.padding(12).background(Color.accentColor.opacity(0.08))
                }
                ZStack {
                    if model.hasText {
                        let chapterID = model.selectedChapterID
                        ReaderTextView(text: model.displayedText, textID: model.displayedTextID,
                                       highlightedRange: model.localSpokenRange.length > 0 ? model.localSpokenRange : model.localResumeRange,
                                       searchRanges: model.searchHighlights, focusRequest: model.focusRequest,
                                       followsReading: model.followsReading,
                                       onSelection: { model.setSelection($0, chapterID: chapterID) },
                                       onReadFrom: { model.readFromChapterSelection($0, chapterID: chapterID) })
                    } else { emptyState }
                    if model.isLoading {
                        Color(nsColor: .windowBackgroundColor).opacity(0.85)
                        ProgressView("正在读取文字和章节…").padding(28)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                Divider()
                playbackBar
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .tint(Color(red: 0.10, green: 0.48, blue: 0.44))
        .animation(.easeInOut(duration: 0.18), value: showsSidebar)
        .overlay {
            if isDropping {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            guard !providers.isEmpty, !model.isAddingFiles else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                await model.addFiles(urls)
            }
            return true
        }
        .onChange(of: model.chapterProgress) { _, value in if !isSeeking { seekValue = value } }
        .onChange(of: model.searchQuery) { _, value in if !value.isEmpty { sidebarTab = .search } }
        .sheet(isPresented: Binding(get: { showSettings || model.showShortcutSheet }, set: {
            if !$0 { showSettings = false; model.showShortcutSheet = false }
        })) {
            if model.showShortcutSheet { ShortcutSheet(model: model) }
            else { ReaderSettingsView(model: model, onShortcut: { model.showShortcutSheet = true; showSettings = false }) }
        }
        .alert("无法完成操作", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("清空书架？", isPresented: $model.showClearLibraryConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空书架", role: .destructive) { model.clearLibrary() }
        } message: { Text("将移除全部文件记录和阅读进度，磁盘上的原文件不会被删除。") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLibraryAvailability()
            Task { await model.refreshVoices() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in
            Task { await model.refreshVoices() }
        }
    }

    private var chapterSidebar: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 22, weight: .medium)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("听文").font(.system(size: 23, weight: .semibold))
                    Text("把文字，交给声音").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.top, 8)
            Button(action: model.openPanel) {
                Label(model.isAddingFiles ? "正在添加…" : "添加文本文件", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
            }.controlSize(.large).buttonStyle(.borderedProminent).disabled(model.isAddingFiles || model.isLoading)
            Picker("侧栏内容", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            if sidebarTab == .library {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("查找书架文件", text: $libraryQuery).textFieldStyle(.plain)
                    Menu {
                        Button("刷新文件状态", action: model.refreshLibraryAvailability)
                        Divider()
                        Button("清空书架…", role: .destructive) { model.showClearLibraryConfirmation = true }
                            .disabled(model.libraryEntries.isEmpty || model.isLoading || model.isAddingFiles)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("管理书架").accessibilityLabel("管理书架")
                }.padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            } else {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索全文", text: $model.searchQuery)
                    .textFieldStyle(.plain).focused($searchFocused).accessibilityIdentifier("book-search")
                if !model.searchQuery.isEmpty {
                    Button { model.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
                }
            }.padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
            if sidebarTab == .search {
                HStack(spacing: 8) {
                    if model.isSearching { ProgressView().controlSize(.small) }
                    Text(model.isSearching ? "正在搜索…" : model.searchQuery.isEmpty ? "输入关键词搜索全文" :
                            "\(model.searchResults.count) 个章节 · \(model.searchMatchCount) 处匹配")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if sidebarTab == .library {
                            ForEach(filteredLibrary) { entry in libraryRow(entry) }
                            if model.libraryEntries.isEmpty {
                                sidebarMessage("添加本地文本到书架，\n下次打开即可继续阅读", icon: "books.vertical")
                            } else if filteredLibrary.isEmpty {
                                sidebarMessage("没有匹配的文件", icon: "magnifyingglass")
                            }
                        } else if sidebarTab == .contents {
                            ForEach(model.chapters) { chapter in
                                Button { model.selectChapter(chapter.id) } label: {
                                    Text(chapter.title).font(.system(size: 13)).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 11).padding(.vertical, 10)
                                        .background(rowBackground(chapter.id), in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help(chapter.title).id(chapter.id)
                                    .accessibilityIdentifier("chapter-\(chapter.id)")
                            }
                            if !model.hasText { sidebarMessage("打开文件后显示章节目录", icon: "list.bullet") }
                        } else {
                            ForEach(model.searchResults) { result in
                                Button { model.showSearchResult(result) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .top, spacing: 8) {
                                            Text(result.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                            Spacer(minLength: 0)
                                            Text("\(result.matches.count)").font(.caption2).monospacedDigit()
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                        }
                                        Text(result.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(11).background(rowBackground(result.id), in: RoundedRectangle(cornerRadius: 8))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help(result.title).id(result.id)
                                    .accessibilityLabel("\(result.title)，\(result.matches.count) 处匹配")
                                    .accessibilityIdentifier("search-result-\(result.id)")
                            }
                            if !model.isSearching && model.searchResults.isEmpty {
                                sidebarMessage(model.searchQuery.isEmpty ? "搜索正文或章节标题" : "没有找到匹配内容", icon: "magnifyingglass")
                            }
                        }
                    }.padding(.vertical, 2)
                }
                .onChange(of: model.selectedChapterID) { _, id in
                    if sidebarTab == .contents, let id { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: sidebarTab) { _, tab in
                    if tab == .contents, let id = model.selectedChapterID { proxy.scrollTo(id, anchor: .center) }
                }
            }.disabled(model.isLoading || model.isAddingFiles)
            Divider()
            HStack {
                Text(sidebarTab == .library ? "\(model.libraryEntries.count) 个文件" : "\(model.chapters.count) 个章节").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showSettings = true } label: { Label("朗读设置", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.plain).font(.caption)
            }
        }.padding(.horizontal, 17).padding(.vertical, 17)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filteredLibrary: [LibraryEntry] {
        let query = libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.libraryEntries : model.libraryEntries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func libraryStatus(_ entry: LibraryEntry) -> String {
        if model.unavailableEntryIDs.contains(entry.id) { return "文件不可用 · 请重新定位" }
        guard let checkpoint = entry.checkpoint else { return "未开始" }
        if checkpoint.finished { return "已读完" }
        return "\(checkpoint.chapterTitle) · 全书 \(Int(entry.progress * 100))%"
    }

    private func libraryRow(_ entry: LibraryEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button { Task { await model.openLibraryEntry(entry.id) } } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Label(entry.name, systemImage: model.unavailableEntryIDs.contains(entry.id) ? "doc.badge.ellipsis" : "doc.text")
                        .font(.system(size: 13, weight: .medium)).lineLimit(2)
                    Text(libraryStatus(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let date = entry.lastReadAt {
                        Text("上次阅读 \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(entry.path).accessibilityIdentifier("library-\(entry.id)")
            Menu {
                Button("打开并恢复进度") { Task { await model.openLibraryEntry(entry.id) } }
                Button("重新定位文件…") { model.relocateLibraryEntry(entry.id) }
                if entry.sourceEncoding != nil {
                    Menu("文本编码") {
                        ForEach(TextEncoding.allCases) { encoding in
                            Button(encoding.label) { Task { await model.openLibraryEntry(entry.id, encoding: encoding) } }
                        }
                    }
                }
                if entry.convertedUTF8Path != nil { Button("显示 UTF-8 副本") { model.showConvertedCopy(entry) } }
                Divider()
                Button("从书架移除", role: .destructive) { model.removeLibraryEntry(entry.id) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("管理 \(entry.name)")
        }.padding(11)
            .background(model.currentLibraryID == entry.id ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contextMenu {
                Button("重新定位文件…") { model.relocateLibraryEntry(entry.id) }
                Button("从书架移除", role: .destructive) { model.removeLibraryEntry(entry.id) }
            }
    }

    private func rowBackground(_ id: Int) -> Color {
        model.selectedChapterID == id ? Color.accentColor.opacity(0.14) : Color.clear
    }

    private func sidebarMessage(_ message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.title2)
            Text(message).font(.callout).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var documentHeader: some View {
        HStack(spacing: 14) {
            Button { showsSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .help(showsSidebar ? "收起侧栏" : "展开侧栏").accessibilityLabel("切换侧栏")
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(model.hasText ? "\(model.characterCount.formatted()) 个字符 · \(model.chapters.count) 个章节" + (model.sourceEncodingLabel.map { " · \($0)" } ?? "") : "选择文件，或将文件拖到这里")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                showsSidebar = true
                sidebarTab = .search
                DispatchQueue.main.async { searchFocused = true }
            } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command).help("搜索全文（⌘F）").accessibilityLabel("搜索全文")
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .help("声音、语速和快捷键设置").accessibilityLabel("朗读设置")
        }.buttonStyle(.borderless).font(.system(size: 16))
            .padding(.horizontal, 24).padding(.vertical, 17)
    }

    private var chapterHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(model.currentChapter?.title ?? "全文").font(.system(size: 20, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 5)
                HStack(spacing: 10) {
                    Button { model.moveChapter(by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled((model.selectedChapterID ?? 0) == 0).help("上一章").accessibilityLabel("上一章")
                    Button { model.moveChapter(by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled((model.selectedChapterID ?? 0) + 1 >= model.chapters.count).help("下一章").accessibilityLabel("下一章")
                }.buttonStyle(.bordered).disabled(model.isLoading)
            }
            HStack {
                Text("\((model.selectedChapterID ?? 0) + 1) / \(model.chapters.count) · 读完自动进入下一章")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("跟随朗读", isOn: $model.followsReading).toggleStyle(.switch).controlSize(.small).font(.caption)
            }
        }.padding(.horizontal, 28).padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.pages").font(.system(size: 45, weight: .light)).foregroundStyle(.tint)
                .frame(width: 92, height: 92).background(Color.accentColor.opacity(0.08), in: Circle())
            Text("阅读，也可以用听的。").font(.system(size: 25, weight: .medium))
            Text("添加文件到书架，下次打开继续阅读。\n按章节朗读，搜索你想听的那一段。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            HStack(spacing: 12) {
                Button("选择文件…", action: model.openPanel)
                Button("试读示例", action: model.openExample)
            }.controlSize(.large).buttonStyle(.bordered)
            Text("TXT · Markdown · RTF · HTML · DOCX · PDF").font(.caption).foregroundStyle(.tertiary)
        }.padding(35)
    }

    private var playbackBar: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Text("本章").font(.caption).foregroundStyle(.secondary)
                Slider(value: $seekValue, in: 0...1, onEditingChanged: { editing in
                    isSeeking = editing
                    if !editing { model.seekInChapter(to: seekValue) }
                }).disabled(!model.hasText || model.isLoading).accessibilityLabel("本章朗读进度")
                Text("\(Int((isSeeking ? seekValue : model.chapterProgress) * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Button(action: model.restartChapter) { Image(systemName: "backward.end.fill").frame(width: 24, height: 24) }
                    .help("回到本章开头").accessibilityLabel("回到本章开头")
                Button(action: model.togglePlayback) {
                    Label(model.isPlaying ? "暂停" : (model.state == .paused || model.resumeMarkerOffset != nil) ? "继续朗读" : model.state == .finished ? "重新开始" : "开始朗读",
                          systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(minWidth: 105).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button(action: model.stop) { Image(systemName: "stop.fill").frame(width: 24, height: 24) }
                    .help("停止并保留当前位置").accessibilityLabel("停止朗读")
                Spacer(minLength: 4)
                Button { model.readFromSelection(model.selectionOffset) } label: { Label("从选中处朗读", systemImage: "text.cursor") }
                    .help("先点击或选中文本，再从该位置开始朗读")
            }.buttonStyle(.bordered).disabled(!model.hasText || model.isLoading)
            HStack {
                Text(model.state.rawValue)
                Text("· \(model.shortcut.display)").font(.system(.caption, design: .monospaced))
                Spacer()
                Text("全书 \(Int(model.progress * 100))%")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 26).padding(.vertical, 17)
    }
}
