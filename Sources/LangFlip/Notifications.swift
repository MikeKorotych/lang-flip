import Foundation

extension Notification.Name {
    /// Posted whenever Settings.enabled flips from any code path other than
    /// the menubar's own toggle (so the menubar can refresh its icon and
    /// menu state). Currently only the both-Shifts gesture posts this.
    static let langFlipEnabledChanged = Notification.Name("LangFlipEnabledChanged")

    /// Posted after user-installed dictionaries are downloaded, replaced,
    /// or reset, so the in-memory auto-flip engine can reload without
    /// requiring an app restart.
    static let langFlipDictionariesChanged = Notification.Name("LangFlipDictionariesChanged")

    /// Posted by AutoFlip after the background dictionary load finishes
    /// (initial startup and every subsequent reload). UI surfaces that
    /// display word counts (Preferences > Languages) listen for this to
    /// refresh without polling.
    static let langFlipDictionariesReloaded = Notification.Name("LangFlipDictionariesReloaded")

    /// Posted when the voice recorder starts, stops, or fails so
    /// Preferences can refresh without polling tight loops.
    static let langFlipVoiceRecorderChanged = Notification.Name("LangFlipVoiceRecorderChanged")

    /// Posted whenever the dictation controller changes state
    /// (idle ↔ recording ↔ transcribing). Drives the floating dictation
    /// island so it reacts instantly instead of polling tightly.
    static let langFlipDictationStateChanged = Notification.Name("LangFlipDictationStateChanged")

    /// Posted when an in-progress dictation is cancelled (discarded without
    /// transcribing). The island shows a "Transcript cancelled" toast.
    static let langFlipDictationCancelled = Notification.Name("LangFlipDictationCancelled")
}
