import ApplicationServices
import Foundation

enum FocusedTextReader {
    struct Context {
        let value: String
        let selectedRange: CFRange
    }

    static func current() -> Context? {
        guard let element = focusedElement() else { return nil }
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

    static func hasFocusedTextInput() -> Bool {
        guard let element = focusedElement(),
              !FocusedTextPrivacy.isSensitive(element: element)
        else { return false }

        return isLikelyTextInput(
            role: stringAttribute(kAXRoleAttribute, from: element),
            subrole: stringAttribute(kAXSubroleAttribute, from: element),
            hasSelectedTextRange: hasSelectedTextRange(element),
            hasSettableValue: hasSettableValue(element)
        )
    }

    static func isLikelyTextInput(
        role: String?,
        subrole: String?,
        hasSelectedTextRange: Bool,
        hasSettableValue: Bool
    ) -> Bool {
        let normalizedRole = role ?? ""
        let normalizedSubrole = subrole ?? ""

        if normalizedRole == "AXTextField"
            || normalizedRole == "AXTextArea"
            || normalizedRole == "AXComboBox" {
            return true
        }

        if normalizedSubrole.localizedCaseInsensitiveContains("search") {
            return true
        }

        if hasSelectedTextRange {
            return normalizedRole.localizedCaseInsensitiveContains("text")
                || normalizedRole == "AXWebArea"
                || hasSettableValue
        }

        return false
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success, let focusedRef else {
            return nil
        }

        return (focusedRef as! AXUIElement)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        return value
    }

    private static func hasSelectedTextRange(_ element: AXUIElement) -> Bool {
        var rangeRef: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success && rangeRef != nil
    }

    private static func hasSettableValue(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }
}
