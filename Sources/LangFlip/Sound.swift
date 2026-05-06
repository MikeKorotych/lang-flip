import AppKit

/// Tiny audio feedback when the app physically rewrites text. Off by default
/// (many users find click sounds intrusive) — opt in via the menubar.
///
/// Uses macOS built-in system sounds so we ship no audio assets. "Pop" is
/// short and unobtrusive; if a future version wants a custom sound, this is
/// the only file that needs to change.
enum Sound {
    private static let flipSound = NSSound(named: "Pop")

    /// Play the "we just changed your text" tick. No-op if the user has
    /// disabled sound, or if the system sound failed to load.
    static func playFlip() {
        guard Settings.shared.soundEnabled else { return }
        guard let sound = flipSound else { return }

        let fire = {
            sound.stop()
            sound.play()
        }
        if Thread.isMainThread {
            fire()
        } else {
            DispatchQueue.main.async(execute: fire)
        }
    }
}
