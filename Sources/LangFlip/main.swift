import Foundation
import AppKit

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else {
    FileHandle.standardError.write(Data("lang-flip: Accessibility permission not granted yet. Approve in System Settings → Privacy & Security → Accessibility, then re-run.\n".utf8))
    exit(1)
}

let tap = EventTap()
do {
    try tap.start()
} catch {
    FileHandle.standardError.write(Data("lang-flip: \(error.localizedDescription)\n".utf8))
    exit(1)
}

print("lang-flip: running. Hotkey: ⌃⌥⌘\\ converts the last word.")
CFRunLoopRun()
