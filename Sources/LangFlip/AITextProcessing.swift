import Foundation

/// Shared "AI is processing the selected text" indicator. Drives the dictation
/// island's spinner during grammar fix / transform / translate — the same
/// visual the TTS buffering uses. Reference-counted (begin/end balanced) so
/// overlapping requests don't clear it early. Mutations hop to the main thread
/// since callers fire from background poll closures.
final class AITextProcessing {
    static let shared = AITextProcessing()

    private(set) var isActive = false
    private var count = 0

    private init() {}

    func begin() {
        DispatchQueue.main.async { [self] in
            count += 1
            update()
        }
    }

    func end() {
        DispatchQueue.main.async { [self] in
            if count > 0 { count -= 1 }
            update()
        }
    }

    private func update() {
        let active = count > 0
        guard active != isActive else { return }
        isActive = active
        // Reuses the island's processing signal (same spinner as TTS buffering).
        NotificationCenter.default.post(name: .langFlipTTSStateChanged, object: nil)
    }
}
