import AppKit
import Combine
import Foundation

/// Auto-fills the local account profile (first/last name + avatar) from the
/// Google sign-in. Supabase puts the Google identity into the access token's
/// `user_metadata` claim (full_name / given_name / family_name / avatar_url),
/// so we decode the stored JWT client-side — no backend change needed.
///
/// Only fills empty fields, so a user's manual edits in the Manage Account
/// modal are never clobbered. Runs on launch and whenever sign-in state flips.
@MainActor
final class AccountProfileSync {
    static let shared = AccountProfileSync()

    private var cancellables = Set<AnyCancellable>()
    private var didSync = false

    private init() {}

    func start() {
        SupabaseBackendAuth.shared.$currentUser
            .sink { [weak self] user in
                if user != nil {
                    self?.syncIfNeeded()
                } else {
                    // Signed out — re-arm so the next sign-in (possibly a
                    // different account) syncs its profile again.
                    self?.didSync = false
                }
            }
            .store(in: &cancellables)
        // Already signed in from a previous launch? The token is on disk before
        // /me resolves, so we can fill names/avatar immediately.
        if SupabaseBackendAuth.hasStoredSession { syncIfNeeded() }
    }

    private func syncIfNeeded() {
        guard !didSync else { return }
        guard let token = KeychainStore.getString(account: KeychainStore.backendAccessToken),
              let meta = Self.userMetadata(fromJWT: token) else { return }
        didSync = true

        if Settings.shared.accountFirstName.isEmpty && Settings.shared.accountLastName.isEmpty {
            let (first, last) = Self.splitName(meta)
            if !first.isEmpty { Settings.shared.accountFirstName = first }
            if !last.isEmpty { Settings.shared.accountLastName = last }
        }

        if Settings.shared.accountAvatarPath.isEmpty,
           let urlString = (meta["avatar_url"] ?? meta["picture"]) as? String,
           let url = URL(string: urlString) {
            downloadAvatar(url)
        }
    }

    // MARK: - Name

    private static func splitName(_ meta: [String: Any]) -> (first: String, last: String) {
        if let given = (meta["given_name"] as? String)?.trimmed, !given.isEmpty {
            let family = (meta["family_name"] as? String)?.trimmed ?? ""
            return (given, family)
        }
        let full = ((meta["full_name"] ?? meta["name"]) as? String)?.trimmed ?? ""
        guard !full.isEmpty else { return ("", "") }
        let parts = full.split(separator: " ", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    // MARK: - Avatar

    private func downloadAvatar(_ url: URL) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, NSImage(data: data) != nil else { return }
            let dest = Self.avatarFileURL()
            guard let dest else { return }
            // Re-encode to PNG so the on-disk file matches what the modal writes.
            let pngData: Data
            if let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                pngData = png
            } else {
                pngData = data
            }
            try? pngData.write(to: dest, options: .atomic)
            Task { @MainActor in
                // Only adopt it if the user still hasn't set their own avatar.
                if Settings.shared.accountAvatarPath.isEmpty {
                    Settings.shared.accountAvatarPath = dest.path
                }
            }
        }.resume()
    }

    nonisolated private static func avatarFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Sayful", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("avatar.png")
    }

    // MARK: - JWT

    /// Decode a JWT's `user_metadata` claim (no signature check — we only read
    /// non-sensitive profile fields the server already issued to us).
    private static func userMetadata(fromJWT jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var b64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["user_metadata"] as? [String: Any]
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
