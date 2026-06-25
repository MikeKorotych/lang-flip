import Carbon.HIToolbox
import CoreGraphics
import Foundation

final class DictationCorrectionLearner {
    static let shared = DictationCorrectionLearner()

    private static let captureDelay: TimeInterval = 0.35
    private static let watchWindow: TimeInterval = 45
    private static let editDebounce: TimeInterval = 1.2
    private static let maxLearnedPhraseWords = 4

    private struct Pending {
        let originalText: String
        var baselineValue: String
        var insertedRange: NSRange
        let appBundleID: String?
        let expiresAt: Date
        var debounce: DispatchWorkItem?
    }

    private var pending: Pending?

    private init() {}

    func recordInsertion(
        text: String,
        beforeContext: FocusedTextReader.Context?,
        appBundleID: String?
    ) {
        let inserted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard inserted.count >= 2 else { return }

        pending?.debounce?.cancel()
        pending = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.captureDelay) { [weak self] in
            guard let self else { return }
            guard let context = FocusedTextReader.current(),
                  let range = Self.insertedRange(
                    inserted,
                    in: context.value,
                    cursor: context.selectedRange.location,
                    beforeContext: beforeContext
                  )
            else { return }

            self.pending = Pending(
                originalText: inserted,
                baselineValue: context.value,
                insertedRange: range,
                appBundleID: appBundleID,
                expiresAt: Date().addingTimeInterval(Self.watchWindow),
                debounce: nil
            )
        }
    }

    func noteUserKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard var p = pending else { return }
        guard Date() <= p.expiresAt else {
            pending = nil
            return
        }

        let isDelete = keyCode == CGKeyCode(kVK_Delete) || keyCode == CGKeyCode(kVK_ForwardDelete)
        let commandLike = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        guard isDelete || !commandLike else { return }

        p.debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.evaluatePendingCorrection()
        }
        p.debounce = work
        pending = p
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.editDebounce, execute: work)
    }

    private func evaluatePendingCorrection() {
        guard var p = pending else { return }
        p.debounce?.cancel()
        p.debounce = nil
        pending = p

        guard Date() <= p.expiresAt else {
            pending = nil
            return
        }
        if let expectedBundle = p.appBundleID,
           let currentBundle = AppContext.frontmostBundleID(),
           expectedBundle != currentBundle {
            return
        }
        guard let context = FocusedTextReader.current(),
              context.value != p.baselineValue,
              let changed = Self.changedRanges(from: p.baselineValue, to: context.value)
        else { return }

        let baselineExpanded = Self.expandedTermRange(changed.old, in: p.baselineValue)
        guard baselineExpanded.length > 0,
              NSIntersectionRange(baselineExpanded, p.insertedRange).length > 0
        else { return }

        let currentExpanded = Self.expandedTermRange(changed.new, in: context.value)
        let original = Self.substring(p.baselineValue, range: baselineExpanded)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = Self.substring(context.value, range: currentExpanded)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.shouldLearn(original: original, corrected: corrected) else { return }
        PersonalDictionaryStore.shared.addAutomatic(canonical: corrected, variant: original)

        p.baselineValue = context.value
        p.insertedRange = Self.shiftedRangeAfterLearning(
            previous: p.insertedRange,
            learnedOldRange: baselineExpanded,
            learnedNewRange: currentExpanded
        )
        pending = p
    }

    private static func insertedRange(
        _ inserted: String,
        in value: String,
        cursor: Int,
        beforeContext: FocusedTextReader.Context?
    ) -> NSRange? {
        let ns = value as NSString
        let insertedLength = (inserted as NSString).length

        if let beforeContext {
            let start = beforeContext.selectedRange.location
            if start >= 0, start + insertedLength <= ns.length,
               ns.substring(with: NSRange(location: start, length: insertedLength)) == inserted {
                return NSRange(location: start, length: insertedLength)
            }
        }

        var best: NSRange?
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.length > 0 {
            let range = ns.range(of: inserted, options: [], range: searchRange)
            guard range.location != NSNotFound else { break }
            if best == nil {
                best = range
            } else {
                let currentDistance = abs((best!.location + best!.length) - cursor)
                let nextDistance = abs((range.location + range.length) - cursor)
                if nextDistance < currentDistance {
                    best = range
                }
            }
            let nextLocation = range.location + max(range.length, 1)
            guard nextLocation < ns.length else { break }
            searchRange = NSRange(location: nextLocation, length: ns.length - nextLocation)
        }
        return best
    }

    private static func changedRanges(from old: String, to new: String) -> (old: NSRange, new: NSRange)? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < oldUnits.count,
              prefix < newUnits.count,
              oldUnits[prefix] == newUnits[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix + prefix < oldUnits.count,
              suffix + prefix < newUnits.count,
              oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
            suffix += 1
        }

        let oldLength = oldUnits.count - prefix - suffix
        let newLength = newUnits.count - prefix - suffix
        guard oldLength > 0 || newLength > 0 else { return nil }
        return (
            NSRange(location: prefix, length: max(0, oldLength)),
            NSRange(location: prefix, length: max(0, newLength))
        )
    }

    private static func expandedTermRange(_ range: NSRange, in value: String) -> NSRange {
        let ns = value as NSString
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        var start = min(max(range.location, 0), ns.length)
        var end = min(max(range.location + range.length, start), ns.length)

        if range.length == 0 {
            return range
        }

        while start > 0, isTermScalar(ns.character(at: start - 1)) {
            start -= 1
        }
        while end < ns.length, isTermScalar(ns.character(at: end)) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private static func shouldLearn(original: String, corrected: String) -> Bool {
        guard original != corrected else { return false }
        guard original.count >= 2, corrected.count >= 2 else { return false }
        guard original.count <= 80, corrected.count <= 80 else { return false }
        guard original.rangeOfCharacter(from: .letters) != nil,
              corrected.rangeOfCharacter(from: .letters) != nil else { return false }
        guard !original.contains("\n"), !corrected.contains("\n") else { return false }
        guard wordCount(original) <= maxLearnedPhraseWords,
              wordCount(corrected) <= maxLearnedPhraseWords else { return false }

        let lowerChanged = original.lowercased() != corrected.lowercased()
        let spellingSignal = corrected.contains(where: { $0.isUppercase || $0.isNumber })
            || corrected.contains("-")
            || corrected.contains(".")
            || corrected.contains("_")
        return lowerChanged || spellingSignal
    }

    private static func shiftedRangeAfterLearning(
        previous: NSRange,
        learnedOldRange: NSRange,
        learnedNewRange: NSRange
    ) -> NSRange {
        let delta = learnedNewRange.length - learnedOldRange.length
        if learnedOldRange.location + learnedOldRange.length <= previous.location {
            return NSRange(location: max(0, previous.location + delta), length: previous.length)
        }
        if NSIntersectionRange(previous, learnedOldRange).length > 0 {
            return NSRange(location: previous.location, length: max(0, previous.length + delta))
        }
        return previous
    }

    private static func substring(_ value: String, range: NSRange) -> String {
        let ns = value as NSString
        guard range.location >= 0,
              range.location + range.length <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    private static func wordCount(_ value: String) -> Int {
        value.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func isTermScalar(_ unit: unichar) -> Bool {
        if unit == 45 || unit == 46 || unit == 95 || unit == 39 { return true }
        guard let scalar = UnicodeScalar(Int(unit)) else { return false }
        return CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
    }
}
