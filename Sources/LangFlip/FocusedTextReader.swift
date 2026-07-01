import ApplicationServices
import Foundation

enum FocusedTextReader {
    struct Context {
        let value: String
        let selectedRange: CFRange
    }

    static func current() -> Context? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }

        let element = focusedRef as! AXUIElement
        guard !FocusedTextPrivacy.isSensitive(element: element) else {
            return nil
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else {
            return nil
        }

        var range = CFRange(location: value.utf16.count, length: 0)
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef,
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue((rangeRef as! AXValue), .cfRange, &selected) {
                range = selected
            }
        }

        range.location = max(0, min(range.location, value.utf16.count))
        range.length = max(0, min(range.length, value.utf16.count - range.location))
        return Context(value: value, selectedRange: range)
    }
}
