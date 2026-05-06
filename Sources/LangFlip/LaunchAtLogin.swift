import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp so SwiftUI views can flip launch-at-login
/// without each importing ServiceManagement and worrying about errors.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Try to set the desired state. Logs the failure mode to stderr if
    /// macOS rejects the request — typical reasons are the user denying
    /// the system prompt, or the .app being run from a non-standard
    /// location (Gatekeeper requires it under /Applications or
    /// ~/Applications for the registration to take effect).
    static func set(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data(
                "lang-flip: launch-at-login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}
