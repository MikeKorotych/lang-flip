import SwiftUI

/// Corporate "Team" section — a gamified activity dashboard for @uni.tech
/// accounts: daily/weekly leaderboards (podium + ranked list), your XP/level
/// standing, and locally-earned achievement badges. Everything animates in with
/// the same staggered language as Insights; counters tick up, the podium grows,
/// badge tiles pop.
struct TeamDashboardView: View {
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @ObservedObject private var history = DictationHistory.shared
    @StateObject private var model = TeamDashboardModel()
    @State private var appeared = false
    @State private var period: TeamDashboardModel.Period = .daily

    var body: some View {
        // Defense in depth: the sidebar already hides this section, but the
        // content re-checks so a stale selection never leaks the dashboard.
        if !TeamAccess.isEligible(email: auth.currentUser?.email) {
            lockedCard
        } else {
            dashboard
        }
    }

    private var lockedCard: some View {
        FlowCard {
            HStack(spacing: 12) {
                Image(systemName: "lock").foregroundColor(FlowTheme.inkSecondary)
                Text("The Team dashboard is available to \(TeamAccess.requiredDomain) accounts.")
                    .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                DisplayText("Team", size: 26)
                Text(TeamAccess.requiredDomain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(FlowTheme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(FlowTheme.accentSoft))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                FlowSmallButton(title: "Refresh") {
                    Task { await model.load() }
                }
            }
            .appearStagger(0, appeared)

            hero.appearStagger(1, appeared)

            if model.source == .localPreview {
                previewBanner.appearStagger(2, appeared)
            }

            FlowSegmented(
                items: TeamDashboardModel.Period.allCases.map { (value: $0, label: $0.rawValue) },
                selection: $period)
                .appearStagger(2, appeared)

            board.appearStagger(3, appeared)

            FlowSectionLabel("Achievements").appearStagger(4, appeared)
            TeamBadgeGrid(badges: model.badges, appeared: appeared)
                .appearStagger(5, appeared)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
        .task { await model.load() }
        .onReceive(history.$entries) { _ in
            // Local dictations shift the preview board and can unlock badges live.
            Task { await model.load() }
        }
    }

    // MARK: Hero

    private var hero: some View {
        let you = model.you
        let xp = you?.xp ?? 0
        let level = TeamGamification.level(forXP: xp)
        return FlowHeroSurface {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    (
                        Text("Climb the ")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                        + Text("leaderboard")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                            .italic()
                    )
                    .foregroundColor(.white)

                    Text("Every dictated word is XP. Daily and weekly standings across the \(TeamAccess.requiredDomain) team.")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        heroStat(icon: "bolt.fill", label: "XP this week", value: xp)
                        if let you {
                            heroStat(icon: "flame.fill", label: "day streak", value: you.player.streakDays)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                TeamLevelRing(level: level,
                              title: TeamGamification.title(forLevel: level),
                              progress: TeamGamification.progressToNextLevel(forXP: xp),
                              appeared: appeared)
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        }
    }

    private func heroStat(icon: String, label: String, value: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(.white.opacity(0.9))
            AnimatedNumberText(value: value,
                               font: .system(size: 15, weight: .semibold, design: .serif),
                               color: .white)
            Text(label).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.12)))
    }

    private var previewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundColor(FlowTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("The team server is warming up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FlowTheme.ink)
                Text("Showing your local stats for now — teammates appear here as soon as the leaderboard goes live.")
                    .font(.system(size: 12))
                    .foregroundColor(FlowTheme.inkSecondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlowTheme.rowHover)
        )
    }

    // MARK: Board

    @ViewBuilder
    private var board: some View {
        let rows = model.rows(for: period)
        VStack(alignment: .leading, spacing: 16) {
            if rows.count >= 3 {
                TeamPodium(top: Array(rows.prefix(3)), appeared: appeared)
                if rows.count > 3 {
                    TeamBoardList(rows: Array(rows.dropFirst(3)),
                                  maxXP: rows.first?.xp ?? 1)
                }
            } else if rows.isEmpty {
                FlowCard {
                    HStack(spacing: 12) {
                        Image(systemName: "trophy").foregroundColor(FlowTheme.accent)
                        Text("No activity yet \(period == .daily ? "today" : "this week") — dictate something and claim rank #1.")
                            .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
                    }
                }
            } else {
                TeamBoardList(rows: rows, maxXP: rows.first?.xp ?? 1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: period)
    }
}

// MARK: - Level ring

/// Circular level indicator for the hero: an accent arc sweeps to the progress
/// toward the next level, with the level number in the middle.
private struct TeamLevelRing: View {
    let level: Int
    let title: String
    let progress: Double
    let appeared: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: appeared ? max(progress, 0.02) : 0)
                    .stroke(
                        AngularGradient(colors: [FlowTheme.accent, Color(red: 0.35, green: 0.85, blue: 0.65)],
                                        center: .center,
                                        startAngle: .degrees(-90), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 1.1).delay(0.3), value: appeared)
                VStack(spacing: 0) {
                    Text("LVL")
                        .font(.system(size: 9, weight: .semibold)).tracking(1)
                        .foregroundColor(.white.opacity(0.7))
                    Text("\(level)")
                        .font(.system(size: 28, weight: .semibold, design: .serif))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 88, height: 88)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        }
    }
}

// MARK: - Podium

/// Top-3 podium: silver | gold | bronze columns that grow from the floor, with
/// a bouncing crown on the leader. Column height encodes XP relative to #1.
private struct TeamPodium: View {
    let top: [TeamGamification.RankedPlayer]   // ranks 1...3, in rank order
    let appeared: Bool

    private var display: [TeamGamification.RankedPlayer] {
        // Visual order: 2nd, 1st, 3rd.
        [top[1], top[0], top[2]]
    }

    var body: some View {
        FlowCard {
            HStack(alignment: .bottom, spacing: 18) {
                ForEach(display) { row in
                    PodiumColumn(row: row,
                                 fraction: fraction(for: row),
                                 appeared: appeared)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func fraction(for row: TeamGamification.RankedPlayer) -> Double {
        let leader = max(top[0].xp, 1)
        // Keep even a zero-XP podium visible.
        return max(0.25, Double(row.xp) / Double(leader))
    }
}

private struct PodiumColumn: View {
    let row: TeamGamification.RankedPlayer
    let fraction: Double
    let appeared: Bool

    @State private var crownBounce = false

    private var maxBarHeight: CGFloat { 110 }
    private var barHeight: CGFloat { maxBarHeight * fraction }
    private var medal: Color {
        switch row.rank {
        case 1: return Color(red: 0.85, green: 0.65, blue: 0.13)
        case 2: return Color(red: 0.62, green: 0.65, blue: 0.69)
        default: return Color(red: 0.72, green: 0.45, blue: 0.20)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if row.rank == 1 {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18))
                    .foregroundColor(medal)
                    .offset(y: crownBounce ? -3 : 1)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: crownBounce)
                    .onAppear { crownBounce = true }
            }
            TeamAvatar(name: row.player.name, seed: row.player.id, size: row.rank == 1 ? 46 : 38,
                       highlighted: row.isYou)
            Text(row.player.name)
                .font(.system(size: 13, weight: row.isYou ? .bold : .semibold))
                .foregroundColor(FlowTheme.ink)
                .lineLimit(1)
            AnimatedNumberText(value: row.xp,
                               font: .system(size: 15, weight: .semibold, design: .serif),
                               color: FlowTheme.ink)
            Text("XP")
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundColor(FlowTheme.inkSecondary)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [medal.opacity(0.85), medal.opacity(0.45)],
                                         startPoint: .top, endPoint: .bottom))
                Text("\(row.rank)")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundColor(.white)
                    .padding(.top, 8)
            }
            .frame(height: appeared ? barHeight : 8)
            .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.25 + Double(row.rank) * 0.12),
                       value: appeared)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Ranked list

private struct TeamBoardList: View {
    let rows: [TeamGamification.RankedPlayer]
    let maxXP: Int

    var body: some View {
        FlowCard(padding: 10) {
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    TeamBoardRow(row: row, maxXP: max(maxXP, 1))
                }
            }
        }
    }
}

private struct TeamBoardRow: View {
    let row: TeamGamification.RankedPlayer
    let maxXP: Int

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(row.rank)")
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundColor(FlowTheme.inkSecondary)
                .frame(width: 34, alignment: .leading)
            TeamAvatar(name: row.player.name, seed: row.player.id, size: 30, highlighted: row.isYou)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.player.name)
                        .font(.system(size: 13, weight: row.isYou ? .bold : .medium))
                        .foregroundColor(FlowTheme.ink)
                        .lineLimit(1)
                    if row.isYou {
                        Text("YOU")
                            .font(.system(size: 9, weight: .bold)).tracking(0.5)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(FlowTheme.accent))
                    }
                }
                Text("\(row.player.words) words · \(row.player.dictations) dictations")
                    .font(.system(size: 11))
                    .foregroundColor(FlowTheme.inkSecondary)
            }
            Spacer(minLength: 12)
            if row.player.streakDays > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 10)).foregroundColor(.orange)
                    Text("\(row.player.streakDays)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(FlowTheme.inkSecondary)
                }
            }
            // XP bar relative to the board leader.
            ZStack(alignment: .leading) {
                Capsule().fill(FlowTheme.rowHover)
                Capsule().fill(FlowTheme.accent)
                    .frame(width: 90 * CGFloat(row.xp) / CGFloat(maxXP))
            }
            .frame(width: 90, height: 6)
            Text("\(row.xp) XP")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(FlowTheme.ink)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(row.isYou ? FlowTheme.accentSoft : (hovering ? FlowTheme.rowHover : .clear))
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - Badges

private struct TeamBadgeGrid: View {
    let badges: [TeamGamification.Badge]
    let appeared: Bool

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                TeamBadgeTile(badge: badge, index: index, appeared: appeared)
            }
        }
    }
}

private struct TeamBadgeTile: View {
    let badge: TeamGamification.Badge
    let index: Int
    let appeared: Bool

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(badge.unlocked ? FlowTheme.accentSoft : FlowTheme.rowHover)
                    .frame(width: 44, height: 44)
                Image(systemName: badge.unlocked ? badge.icon : "lock")
                    .font(.system(size: 17))
                    .foregroundColor(badge.unlocked ? FlowTheme.accent : FlowTheme.inkSecondary.opacity(0.6))
            }
            Text(badge.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(badge.unlocked ? FlowTheme.ink : FlowTheme.inkSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FlowTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(badge.unlocked && hovering ? FlowTheme.accent.opacity(0.5) : FlowTheme.cardStroke,
                        lineWidth: 1)
        )
        .opacity(badge.unlocked ? 1 : 0.75)
        .scaleEffect(appeared ? 1 : 0.6)
        .opacity(appeared ? (badge.unlocked ? 1 : 0.75) : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.5 + Double(index) * 0.05),
                   value: appeared)
        .onHover { hovering = $0 }
        .popover(isPresented: $hovering, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(badge.title)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(FlowTheme.ink)
                Text(badge.unlocked ? badge.detail : "Locked — \(badge.detail.lowercased())")
                    .font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
            }
            .padding(12)
            .frame(minWidth: 180, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

/// Initials avatar with a hue derived deterministically from the player id, so
/// colors are stable across launches and identical for the same teammate.
private struct TeamAvatar: View {
    let name: String
    let seed: String
    let size: CGFloat
    var highlighted = false

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var hue: Double {
        // djb2 — deterministic across launches (unlike `hashValue`).
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }

    var body: some View {
        ZStack {
            Circle().fill(Color(hue: hue, saturation: 0.45, brightness: 0.72))
            Text(initials)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(highlighted ? FlowTheme.accent : .clear, lineWidth: 2))
    }
}

/// Text whose number ticks up to `value` (easing out) whenever it appears or
/// the value changes. The final value is laid out invisibly so the width never
/// jumps mid-animation.
private struct AnimatedNumberText: View {
    let value: Int
    let font: Font
    let color: Color

    @State private var shown: Double = 0

    var body: some View {
        Text(StatsFormat.count(value))
            .font(font).foregroundColor(color).monospacedDigit()
            .opacity(0)
            .modifier(CountUpOverlay(value: shown, font: font, color: color))
            .onAppear { withAnimation(.easeOut(duration: 1.0)) { shown = Double(value) } }
            .onChange(of: value) { new in
                withAnimation(.easeOut(duration: 0.7)) { shown = Double(new) }
            }
    }
}

private struct CountUpOverlay: ViewModifier, Animatable {
    var value: Double
    let font: Font
    let color: Color

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay(
            Text(StatsFormat.count(Int(value)))
                .font(font).foregroundColor(color).monospacedDigit(),
            alignment: .leading)
    }
}
