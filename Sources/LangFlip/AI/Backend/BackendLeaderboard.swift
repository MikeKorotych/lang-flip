import Foundation

// Team leaderboard contract (spec §5.5). The server aggregates per-user
// activity from the metering log and returns ranked daily + weekly boards for
// the caller's corporate domain. Only corporate (@uni.tech) accounts may call
// it; everyone else gets `403 { code: "bad_request" }`.

/// One player on a board. `words`/`dictations` are the aggregated totals for
/// the board's period; `streakDays` counts consecutive active days up to today
/// (UTC). The server never returns raw emails of teammates — `name` is the
/// display name (or the email local-part as a fallback, chosen server-side).
struct BackendLeaderboardPlayer: Codable, Equatable {
    let id: String
    let name: String
    let words: Int
    let dictations: Int
    let streakDays: Int
}

struct BackendLeaderboardResponse: Codable, Equatable {
    let daily: [BackendLeaderboardPlayer]
    let weekly: [BackendLeaderboardPlayer]
    let generatedAt: Date
}
