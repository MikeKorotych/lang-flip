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
