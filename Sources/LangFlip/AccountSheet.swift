import AppKit
import SwiftUI

/// "Manage account" modal, opened from the title-bar profile popover. Mirrors the
/// Wispr Flow account panel — name, email, avatar, plan/quota, and the
/// destructive sign-out / delete actions.
///
/// Backend note: the `/me` endpoint only returns email/role/quota today, so the
/// first/last name and avatar are stored locally (Settings + a copied image)
/// until WS1 adds profile + avatar + delete endpoints. Save persists those
/// locally; Delete signs out and clears local data (server-side account deletion
/// needs the backend endpoint).
struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var auth = SupabaseBackendAuth.shared

    @State private var firstName = Settings.shared.accountFirstName
    @State private var lastName = Settings.shared.accountLastName
    @State private var avatar: NSImage? = AccountSheet.loadAvatar()
    @State private var avatarPath = Settings.shared.accountAvatarPath
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DisplayText("Account", size: 26)

            Divider().overlay(FlowTheme.cardStroke)

            FlowCard(padding: 20) {
                VStack(spacing: 0) {
                    fieldRow("First name") {
                        FlowTextField(placeholder: "First name", text: $firstName)
                            .frame(width: 240)
                    }
                    rowDivider
                    fieldRow("Last name") {
                        FlowTextField(placeholder: "Last name", text: $lastName)
                            .frame(width: 240)
                    }
                    rowDivider
                    fieldRow("Email") {
                        Text(auth.currentUser?.email ?? "Not signed in")
                            .font(.system(size: 14))
                            .foregroundColor(FlowTheme.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    rowDivider
                    if let user = auth.currentUser {
                        fieldRow("Plan") {
                            Text(user.role == .corporate ? "Corporate" : "Free")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(FlowTheme.accent)
                        }
                        rowDivider
                    }
                    fieldRow("Profile picture") {
                        HStack(spacing: 10) {
                            avatarView
                            FlowSmallButton(title: "Change") { chooseAvatar() }
                            if avatar != nil {
                                FlowSmallButton(title: "Remove") { clearAvatar() }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                FlowSmallButton(title: "Sign out") {
                    auth.signOut()
                    dismiss()
                }
                Button("Delete account") { confirmingDelete = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red.opacity(0.85))

                Spacer()

                FlowSmallButton(title: "Cancel") { dismiss() }
                FlowSmallButton(title: "Save", prominent: true) { save() }
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(FlowTheme.paper)
        .confirmationDialog("Delete account?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This signs you out and removes Sayful's saved profile from this Mac. To permanently delete your Sayful Cloud account and data, contact support — full account deletion isn't available in-app yet.")
        }
    }

    private var rowDivider: some View {
        Divider().overlay(FlowTheme.cardStroke).padding(.vertical, 14)
    }

    private func fieldRow<Trailing: View>(_ label: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FlowTheme.ink)
            Spacer(minLength: 16)
            trailing()
        }
    }

    private var avatarView: some View {
        Group {
            if let avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(FlowTheme.inkSecondary.opacity(0.5))
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private func save() {
        Settings.shared.accountFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.accountLastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.accountAvatarPath = avatarPath
        dismiss()
    }

    private func deleteAccount() {
        auth.signOut()
        clearAvatar()
        Settings.shared.accountFirstName = ""
        Settings.shared.accountLastName = ""
        dismiss()
    }

    private func chooseAvatar() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        if let saved = Self.persistAvatar(from: url) {
            avatarPath = saved
            avatar = image
        }
    }

    private func clearAvatar() {
        if !avatarPath.isEmpty {
            try? FileManager.default.removeItem(atPath: avatarPath)
        }
        avatarPath = ""
        avatar = nil
        Settings.shared.accountAvatarPath = ""
    }

    private static func avatarURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Sayful", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("avatar.png")
    }

    /// Copy the chosen image into Application Support as a PNG and return its path.
    private static func persistAvatar(from source: URL) -> String? {
        guard let dest = avatarURL(),
              let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: dest, options: .atomic)
            return dest.path
        } catch {
            return nil
        }
    }

    private static func loadAvatar() -> NSImage? {
        let path = Settings.shared.accountAvatarPath
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
