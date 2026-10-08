import SwiftUI
import AppKit

struct ReaderTextView: NSViewRepresentable {
    let text: String
    let textID: UUID
    let highlightedRange: NSRange
    let searchRanges: [NSRange]
    let focusRequest: TextFocusRequest?
    let followsReading: Bool
    let onSelection: (Int) -> Void
    let onReadFrom: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let view = ReadingTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.setAccessibilityIdentifier("chapter-text")
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 30, height: 26)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.readFrom = onReadFrom
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ReadingTextView else { return }
        context.coordinator.parent = self
        view.readFrom = onReadFrom
        if context.coordinator.textID != textID {
            view.string = text
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 8
            view.textStorage?.addAttributes([
                .font: NSFont.systemFont(ofSize: 17),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style
            ], range: NSRange(location: 0, length: (text as NSString).length))
            context.coordinator.lastHighlight = NSRange(location: 0, length: 0)
            context.coordinator.searchRanges = []
            context.coordinator.lastFocusID = nil
            context.coordinator.textID = textID
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.scrollToBeginningOfDocument(nil)
        }
        let length = view.textStorage?.length ?? 0
        let searchChanged = context.coordinator.searchRanges != searchRanges
        if searchChanged {
            view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            for range in searchRanges where NSMaxRange(range) <= length {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.42), forCharacterRange: range)
            }
            context.coordinator.searchRanges = searchRanges
        }
        let readingChanged = context.coordinator.lastHighlight != highlightedRange
        if readingChanged || searchChanged {
            let previous = context.coordinator.lastHighlight
            if !searchChanged, NSMaxRange(previous) <= length {
                view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: previous)
                for range in searchRanges where NSIntersectionRange(range, previous).length > 0 && NSMaxRange(range) <= length {
                    view.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.42), forCharacterRange: range)
                }
            }
            if highlightedRange.length > 0, NSMaxRange(highlightedRange) <= length {
                view.layoutManager?.addTemporaryAttribute(.backgroundColor,
                    value: NSColor.systemTeal.withAlphaComponent(0.23), forCharacterRange: highlightedRange)
                if followsReading && readingChanged { view.scrollRangeToVisible(highlightedRange) }
            }
            context.coordinator.lastHighlight = highlightedRange
        }
        if context.coordinator.lastFocusID != focusRequest?.id {
            if let request = focusRequest, NSMaxRange(request.range) <= length {
                view.setSelectedRange(NSRange(location: request.range.location, length: 0))
                view.scrollRangeToVisible(request.range)
            }
            context.coordinator.lastFocusID = focusRequest?.id
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReaderTextView
        var lastHighlight = NSRange(location: 0, length: 0)
        var searchRanges: [NSRange] = []
        var textID: UUID?
        var lastFocusID: UUID?
        init(_ parent: ReaderTextView) { self.parent = parent }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let offset = view.selectedRange().location
            let callback = parent.onSelection
            DispatchQueue.main.async { callback(offset) }
        }
    }
}

final class ReadingTextView: NSTextView {
    var readFrom: ((Int) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let item = NSMenuItem(title: "从选中处开始朗读", action: #selector(speakFromSelection), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func speakFromSelection() { readFrom?(selectedRange().location) }
}
