import SwiftUI

/// Account / sign-in row for `.backend` (Sayful Cloud) mode. Lives in the AI
/// settings section. Shows the signed-in user + weekly quota, or a Google
/// sign-in button.
struct BackendAccountView: View {
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let user = auth.currentUser {
                row("Signed in", user.email)
                row("Plan", user.role == .corporate ? "Corporate" : "Free")
                row("This week", "\(user.quota.used) / \(user.quota.limit) words")
                Button("Sign out") { auth.signOut() }
                    .controlSize(.small)
            } else if auth.isSignedIn {
                HStack {
                    Text("Signed in")
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Refresh") { load() }.controlSize(.small)
                }
            } else {
                Button(working ? "Signing in…" : "Sign in with Google") { signIn() }
                    .disabled(working)
            }

            if let error {
                Text(error).font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { if auth.isSignedIn && auth.currentUser == nil { load() } }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary).lineLimit(1) }
    }

    private func signIn() {
        working = true; error = nil
        Task { @MainActor in
            defer { working = false }
            do { _ = try await auth.signIn() }
            catch { self.error = (error as? BackendError)?.message ?? error.localizedDescription }
        }
    }

    private func load() {
        working = true; error = nil
        Task { @MainActor in
            defer { working = false }
            do { _ = try await auth.refreshUser() }
            catch { self.error = (error as? BackendError)?.message ?? error.localizedDescription }
        }
    }
}
