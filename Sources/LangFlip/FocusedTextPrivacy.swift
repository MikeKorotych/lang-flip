import ApplicationServices
import Foundation

enum FocusedTextPrivacy {
    static func isSensitive(role: String?, subrole: String?, labels: [String]) -> Bool {
        if subrole == (kAXSecureTextFieldSubrole as String) { return true }
        if role?.localizedCaseInsensitiveContains("secure") == true { return true }
        if subrole?.localizedCaseInsensitiveContains("secure") == true { return true }

        return labels.contains { label in
            let normalized = label
                .lowercased()
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")

            return normalized.contains("password")
                || normalized.contains("passcode")
                || normalized.contains("one time code")
                || normalized.contains("2fa")
                || normalized.contains("two factor")
                || normalized.contains("auth code")
                || normalized.contains("api key")
                || normalized.contains("secret")
                || normalized.contains("token")
                || normalized.contains("private key")
        }
    }

    static func isSensitive(element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let labels = [
            stringAttribute(kAXTitleAttribute, from: element),
            stringAttribute(kAXDescriptionAttribute, from: element),
            stringAttribute(kAXHelpAttribute, from: element),
            stringAttribute(kAXPlaceholderValueAttribute, from: element),
            stringAttribute(kAXIdentifierAttribute, from: element),
        ].compactMap { $0 }

        return isSensitive(role: role, subrole: subrole, labels: labels)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        return value
    }
}
