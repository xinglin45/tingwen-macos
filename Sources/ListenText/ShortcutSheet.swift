import SwiftUI
import AppKit

struct ShortcutSheet: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: KeyboardShortcut?
    @State private var message = "请同时按下 Control、Option 或 Command 中的至少一个修饰键。"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("播放 / 暂停快捷键", systemImage: "keyboard")
                .font(.system(size: 21, weight: .semibold))
            Text("在任何 App 中按下这组快捷键，即可控制听文。应用需要保持运行，关闭主窗口后仍可使用。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.08))
                RoundedRectangle(cornerRadius: 14).stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                VStack(spacing: 8) {
                    Text(candidate?.display ?? "按下你的快捷键")
                        .font(.system(size: 27, weight: .medium, design: .rounded))
                    Text("当前：\(model.shortcut.display)").font(.caption).foregroundStyle(.secondary)
                }
                ShortcutCapture(onEvent: { event in
                    guard !event.isARepeat else { return }
                    if event.keyCode == 53 { dismiss(); return }
                    if let captured = KeyboardShortcut(event: event) {
                        candidate = captured
                        message = "点击保存后生效。若与其他应用冲突，请换一组组合键。"
                    } else {
                        message = "请加入 Control、Option 或 Command，避免影响正常打字。"
                    }
                })
            }.frame(height: 112)
            Text(message).font(.callout).foregroundStyle(.secondary).frame(minHeight: 36, alignment: .topLeading)
            HStack {
                Button("恢复默认") { candidate = .standard }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    guard let candidate else { return }
                    if model.saveShortcut(candidate) { dismiss() }
                    else { message = "这组快捷键已被系统或其他应用占用，请换一组后再保存。" }
                }.buttonStyle(.borderedProminent).disabled(candidate == nil)
            }
        }.padding(28).frame(width: 460)
        .onAppear { model.suspendShortcut() }
        .onDisappear { model.restoreShortcut() }
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    let onEvent: (NSEvent) -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onEvent = onEvent
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.onEvent = onEvent }

    final class CaptureView: NSView {
        var onEvent: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) { onEvent?(event) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool { onEvent?(event); return true }
    }
}
