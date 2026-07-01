import Foundation

enum SensitiveLogRedactor {
    private struct Rule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let rules: [Rule] = [
        makeRule(#"(?i)\b(Authorization\s*:\s*Bearer\s+)[^\s"',\r\n]+"#, "$1[REDACTED]"),
        makeRule(#"(?i)\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}"#, "$1[REDACTED]"),
        makeRule(#"(?i)(["'](?:access_token|refresh_token|id_token|api[_-]?key|apikey|authorization|token)["']\s*:\s*["'])[^"']+(["'])"#, "$1[REDACTED]$2"),
        makeRule(#"(?i)\b(access_token|refresh_token|id_token|api[_-]?key|apikey|token)=([^&\s"',]+)"#, "$1=[REDACTED]"),
        makeRule(#"\bsk-[A-Za-z0-9_-]{16,}\b"#, "[REDACTED]"),
        makeRule(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[REDACTED]"),
    ]

    static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var output = input
        for rule in rules {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = rule.regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: range,
                withTemplate: rule.template
            )
        }
        return output
    }

    static func contentSummary(_ input: String) -> String {
        let words = input.split(whereSeparator: { $0.isWhitespace }).count
        let lines = input.isEmpty ? 0 : input.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).count
        return "chars=\(input.count) words=\(words) lines=\(lines)"
    }

    private static func makeRule(_ pattern: String, _ template: String) -> Rule {
        // Patterns are static and covered by tests; fail closed in release.
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        return Rule(regex: regex, template: template)
    }
}
