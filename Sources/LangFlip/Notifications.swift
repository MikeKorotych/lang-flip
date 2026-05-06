import Foundation

extension Notification.Name {
    /// Posted whenever Settings.enabled flips from any code path other than
    /// the menubar's own toggle (so the menubar can refresh its icon and
    /// menu state). Currently only the both-Shifts gesture posts this.
    static let langFlipEnabledChanged = Notification.Name("LangFlipEnabledChanged")
}
