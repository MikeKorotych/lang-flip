import Foundation
import AppKit

/// Snapshot of pasteboard contents that can be restored later. Captures every
/// item and every type/data pair so we can put back arbitrary content (text,
/// rich text, images, files) after we hijack the clipboard for a copy/paste
/// round-trip.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pb: NSPasteboard = .general) -> PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pb: NSPasteboard = .general) {
        pb.clearContents()
        let restoredItems: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        if !restoredItems.isEmpty {
            pb.writeObjects(restoredItems)
        }
    }
}

enum TransientPasteboard {
    static let defaultRestoreDelay: TimeInterval = 0.30

    /// Temporarily places a string on the pasteboard for a synthesized paste,
    /// then restores the user's previous pasteboard if nothing else changed it.
    static func pasteString(
        _ string: String,
        to pb: NSPasteboard = .general,
        restoreAfter delay: TimeInterval = defaultRestoreDelay,
        restoreOriginalClipboard: Bool = true,
        paste: () -> Void
    ) {
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString(string, forType: .string)
        let transientChangeCount = pb.changeCount

        paste()

        guard restoreOriginalClipboard else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pb.changeCount == transientChangeCount else { return }
            snapshot.restore(to: pb)
        }
    }
}
