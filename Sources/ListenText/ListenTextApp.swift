import SwiftUI
import AppKit
import AVFoundation

@main
struct ListenTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ReaderModel()
    @State private var startedVerification = false

    var body: some Scene {
        Window("听文", id: "reader") {
            ContentView(model: model)
                .onAppear {
                    delegate.model = model
                    let arguments = CommandLine.arguments
                    if let index = arguments.firstIndex(of: "--verify"), arguments.count > index + 1, !startedVerification {
                        startedVerification = true
                        let bookURL: URL?
                        if let bookIndex = arguments.firstIndex(of: "--verify-book"), arguments.count > bookIndex + 1 {
                            bookURL = URL(fileURLWithPath: arguments[bookIndex + 1])
                        } else { bookURL = nil }
                        Task { await AppVerification.run(model: model, reportURL: URL(fileURLWithPath: arguments[index + 1]), bookURL: bookURL) }
                    }
                }
                .onOpenURL { url in Task { await model.load(url) } }
        }
        .defaultSize(width: 1120, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文本文件…", action: model.openPanel).keyboardShortcut("o")
            }
            CommandMenu("朗读") {
                Button(model.isPlaying ? "暂停" : "播放 / 继续", action: model.togglePlayback)
                    .disabled(!model.hasText)
                Button("停止", action: model.stop).disabled(!model.hasText)
                Button("回到开头", action: model.restart).disabled(!model.hasText)
                Divider()
                Button("设置全局快捷键…") { model.showShortcutSheet = true }
            }
        }
        MenuBarExtra("听文", systemImage: model.isPlaying ? "waveform" : "book.closed") {
            ReaderMenu(model: model)
        }
    }
}

private struct ReaderMenu: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.hasText ? model.title : "听文 · 文本朗读")
        Text("\(model.state.rawValue) · \(Int(model.progress * 100))%")
        Divider()
        Button("\(model.isPlaying ? "暂停" : "播放 / 继续")  \(model.shortcut.display)", action: model.togglePlayback)
            .disabled(!model.hasText || model.isLoading)
        Button("停止", action: model.stop).disabled(!model.hasText)
        Divider()
        Button("显示主窗口") { openWindow(id: "reader"); NSApp.activate(ignoringOtherApps: true) }
        Button("打开文件…") { openWindow(id: "reader"); NSApp.activate(ignoringOtherApps: true); model.openPanel() }
        Divider()
        Button("退出听文") { NSApp.terminate(nil) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ReaderModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
}
