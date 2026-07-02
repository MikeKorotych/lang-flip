import SwiftUI

/// Corporate "Team" section — a words-first activity dashboard for @uni.tech
/// accounts. The hero spotlights *your* rank with movement since the previous
/// period; a team-pulse strip shows what the whole team dictated (with a trend
/// vs the last period); a movers row celebrates the biggest climber and the
/// most improved teammate; then the podium, the ranked list with rank-delta
/// chips, and locally-earned badges. Everything animates in with the staggered
/// language of Insights: counters tick, the podium grows with a shine sweep,
/// badge tiles pop.
struct TeamDashboardView: View {
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @ObservedObject private var history = DictationHistory.shared
    @StateObject private var model = TeamDashboardModel()
    @State private var appeared = false
    @State private var period: TeamDashboardModel.Period = .weekly
    @AppStorage("lf.dev.teamPreviewTeammates") private var devTeamPreviewTeammates = false

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
        let insights = model.insights(for: period)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    DisplayText("Team Activity", size: 26)
                    Text(TeamAccess.requiredDomain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(FlowTheme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(FlowTheme.accentSoft))
                        .offset(y: 2)
                }
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                TeamIconButton(systemName: "arrow.clockwise", help: "Refresh") {
                    Task { await model.load() }
                }
            }
            .appearStagger(0, appeared)

            hero(insights).appearStagger(1, appeared)

            if !devTeamPreviewTeammates && (model.isLocalPreview || (period == .monthly && model.isMonthlyLocalFallback)) {
                previewBanner.appearStagger(2, appeared)
            }

            HStack {
                Spacer()
                FlowSegmented(
                    items: TeamDashboardModel.Period.allCases.map { (value: $0, label: $0.rawValue) },
                    selection: $period)
                Spacer()
            }
                .appearStagger(2, appeared)

            TeamPulseStrip(pulse: insights.pulse, appeared: appeared)
                .appearStagger(3, appeared)

            if insights.topClimber != nil || insights.mostImproved != nil {
                TeamMoversRow(topClimber: insights.topClimber,
                              mostImproved: insights.mostImproved,
                              periodSuffix: period.labelSuffix,
                              appeared: appeared)
                    .appearStagger(4, appeared)
            }

            board(insights).appearStagger(5, appeared)

            FlowSectionLabel("Achievements").appearStagger(6, appeared)
            TeamBadgeGrid(badges: model.badges, appeared: appeared)
                .appearStagger(7, appeared)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
        .task { await model.load() }
        .onReceive(history.$entries) { _ in
            // Local dictations shift the preview board and can unlock badges live.
            Task { await model.load() }
        }
        .onChange(of: devTeamPreviewTeammates) { _ in
            Task { await model.load() }
        }
    }

    // MARK: Hero

    private func hero(_ insights: TeamGamification.BoardInsights) -> some View {
        FlowHeroSurface {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    (
                        Text("Make words ")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                        + Text("visible")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                            .italic()
                    )
                    .foregroundColor(.white)

                    Text("Team activity is ranked by dictated words — the same work signal people already track against the weekly Sayful quota.")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        heroStat(icon: "text.alignleft",
                                 label: "words \(period.labelSuffix)",
                                 value: insights.you?.words ?? 0)
                        if let streak = model.youThisWeek?.player.streakDays, streak > 0 {
                            heroStat(icon: "flame.fill", label: "day streak", value: streak)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                TeamRankSpotlight(standing: insights.you,
                                  periodSuffix: period.labelSuffix,
                                  appeared: appeared)
            }
            .padding(28)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .leading)
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
                Text(model.isLocalPreview ? "The team server is warming up" : "Monthly team board is warming up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FlowTheme.ink)
                Text(model.isLocalPreview
                     ? "Showing your local stats for now — teammates appear here as soon as the leaderboard goes live."
                     : "Showing your local month for now — teammates appear here once the backend returns monthly rows.")
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
    private func board(_ insights: TeamGamification.BoardInsights) -> some View {
        let rows = model.rows(for: period)
        let deltas = model.previousBoard(for: period) == nil ? nil : insights.rankDeltas
        VStack(alignment: .leading, spacing: 16) {
            if rows.count >= 3 {
                TeamPodium(top: Array(rows.prefix(3)), deltas: deltas, appeared: appeared)
                if rows.count > 3 {
                    TeamBoardList(rows: Array(rows.dropFirst(3)),
                                  maxWords: rows.first?.activityWords ?? 1,
                                  deltas: deltas)
                }
            } else if rows.isEmpty {
                FlowCard {
                    HStack(spacing: 12) {
                        Image(systemName: "trophy").foregroundColor(FlowTheme.accent)
                        Text("No activity yet \(period.labelSuffix) — dictate something and claim rank #1.")
                            .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
                    }
                }
            } else {
                TeamBoardList(rows: rows, maxWords: rows.first?.activityWords ?? 1, deltas: deltas)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: period)
    }
}

private extension TeamDashboardModel.Period {
    var labelSuffix: String {
        switch self {
        case .daily: return "today"
        case .weekly: return "this week"
        case .monthly: return "this month"
        }
    }
}

private struct TeamIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(hovering ? FlowTheme.accent : FlowTheme.ink)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(hovering ? FlowTheme.rowHover : .clear)
        )
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Rank spotlight (hero, right side)

/// Your rank as the hero's centerpiece: a big serif "#N" that springs in, a
/// movement chip vs the previous period, and the concrete gap worth closing —
/// "you lead", "N words to #K" — phrased per rank.
private struct TeamRankSpotlight: View {
    let standing: TeamGamification.YourStanding?
    let periodSuffix: String
    let appeared: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let standing {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("#")
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                        .foregroundColor(.white.opacity(0.65))
                    Text("\(standing.rank)")
                        .font(.system(size: 52, weight: .bold, design: .serif))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.62).delay(0.25), value: appeared)

                Text("of \(standing.totalPlayers) \(periodSuffix)")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 6) {
                    if let delta = standing.rankDelta {
                        RankDeltaChip(delta: delta, onDark: true)
                    }
                    if let gap = gapLine {
                        Text(gap)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)
                .animation(.easeOut(duration: 0.45).delay(0.55), value: appeared)
            } else {
                Image(systemName: "trophy")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.75))
                Text("Dictate to enter\nthe board")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 150)
    }

    private var gapLine: String? {
        guard let standing else { return nil }
        if standing.rank == 1 {
            guard let lead = standing.leadOverNext, standing.totalPlayers > 1 else { return nil }
            return "leads by \(StatsFormat.count(lead)) words"
        }
        if let toTopFive = standing.gapToTopFive {
            return "\(StatsFormat.count(toTopFive)) words to top 5"
        }
        if let toNext = standing.gapToNext {
            return "\(StatsFormat.count(toNext)) words to #\(standing.rank - 1)"
        }
        return nil
    }
}

/// Compact rank-movement chip: ▲n (green) / ▼n (red) / = (neutral).
private struct RankDeltaChip: View {
    let delta: Int
    var onDark = false

    private var symbol: String { delta > 0 ? "arrowtriangle.up.fill" : (delta < 0 ? "arrowtriangle.down.fill" : "equal") }
    private var tint: Color {
        if delta > 0 { return Color(red: 0.25, green: 0.75, blue: 0.45) }
        if delta < 0 { return Color(red: 0.88, green: 0.40, blue: 0.34) }
        return onDark ? .white.opacity(0.7) : FlowTheme.inkSecondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            if delta != 0 {
                Text("\(abs(delta))").font(.system(size: 11, weight: .bold)).monospacedDigit()
            }
        }
        .foregroundColor(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(onDark ? 0.22 : 0.14)))
    }
}

/// "NEW" chip for players absent from the previous board.
private struct NewEntrantChip: View {
    var body: some View {
        Text("NEW")
            .font(.system(size: 8, weight: .bold)).tracking(0.6)
            .foregroundColor(FlowTheme.accent)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(FlowTheme.accentSoft))
    }
}

// MARK: - Team pulse

/// Team-wide totals for the selected period — the "we did this together"
/// counterweight to the competitive board — plus a trend vs the last period.
private struct TeamPulseStrip: View {
    let pulse: TeamGamification.TeamPulse
    let appeared: Bool

    var body: some View {
        FlowCard(padding: 14) {
            HStack(spacing: 0) {
                stat(icon: "text.word.spacing", value: pulse.totalWords, label: "team words")
                divider
                stat(icon: "person.2.fill", value: pulse.activeMembers, label: "active teammates")
                divider
                stat(icon: "chart.bar.fill", value: pulse.averageWords, label: "avg words / person")
                if let trend = pulse.trendPercent {
                    divider
                    trendStat(trend)
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.easeOut(duration: 0.45).delay(0.15), value: appeared)
        }
    }

    private func stat(icon: String, value: Int, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(FlowTheme.accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(FlowTheme.accentSoft))
            VStack(alignment: .leading, spacing: 2) {
                AnimatedNumberText(value: value,
                                   font: .system(size: 16, weight: .semibold, design: .serif),
                                   color: FlowTheme.ink)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                    .foregroundColor(FlowTheme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 112, maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    private func trendStat(_ trend: Int) -> some View {
        let up = trend >= 0
        let tint = up ? Color(red: 0.25, green: 0.75, blue: 0.45) : Color(red: 0.88, green: 0.40, blue: 0.34)
        return HStack(spacing: 12) {
            Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(up ? "+" : "")\(trend)%")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(tint)
                    .monospacedDigit()
                Text("VS PREVIOUS")
                    .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                    .foregroundColor(FlowTheme.inkSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 112, maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
    }

    private var divider: some View {
        Rectangle()
            .fill(FlowTheme.cardStroke)
            .frame(width: 1, height: 34)
    }
}

// MARK: - Movers

/// Spotlights beyond the podium: the biggest rank climber and the largest word
/// growth vs the previous period — so improving mid-pack teammates get shine,
/// not only the perennial top-1.
private struct TeamMoversRow: View {
    let topClimber: TeamGamification.Mover?
    let mostImproved: TeamGamification.Mover?
    let periodSuffix: String
    let appeared: Bool

    var body: some View {
        HStack(spacing: 16) {
            if let climber = topClimber {
                MoverCard(icon: "arrow.up.forward.circle.fill",
                          label: "Biggest climb \(periodSuffix)",
                          player: climber.player,
                          headline: "▲\(climber.rankClimb) \(climber.rankClimb == 1 ? "place" : "places")",
                          appeared: appeared, slideFrom: -24)
            }
            if let improved = mostImproved {
                MoverCard(icon: "chart.line.uptrend.xyaxis.circle.fill",
                          label: "Most improved \(periodSuffix)",
                          player: improved.player,
                          headline: "+\(StatsFormat.count(improved.wordsGained)) words",
                          appeared: appeared, slideFrom: 24)
            }
        }
    }
}

private struct MoverCard: View {
    let icon: String
    let label: String
    let player: BackendLeaderboardPlayer
    let headline: String
    let appeared: Bool
    let slideFrom: CGFloat

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(FlowTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                    .foregroundColor(FlowTheme.inkSecondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    TeamAvatar(name: player.name, seed: player.id, size: 22)
                    Text(player.name)
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 10)
            Text(headline)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(FlowTheme.accent)
                .monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(FlowTheme.accentSoft))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                .fill(FlowTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                .stroke(hovering ? FlowTheme.accent.opacity(0.45) : FlowTheme.cardStroke, lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.01 : 1)
        .offset(x: appeared ? 0 : slideFrom)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.8).delay(0.3), value: appeared)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Podium

/// Top-3 podium: silver | gold | bronze columns that grow from the floor, with
/// a bouncing crown and a pulsing glow on the leader, movement chips under the
/// names, and a one-shot shine sweep across the bars once they have grown.
private struct TeamPodium: View {
    let top: [TeamGamification.RankedPlayer]   // ranks 1...3, in rank order
    let deltas: [String: Int]?
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
                                 delta: deltas?[row.id],
                                 hasDeltas: deltas != nil,
                                 appeared: appeared)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func fraction(for row: TeamGamification.RankedPlayer) -> Double {
        let leader = max(top[0].activityWords, 1)
        // Keep even a zero-word podium visible.
        return max(0.25, Double(row.activityWords) / Double(leader))
    }
}

private struct PodiumColumn: View {
    let row: TeamGamification.RankedPlayer
    let fraction: Double
    let delta: Int?
    let hasDeltas: Bool
    let appeared: Bool

    @State private var crownBounce = false
    @State private var glowPulse = false
    @State private var shine = false

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
            ZStack {
                if row.rank == 1 {
                    // Soft breathing halo behind the leader.
                    Circle()
                        .fill(medal.opacity(0.45))
                        .frame(width: 54, height: 54)
                        .blur(radius: 10)
                        .scaleEffect(glowPulse ? 1.25 : 0.9)
                        .opacity(glowPulse ? 0.9 : 0.5)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: glowPulse)
                        .onAppear { glowPulse = true }
                }
                TeamAvatar(name: row.player.name, seed: row.player.id, size: row.rank == 1 ? 46 : 38,
                           highlighted: row.isYou)
            }
            HStack(spacing: 5) {
                Text(row.player.name)
                    .font(.system(size: 13, weight: row.isYou ? .bold : .semibold))
                    .foregroundColor(FlowTheme.ink)
                    .lineLimit(1)
                if hasDeltas {
                    if let delta {
                        RankDeltaChip(delta: delta)
                    } else {
                        NewEntrantChip()
                    }
                }
            }
            AnimatedNumberText(value: row.activityWords,
                               font: .system(size: 15, weight: .semibold, design: .serif),
                               color: FlowTheme.ink)
            Text("WORDS")
                .font(.system(size: 9, weight: .semibold)).tracking(1)
                .foregroundColor(FlowTheme.inkSecondary)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [medal.opacity(0.85), medal.opacity(0.45)],
                                         startPoint: .top, endPoint: .bottom))
                // One-shot shine sweep after the bar has grown.
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 36)
                        .offset(y: shine ? geo.size.height + 20 : -56)
                        .animation(.easeInOut(duration: 0.9).delay(1.0 + Double(row.rank) * 0.15), value: shine)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)
                Text("\(row.rank)")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundColor(.white)
                    .padding(.top, 8)
            }
            .frame(height: appeared ? barHeight : 8)
            .animation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.25 + Double(row.rank) * 0.12),
                       value: appeared)
            .onAppear { shine = false; DispatchQueue.main.async { shine = true } }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Ranked list

private struct TeamBoardList: View {
    let rows: [TeamGamification.RankedPlayer]
    let maxWords: Int
    let deltas: [String: Int]?

    @State private var page = 0

    private let pageSize = 10
    private var maxPage: Int { max(0, (rows.count - 1) / pageSize) }
    private var effectivePage: Int { min(page, maxPage) }
    private var visibleRows: [TeamGamification.RankedPlayer] {
        let start = effectivePage * pageSize
        let end = min(start + pageSize, rows.count)
        guard start < end else { return [] }
        return Array(rows[start..<end])
    }

    var body: some View {
        FlowCard(padding: 10) {
            VStack(spacing: 8) {
                ForEach(visibleRows) { row in
                    TeamBoardRow(row: row, maxWords: max(maxWords, 1),
                                 delta: deltas?[row.id], hasDeltas: deltas != nil)
                }
                if rows.count > pageSize {
                    pagination
                }
            }
        }
        .onChange(of: rows.map(\.id)) { _ in
            page = min(page, maxPage)
        }
    }

    private var pagination: some View {
        HStack(spacing: 10) {
            Text("Showing \(effectivePage * pageSize + 1)-\(min((effectivePage + 1) * pageSize, rows.count)) of \(rows.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FlowTheme.inkSecondary)
            Spacer()
            TeamPageButton(systemName: "chevron.left", disabled: effectivePage == 0) {
                withAnimation(.easeInOut(duration: 0.2)) { page = max(0, page - 1) }
            }
            Text("\(effectivePage + 1) / \(maxPage + 1)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(FlowTheme.ink)
                .monospacedDigit()
                .frame(width: 44)
            TeamPageButton(systemName: "chevron.right", disabled: effectivePage >= maxPage) {
                withAnimation(.easeInOut(duration: 0.2)) { page = min(maxPage, page + 1) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }
}

private struct TeamPageButton: View {
    let systemName: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(disabled ? FlowTheme.inkSecondary.opacity(0.45) : FlowTheme.ink)
                .frame(width: 26, height: 24)
                .background(Capsule().fill(disabled ? FlowTheme.rowHover.opacity(0.45) : FlowTheme.rowHover))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct TeamBoardRow: View {
    let row: TeamGamification.RankedPlayer
    let maxWords: Int
    let delta: Int?
    let hasDeltas: Bool

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
            if hasDeltas {
                if let delta {
                    RankDeltaChip(delta: delta)
                } else {
                    NewEntrantChip()
                }
            }
            if row.player.streakDays > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 10)).foregroundColor(.orange)
                    Text("\(row.player.streakDays)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(FlowTheme.inkSecondary)
                }
            }
            // Word bar relative to the board leader.
            ZStack(alignment: .leading) {
                Capsule().fill(FlowTheme.rowHover)
                Capsule().fill(FlowTheme.accent)
                    .frame(width: 90 * CGFloat(row.activityWords) / CGFloat(maxWords))
            }
            .frame(width: 90, height: 6)
            Text("\(StatsFormat.count(row.activityWords)) words")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(FlowTheme.ink)
                .frame(width: 92, alignment: .trailing)
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
