import Combine
import Foundation

/// One in-app notification surfaced through the title-bar bell. Identified by a
/// stable `id` so re-posting (e.g. a recurring quota warning) updates in place
/// instead of stacking duplicates.
struct AppNotification: Identifiable, Equatable {
    enum Kind { case info, warning, update }
    let id: String
    let kind: Kind
    let title: String
    let body: String
    let date: Date
    var read: Bool = false

    var icon: String {
        switch kind {
        case .info:    return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .update:  return "arrow.down.circle"
        }
    }
}

/// Lightweight, local notification center behind the bell. No backend — it
/// surfaces things the app already knows: an available update (Sparkle), the
/// weekly quota approaching its limit, and ad-hoc notices other code posts.
@MainActor
final class AppNotifications: ObservableObject {
    static let shared = AppNotifications()

    @Published private(set) var items: [AppNotification] = []
    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Quota source: watch the signed-in user and warn once the weekly
        // allowance is ~80% spent (and again when it's fully spent).
        SupabaseBackendAuth.shared.$currentUser
            .sink { [weak self] user in self?.evaluateQuota(user) }
            .store(in: &cancellables)
    }

    /// Post or refresh a notification. Same `id` → updated in place (and marked
    /// unread again) rather than duplicated.
    func post(id: String, kind: AppNotification.Kind, title: String, body: String, date: Date = Date()) {
        let note = AppNotification(id: id, kind: kind, title: title, body: body, date: date)
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx] = note
        } else {
            items.insert(note, at: 0)
        }
    }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        items = items.map { var n = $0; n.read = true; return n }
    }

    func remove(_ id: String) { items.removeAll { $0.id == id } }
    func clear() { items.removeAll() }

    private func evaluateQuota(_ user: BackendUser?) {
        guard let q = user?.quota, q.limit > 0 else { return }
        let fraction = Double(q.used) / Double(q.limit)
        if q.used >= q.limit {
            post(id: "quota", kind: .warning,
                 title: "Weekly limit reached",
                 body: "You've used all \(q.limit) words this week. It resets at the start of next week.")
        } else if fraction >= 0.8 {
            post(id: "quota", kind: .warning,
                 title: "Approaching weekly limit",
                 body: "\(q.used) of \(q.limit) words used this week.")
        } else {
            // Back under the threshold (new week / corporate bump) — drop the warning.
            remove("quota")
        }
    }
}
