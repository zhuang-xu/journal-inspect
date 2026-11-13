import AppKit
import SwiftUI

/// Native scrolling text handles large entries and selectable, formatted answers.
struct EntryTextView: NSViewRepresentable {
    enum Format {
        case plainText
        case markdown
    }

    let text: String
    var format: Format = .plainText
    var followsOutput = false

    final class Coordinator {
        var text: String?
        var format: Format?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isRichText = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.format != format else { return }

        let view = scroll.documentView as! NSTextView
        let wasAtBottom = view.visibleRect.maxY >= view.bounds.maxY - 24
        let isStarting = view.string.isEmpty
        let previousOrigin = scroll.contentView.bounds.origin
        view.textStorage?.setAttributedString(renderedText())
        coordinator.text = text
        coordinator.format = format

        if followsOutput && (wasAtBottom || isStarting) {
            view.scrollToEndOfDocument(nil)
        } else if !followsOutput {
            view.scrollToBeginningOfDocument(nil)
        } else {
            scroll.contentView.scroll(to: previousOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        (scroll.documentView as? NSTextView)?.string = ""
        coordinator.text = nil
    }

    private func renderedText() -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: 14)
        guard format == .markdown, let parsed = try? AttributedString(markdown: text) else {
            return NSAttributedString(string: text, attributes: [.font: bodyFont])
        }

        let output = NSMutableAttributedString()
        var previousBlock: Int?
        var previousGroup: Int?
        var previousItem: Int?
        var previousRow: Int?

        // Use the parser's block structure, but construct native attributes ourselves.
        // Model-produced links and images stay as text labels.
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first
            let group = components.first { component in
                switch component.kind {
                case .orderedList, .unorderedList, .blockQuote, .table: return true
                default: return false
                }
            }
            let item = components.first {
                if case .listItem = $0.kind { return true }
                return false
            }
            let row = components.first {
                switch $0.kind {
                case .tableHeaderRow, .tableRow: return true
                default: return false
                }
            }

            var font = bodyFont
            var prefix = ""
            if block?.identity != previousBlock {
                if output.length > 0 {
                    if let row, row.identity == previousRow {
                        prefix = "  |  "
                    } else {
                        prefix = group != nil && group?.identity == previousGroup ? "\n" : "\n\n"
                    }
                }
                if let item, item.identity != previousItem, case .listItem(let ordinal) = item.kind
                {
                    let depth = components.filter {
                        if case .listItem = $0.kind { return true }
                        return false
                    }.count
                    prefix += String(repeating: "    ", count: depth - 1)
                    if case .orderedList = group?.kind {
                        prefix += "\(ordinal). "
                    } else {
                        prefix += "• "
                    }
                } else if case .blockQuote = group?.kind {
                    prefix += "│ "
                }
            }

            switch block?.kind {
            case .header(let level):
                font = .systemFont(ofSize: max(15, 25 - CGFloat(level) * 2), weight: .semibold)
            case .codeBlock:
                font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            default:
                break
            }

            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            }
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if inline.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if !prefix.isEmpty {
                output.append(NSAttributedString(string: prefix, attributes: [.font: bodyFont]))
            }
            let content =
                inline.contains(.lineBreak) ? "\n" : String(parsed[run.range].characters)
            output.append(NSAttributedString(string: content, attributes: attributes))
            previousBlock = block?.identity
            previousGroup = group?.identity
            previousItem = item?.identity
            previousRow = row?.identity
        }
        return output
    }
}
