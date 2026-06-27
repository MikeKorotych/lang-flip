import AppKit
import Sparkle

/// Thin wrapper around Sparkle's SPUStandardUpdaterController so the rest of
/// the app can talk to a single ObservableObject for the menubar's
/// "Check for Updates…" item and the Preferences "Update channel" toggles.
///
/// The actual update logic is all in Sparkle — feed URL and public key live
/// in Info.plist (SUFeedURL, SUPublicEDKey). The private signing key lives
/// in the maintainer's Keychain login keychain; `make release` invokes
/// Sparkle's sign_update tool to attach an `edSignature` to each release
/// DMG that the running app verifies against SUPublicEDKey before
/// installing.
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    private(set) var controller: SPUStandardUpdaterController!

    /// Display version of a found-but-not-yet-installed update, or nil. Drives the
    /// title-bar update button so an available update stays one click away.
    @Published private(set) var availableVersion: String?

    private override init() {
        super.init()
        // startingUpdater: true → kicks off the periodic check Sparkle is
        // configured for in Info.plist (SUScheduledCheckInterval).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// Hooked up to the menubar's "Check for Updates…" item. Sparkle handles
    /// the entire flow: fetch appcast, compare versions, prompt user with
    /// release notes, download, verify signatures (Apple notarization +
    /// Sparkle EdDSA), relaunch into the new version.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Silent appcast probe with no UI — used on launch to light up the title-bar
    /// update button. Calls back into `didFindValidUpdate` / `updaterDidNotFindUpdate`.
    func checkInBackground() {
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}

extension Updater: SPUUpdaterDelegate {
    /// Allow updates to install while the user is using the app — Sparkle
    /// will quit + relaunch us. If we ever ship a long-running operation
    /// users shouldn't lose, this is where we'd add a guard.
    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        return true
    }

    /// Filter pre-releases out of the standard channel. Future-proofs us if
    /// we ever publish dev / beta builds in a separate appcast lane.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        return [] // empty = stable channel only (the default)
    }

    /// Surface an available update through the in-app bell (alongside Sparkle's
    /// own prompt) so it stays discoverable even if the user dismisses the prompt.
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.availableVersion = version
            AppNotifications.shared.post(
                id: "update",
                kind: .update,
                title: "Update available",
                body: "Sayful \(version) is ready — click the update button in the header to install it."
            )
        }
    }

    /// Clear the title-bar indicator when a probe finds nothing new (e.g. after the
    /// user updated by other means).
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.availableVersion = nil }
    }
}
