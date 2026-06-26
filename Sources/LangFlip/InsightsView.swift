import SwiftUI

/// Usage dashboard, modeled on the reference (Wispr Flow) Insights screen:
/// a local-stats banner, Usage/Voice sub-tabs, metric cards (an animated WPM
/// gauge, total words with a month-over-month trend, dictations), and a
/// GitHub-style activity heatmap. On entering the tab everything animates in —
/// the gauge sweeps, bars fill, and heatmap cells pop in on a diagonal wave
/// (port of the react-native-reanimated contribution-calendar demo).
struct InsightsView: View {
    @ObservedObject private var history = DictationHistory.shared
    @State private var appeared = false
    @State private var tab: UsageTab = .usage
    @State private var usage = InsightsUsageSnapshot.make(entries: DictationHistory.shared.entries)

    enum UsageTab: String, CaseIterable { case usage = "Your Usage", voice = "Your Voice" }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DisplayText("Insights", size: 26)
                .appearStagger(0, appeared)

            banner.appearStagger(1, appeared)

            tabBar.appearStagger(2, appeared)

            if tab == .usage {
                metricsRow.appearStagger(3, appeared)
                // Explicit equal halves: `.frame(maxWidth:.infinity)` alone splits
                // the HStack's *slack* (not total), so the calendar's larger
                // minimum stole more. Measure THIS row's width and give each card
                // exactly half — clamped so it can never overflow the row.
                HStack(alignment: .top, spacing: 16) {
                    AppBreakdownCard(breakdown: usage.appBreakdown,
                                     total: usage.entriesCount,
                                     uniqueApps: usage.uniqueApps,
                                     appeared: appeared)
                        .frame(maxWidth: .infinity)
                        .appearStagger(4, appeared)
                    // Card fades/slides in like the others; its cells then pop
                    // diagonally on top (their base delay is after the fade).
                    ActivityCard(heatmap: usage.heatmap, appeared: appeared)
                        .frame(maxWidth: .infinity)
                        .appearStagger(4, appeared)
                }
            } else {
                YourVoiceView(history: history, appeared: appeared)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            appeared = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { appeared = true }
        }
        .onReceive(history.$entries) { entries in
            usage = InsightsUsageSnapshot.make(entries: entries)
        }
    }


    // MARK: Banner + tabs

    private var banner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundColor(FlowTheme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stats are stored locally on this Mac")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FlowTheme.ink)
                Text("Your usage history never leaves your device.")
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

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(UsageTab.allCases, id: \.self) { t in
                VStack(spacing: 6) {
                    Text(t.rawValue)
                        .font(.system(size: 14, weight: tab == t ? .semibold : .regular))
                        .foregroundColor(tab == t ? FlowTheme.ink : FlowTheme.inkSecondary)
                    Rectangle()
                        .fill(tab == t ? FlowTheme.accent : .clear)
                        .frame(height: 2)
                }
                .fixedSize()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { tab = t } }
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlowTheme.cardStroke).frame(height: 1)
        }
    }

    // MARK: Metrics

    private var metricsRow: some View {
        HStack(spacing: 16) {
            WPMGaugeCard(wpm: usage.wpm, peak: usage.peakWpm, spokenMinutes: usage.spokenMinutes, appeared: appeared)
            TotalWordsCard(total: usage.totalWords, pages: usage.pages, wordsToday: usage.wordsToday, trend: usage.monthTrend, appeared: appeared)
            DictationsCard(count: usage.entriesCount, avgWords: usage.avgWords, today: usage.dictationsToday, streak: usage.currentStreak, longest: usage.longestStreak)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct EntryDigest {
    let date: Date
    let day: Date
    let wordCount: Int
    let duration: Double?
    let app: String?
}

private struct InsightsUsageSnapshot {
    let entriesCount: Int
    let totalWords: Int
    let wordsToday: Int
    let dictationsToday: Int
    let wpm: Int?
    let peakWpm: Int?
    let spokenMinutes: Int
    let pages: Int
    let avgWords: Int
    let currentStreak: Int
    let longestStreak: Int
    let monthTrend: Int?
    let appBreakdown: [(category: AppCategory, count: Int)]
    let uniqueApps: Int
    let heatmap: ActivityHeatmapSnapshot

    static let empty = make(entries: [])

    static func make(entries: [DictationEntry]) -> InsightsUsageSnapshot {
        let completedEntries = entries.filter(\.isTranscribed)
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let digests = completedEntries.map {
            EntryDigest(date: $0.date,
                        day: cal.startOfDay(for: $0.date),
                        wordCount: $0.wordCount,
                        duration: $0.duration,
                        app: $0.app)
        }

        let totalWords = digests.reduce(0) { $0 + $1.wordCount }
        let wordsToday = digests.reduce(0) { $1.day == today ? $0 + $1.wordCount : $0 }
        let dictationsToday = digests.reduce(0) { $1.day == today ? $0 + 1 : $0 }

        let timed = digests.filter { ($0.duration ?? 0) > 0 }
        let timedWords = timed.reduce(0) { $0 + $1.wordCount }
        let timedMinutes = timed.reduce(0.0) { $0 + ($1.duration ?? 0) / 60 }
        let wpm = timedMinutes > 0 && timedWords > 0 ? Int(Double(timedWords) / timedMinutes) : nil
        let peakWpm = timed.compactMap { entry -> Double? in
            guard let duration = entry.duration, duration > 0 else { return nil }
            return Double(entry.wordCount) / (duration / 60)
        }.max().map(Int.init)

        let days = Set(digests.map(\.day))
        let currentStreak = Self.currentStreak(days: days, calendar: cal, today: today)
        let longestStreak = Self.longestStreak(days: days, calendar: cal)
        let monthTrend = Self.monthTrend(digests: digests, calendar: cal, now: now)

        var categoryCounts: [AppCategory: Int] = [:]
        for entry in digests {
            categoryCounts[AppCategory.classify(entry.app), default: 0] += 1
        }
        let appBreakdown = categoryCounts.sorted { $0.value > $1.value }
            .map { (category: $0.key, count: $0.value) }

        return InsightsUsageSnapshot(
            entriesCount: digests.count,
            totalWords: totalWords,
            wordsToday: wordsToday,
            dictationsToday: dictationsToday,
            wpm: wpm,
            peakWpm: peakWpm,
            spokenMinutes: Int((digests.reduce(0.0) { $0 + ($1.duration ?? 0) } / 60).rounded()),
            pages: Int((Double(totalWords) / 250).rounded()),
            avgWords: digests.isEmpty ? 0 : Int((Double(totalWords) / Double(digests.count)).rounded()),
            currentStreak: currentStreak,
            longestStreak: longestStreak,
            monthTrend: monthTrend,
            appBreakdown: appBreakdown,
            uniqueApps: Set(digests.compactMap(\.app)).count,
            heatmap: ActivityHeatmapSnapshot.make(digests: digests, calendar: cal, today: today)
        )
    }

    static func currentStreak(days: Set<Date>, calendar: Calendar, today: Date) -> Int {
        var count = 0
        var day = today
        while days.contains(day) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        let sorted = days.sorted()
        guard !sorted.isEmpty else { return 0 }
        var longest = 1
        var current = 1
        for i in 1..<sorted.count {
            if calendar.dateComponents([.day], from: sorted[i - 1], to: sorted[i]).day == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    private static func monthTrend(digests: [EntryDigest], calendar: Calendar, now: Date) -> Int? {
        guard let thisMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)),
              let lastMonthStart = calendar.date(byAdding: .month, value: -1, to: thisMonthStart)
        else { return nil }

        var thisMonth = 0
        var lastMonth = 0
        for entry in digests {
            if entry.date >= thisMonthStart && entry.date < now {
                thisMonth += entry.wordCount
            } else if entry.date >= lastMonthStart && entry.date < thisMonthStart {
                lastMonth += entry.wordCount
            }
        }

        guard lastMonth > 0 else { return nil }
        return Int((Double(thisMonth - lastMonth) / Double(lastMonth)) * 100)
    }
}

// MARK: - Metric cards

private struct WPMGaugeCard: View {
    let wpm: Int?
    let peak: Int?
    let spokenMinutes: Int
    let appeared: Bool

    /// Fraction of the gauge to fill (0…1), capping a fast typist at ~160 wpm.
    private var fill: Double { min(Double(wpm ?? 0) / 160.0, 1.0) }

    var body: some View {
        FlowCard(minHeight: 170) {
            VStack(alignment: .leading, spacing: 10) {
                Text(wpm.map { "\($0)" } ?? "—")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Text("WORDS PER MINUTE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(FlowTheme.inkSecondary)
                ZStack(alignment: .bottom) {
                    GaugeArc(fill: appeared ? fill : 0)
                        .frame(height: 70)
                    if let peak {
                        Text("best \(peak)")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(FlowTheme.ink)
                            .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 4)
                Divider().overlay(FlowTheme.cardStroke)
                statLine(icon: "clock", "\(spokenMinutes) min spoken")
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }
}

private func statLine(icon: String, _ text: String) -> some View {
    HStack(spacing: 7) {
        Image(systemName: icon).font(.system(size: 11)).foregroundColor(FlowTheme.accent)
        Text(text).font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
    }
}

private struct GaugeArc: View {
    let fill: Double

    var body: some View {
        ZStack {
            ArcShape()
                .stroke(FlowTheme.cardStroke, style: StrokeStyle(lineWidth: 11, lineCap: .round))
            ArcShape()
                .trim(from: 0, to: fill)
                .stroke(FlowTheme.accent, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .animation(.easeOut(duration: 0.9), value: fill)
        }
        .padding(.horizontal, 6)
    }
}

/// A bottom semicircle (180° arc), left to right.
private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let radius = min(rect.width / 2, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        return p
    }
}

private struct TotalWordsCard: View {
    let total: Int
    let pages: Int
    let wordsToday: Int
    let trend: Int?
    let appeared: Bool

    var body: some View {
        FlowCard(minHeight: 170) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(StatsFormat.count(total))
                        .font(.system(size: 32, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                    Spacer()
                    if let trend {
                        Text("\(trend >= 0 ? "▲" : "▼") \(abs(trend))% this month")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(FlowTheme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(FlowTheme.accentSoft))
                    }
                }
                Text("TOTAL WORDS DICTATED")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(FlowTheme.inkSecondary)
                Divider().overlay(FlowTheme.cardStroke).padding(.vertical, 4)
                statLine(icon: "doc.text", pages >= 1 ? "≈ \(pages) \(pages == 1 ? "page" : "pages") written" : "Your first page awaits")
                statLine(icon: "calendar", "\(wordsToday) words today")
                Spacer(minLength: 6)
                // Single-source bar (desktop-only app).
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(FlowTheme.rowHover)
                            Capsule().fill(FlowTheme.accent)
                                .frame(width: appeared ? geo.size.width : 0)
                                .animation(.easeOut(duration: 0.8).delay(0.1), value: appeared)
                        }
                    }
                    .frame(height: 18)
                    HStack(spacing: 4) {
                        Image(systemName: "desktopcomputer").font(.system(size: 10))
                        Text("Desktop").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(FlowTheme.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DictationsCard: View {
    let count: Int
    let avgWords: Int
    let today: Int
    let streak: Int
    let longest: Int

    var body: some View {
        FlowCard(minHeight: 170) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(count)")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Text("DICTATIONS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(FlowTheme.inkSecondary)
                Divider().overlay(FlowTheme.cardStroke).padding(.vertical, 4)
                statLine(icon: "text.alignleft", "\(avgWords) words per dictation")
                statLine(icon: "calendar", "\(today) today")
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 12)).foregroundColor(FlowTheme.accent)
                    Text("\(streak) day streak")
                        .font(.system(size: 13)).foregroundColor(FlowTheme.ink)
                    Spacer()
                    Text("best \(longest)")
                        .font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Usage by app

private struct AppBreakdownCard: View {
    let breakdown: [(category: AppCategory, count: Int)]
    let total: Int
    let uniqueApps: Int
    let appeared: Bool

    var body: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Usage by category")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 8)
                    Text("APPS USED | \(uniqueApps)")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundColor(FlowTheme.inkSecondary)
                        .lineLimit(1)
                }

                if breakdown.isEmpty {
                    Text("No dictations yet — your most-used apps will appear here.")
                        .font(.system(size: 13))
                        .foregroundColor(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(breakdown.enumerated()), id: \.element.category) { index, item in
                        row(category: item.category, count: item.count, index: index)
                    }
                }
            }
        }
    }

    private func row(category: AppCategory, count: Int, index: Int) -> some View {
        let fraction = total > 0 ? Double(count) / Double(total) : 0
        let pct = Int((fraction * 100).rounded())
        return HStack(spacing: 12) {
            Image(systemName: category.icon)
                .font(.system(size: 14))
                .foregroundColor(FlowTheme.accent)
                .frame(width: 20)
            // Thick bar with the percentage inside the fill (reference style).
            // The track claims full width so this card matches the heatmap card
            // (otherwise the GeometryReader bar collapses the column).
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(FlowTheme.rowHover)
                    .frame(maxWidth: .infinity)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(FlowTheme.accent)
                        .frame(width: appeared ? max(36, geo.size.width * fraction) : 0)
                        .animation(.easeOut(duration: 0.7).delay(0.4 + Double(index) * 0.07), value: appeared)
                }
                Text("\(pct)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.leading, 11)
            }
            .frame(height: 24)
            Text("\(count) \(category.title)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FlowTheme.inkSecondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Coarse category for an app the dictation was inserted into. Wispr-style
/// "Desktop usage" buckets, derived from the tracked target app name.
enum AppCategory: String, CaseIterable {
    case ai, messaging, email, documents, browser, code, notes, other

    var title: String {
        switch self {
        case .ai: return "AI prompts"
        case .messaging: return "Messages"
        case .email: return "Email"
        case .documents: return "Documents"
        case .browser: return "Browser"
        case .code: return "Code"
        case .notes: return "Notes"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .ai: return "sparkles"
        case .messaging: return "message"
        case .email: return "envelope"
        case .documents: return "doc.text"
        case .browser: return "globe"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .notes: return "note.text"
        case .other: return "macwindow"
        }
    }

    static func classify(_ app: String?) -> AppCategory {
        guard let app = app?.lowercased() else { return .other }
        let map: [(AppCategory, [String])] = [
            (.ai, ["chatgpt", "claude", "copilot", "gemini", "perplexity", "poe"]),
            (.messaging, ["slack", "discord", "telegram", "whatsapp", "messages", "teams", "zoom", "signal"]),
            (.email, ["mail", "spark", "outlook", "airmail", "gmail", "superhuman"]),
            (.documents, ["word", "pages", "google docs", "docs", "confluence", "quip"]),
            (.notes, ["notion", "obsidian", "bear", "craft", "notes", "textedit", "drafts"]),
            (.code, ["xcode", "code", "cursor", "terminal", "iterm", "zed", "sublime", "intellij", "pycharm"]),
            (.browser, ["safari", "chrome", "arc", "firefox", "edge", "brave", "orion"]),
        ]
        for (category, keys) in map where keys.contains(where: { app.contains($0) }) {
            return category
        }
        return .other
    }
}

// MARK: - Activity heatmap

private struct ActivityDay {
    let date: Date
    let level: Int
}

private struct ActivityHeatmapSnapshot {
    let currentStreak: Int
    let longestStreak: Int
    let monthLabels: [String]
    let weeks: [[ActivityDay?]]
    private let tooltipsByDay: [Date: DayTooltip]

    static let empty = make(digests: [], calendar: .current, today: Calendar.current.startOfDay(for: Date()))

    func tooltip(_ day: Date) -> DayTooltip {
        tooltipsByDay[day] ?? DayTooltip(date: day, words: 0, apps: 0, topApp: nil)
    }

    static func make(digests: [EntryDigest], calendar: Calendar, today: Date, weeksBack: Int = 13) -> ActivityHeatmapSnapshot {
        var wordsByDay: [Date: Int] = [:]
        var appCountsByDay: [Date: [String: Int]] = [:]
        for entry in digests {
            wordsByDay[entry.day, default: 0] += entry.wordCount
            if let app = entry.app {
                appCountsByDay[entry.day, default: [:]][app, default: 0] += 1
            }
        }

        let daySet = Set(digests.map(\.day))
        let currentStreak = InsightsUsageSnapshot.currentStreak(days: daySet, calendar: calendar, today: today)
        let longestStreak = InsightsUsageSnapshot.longestStreak(days: daySet, calendar: calendar)

        guard let firstDay = calendar.date(byAdding: .day, value: -(weeksBack * 7 - 1), to: today) else {
            return ActivityHeatmapSnapshot(currentStreak: currentStreak,
                                           longestStreak: longestStreak,
                                           monthLabels: [],
                                           weeks: [],
                                           tooltipsByDay: [:])
        }

        let weekday = calendar.component(.weekday, from: firstDay) // 1 = Sunday
        guard let gridStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: firstDay) else {
            return ActivityHeatmapSnapshot(currentStreak: currentStreak,
                                           longestStreak: longestStreak,
                                           monthLabels: [],
                                           weeks: [],
                                           tooltipsByDay: [:])
        }

        var weeks: [[ActivityDay?]] = []
        var tooltips: [Date: DayTooltip] = [:]
        var day = gridStart
        while day <= today {
            var week: [ActivityDay?] = []
            for _ in 0..<7 {
                if day <= today {
                    let words = wordsByDay[day] ?? 0
                    let appCounts = appCountsByDay[day] ?? [:]
                    let topApp = appCounts.max { $0.value < $1.value }?.key
                    let normalizedDay = day
                    week.append(ActivityDay(date: normalizedDay, level: level(forWords: words)))
                    tooltips[normalizedDay] = DayTooltip(date: normalizedDay,
                                                         words: words,
                                                         apps: appCounts.count,
                                                         topApp: topApp)
                } else {
                    week.append(nil)
                }
                if let next = calendar.date(byAdding: .day, value: 1, to: day) {
                    day = next
                } else {
                    break
                }
            }
            weeks.append(week)
        }

        return ActivityHeatmapSnapshot(currentStreak: currentStreak,
                                       longestStreak: longestStreak,
                                       monthLabels: monthLabels(for: weeks, calendar: calendar),
                                       weeks: weeks,
                                       tooltipsByDay: tooltips)
    }

    private static func level(forWords words: Int) -> Int {
        switch words {
        case 0:          return 0
        case 1...200:    return 1
        case 201...600:  return 2
        case 601...1500: return 3
        default:         return 4
        }
    }

    private static func monthLabels(for weeks: [[ActivityDay?]], calendar: Calendar) -> [String] {
        var result = Array(repeating: "", count: weeks.count)
        var lastLabeled = -10
        var prevMonth: Int?
        for (i, week) in weeks.enumerated() {
            guard let first = week.compactMap({ $0?.date }).first else { continue }
            let month = calendar.component(.month, from: first)
            let isBoundary = (prevMonth == nil) || (month != prevMonth!)
            if isBoundary && (i - lastLabeled) >= 3 {
                result[i] = monthAbbr[month - 1]
                lastLabeled = i
            }
            prevMonth = month
        }
        return result
    }

    private static let monthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}

private struct ActivityCard: View {
    let heatmap: ActivityHeatmapSnapshot
    let appeared: Bool

    private let gap: CGFloat = 4
    private let dayLabelW: CGFloat = 34
    @State private var gridWidth: CGFloat = 0

    /// Cell size derived from the card width so the grid fills it edge to edge.
    private var cellSize: CGFloat {
        guard gridWidth > 0 else { return 12 }
        let cols = CGFloat(max(heatmap.weeks.count, 1))
        let avail = gridWidth - dayLabelW - (cols - 1) * gap
        return max(7, min(20, avail / cols))
    }

    var body: some View {
        let cell = cellSize
        return FlowCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(heatmap.currentStreak) day streak")
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("LONGEST STREAK | \(heatmap.longestStreak) DAYS")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.4)
                        .foregroundColor(FlowTheme.inkSecondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }

                // Month labels + grid, centered as a block inside the card so
                // leftover width (cells are size-capped) splits evenly both sides.
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: gap) {
                        Color.clear.frame(width: dayLabelW)
                        ForEach(Array(heatmap.monthLabels.enumerated()), id: \.offset) { _, label in
                            Text(label)
                                .font(.system(size: 10))
                                .foregroundColor(FlowTheme.inkSecondary)
                                .fixedSize()
                                .frame(width: cell, alignment: .leading)
                        }
                    }

                    HStack(alignment: .top, spacing: gap) {
                        // Day labels
                        VStack(alignment: .leading, spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                Text(Self.dayLabels[row])
                                    .font(.system(size: 9))
                                    .foregroundColor(FlowTheme.inkSecondary)
                                    .frame(width: dayLabelW, height: cell, alignment: .leading)
                            }
                        }
                        // Grid
                        ForEach(Array(heatmap.weeks.enumerated()), id: \.offset) { weekIndex, week in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { dayIndex in
                                    let day = week[dayIndex]
                                    HeatCell(
                                        level: day?.level ?? -1,
                                        day: day?.date,
                                        size: cell,
                                        // Start after the card has faded in (~0.55s)
                                        // so the diagonal pop plays on a visible card.
                                        delay: 0.55 + 0.03 * Double(weekIndex + (6 - dayIndex)),
                                        appeared: appeared,
                                        tooltip: heatmap.tooltip
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 6) {
                    Spacer()
                    Text("Less").font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
                    ForEach(1..<5) { lvl in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(HeatCell.color(forLevel: lvl))
                            .frame(width: 12, height: 12)
                    }
                    Text("More").font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
                }
            }
            // Measure the (full) card width to size cells so the grid fills it.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { gridWidth = geo.size.width }
                        .onChange(of: geo.size.width) { gridWidth = $0 }
                }
            )
        }
    }

    static let dayLabels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
}

/// Per-day stats shown in the heatmap hover tooltip.
struct DayTooltip {
    let date: Date
    let words: Int
    let apps: Int
    let topApp: String?
}

/// One heatmap square: pops in (scale + color) on a per-cell delay for the
/// diagonal wave, mirroring the reanimated reference. Hovering an in-range day
/// shows a stats tooltip.
private struct HeatCell: View {
    let level: Int
    let day: Date?
    let size: CGFloat
    let delay: Double
    let appeared: Bool
    let tooltip: (Date) -> DayTooltip

    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(level < 0 ? Color.clear : (appeared ? Self.color(forLevel: level) : Self.color(forLevel: 0)))
            .frame(width: size, height: size)
            .scaleEffect(level < 0 ? 1 : (appeared ? 1 : 0.25))
            .opacity(level < 0 ? 0 : (appeared ? 1 : 0))
            .animation(.spring(response: 0.5, dampingFraction: 0.68).delay(delay), value: appeared)
            .onHover { if day != nil { hovering = $0 } }
            .popover(isPresented: $hovering, arrowEdge: .top) {
                if let day { DayTooltipCard(data: tooltip(day)) }
            }
    }

    static func color(forLevel level: Int) -> Color {
        switch level {
        case 1: return FlowTheme.accent.opacity(0.30)
        case 2: return FlowTheme.accent.opacity(0.50)
        case 3: return FlowTheme.accent.opacity(0.75)
        case 4: return FlowTheme.accent
        default: return FlowTheme.cardStroke.opacity(0.7)
        }
    }
}

/// Hover tooltip for a heatmap day (date + stats), matching the reference.
private struct DayTooltipCard: View {
    let data: DayTooltip

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.dateFormatter.string(from: data.date))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FlowTheme.ink)
            if data.words == 0 {
                Text("No dictations")
                    .font(.system(size: 12))
                    .foregroundColor(FlowTheme.inkSecondary)
            } else {
                Divider().overlay(FlowTheme.cardStroke)
                tipRow("Total words", "\(data.words)")
                tipRow("Total apps used", "\(data.apps)")
                tipRow("Top app", data.topApp ?? "—")
            }
        }
        .padding(14)
        .frame(minWidth: 210, alignment: .leading)
    }

    private func tipRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
            Spacer(minLength: 24)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundColor(FlowTheme.ink)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()
}

enum StatsFormat {
    static func count(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: - Your Voice

/// "Your Voice" tab — a voice profile derived from dictation history (heuristic,
/// no LLM): persona label + description, catchphrase, most-used word, and peak
/// time & place. Modeled on the reference.
private struct YourVoiceView: View {
    @ObservedObject var history: DictationHistory
    let appeared: Bool

    private let milestone = 1000
    private var completedEntries: [DictationEntry] { history.entries.filter(\.isTranscribed) }

    var body: some View {
        if completedEntries.isEmpty {
            FlowCard {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.circle").foregroundColor(FlowTheme.accent)
                    Text("Dictate a little and your voice profile will appear here.")
                        .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
                }
            }
            .appearStagger(3, appeared)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                progressHeader.appearStagger(3, appeared)
                profileCard.appearStagger(4, appeared)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        infoCard(big: catchphrase, label: "CATCHPHRASE", italicSerif: true)
                        infoCard(big: "“\(mostUsedWord)”", label: "MOST USED WORD", italicSerif: true)
                    }
                    .frame(maxWidth: .infinity)
                    peakCard.frame(maxWidth: .infinity)
                }
                .appearStagger(5, appeared)
            }
        }
    }

    // MARK: Pieces

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(FlowTheme.rowHover)
                    Capsule().fill(FlowTheme.accent)
                        .frame(width: appeared ? geo.size.width * progress : 0)
                        .animation(.easeOut(duration: 0.8).delay(0.3), value: appeared)
                }
            }
            .frame(height: 6)
            HStack {
                Text("Created \(Self.dateFormatter.string(from: createdDate))")
                    .font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
                Spacer()
                Text("Next update in \(wordsToNextMilestone) more words")
                    .font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
            }
        }
    }

    private var profileCard: some View {
        FlowCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(profileName)
                        .font(.system(size: 24, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                    Text("VOICE PROFILE")
                        .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                        .foregroundColor(FlowTheme.inkSecondary)
                    Text(profileDescription)
                        .font(.system(size: 15))
                        .foregroundColor(FlowTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                Image(systemName: profileIcon)
                    .font(.system(size: 40))
                    .foregroundColor(FlowTheme.accent)
            }
        }
    }

    private func infoCard(big: String, label: String, italicSerif: Bool) -> some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(big)
                    .font(.system(size: 20, weight: .regular, design: .serif))
                    .italic(italicSerif)
                    .foregroundColor(FlowTheme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(label)
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundColor(FlowTheme.inkSecondary)
            }
        }
    }

    private var peakCard: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20)).foregroundColor(FlowTheme.accent)
                Text(peakTitle)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Text("YOUR PEAK TIME & PLACE")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundColor(FlowTheme.inkSecondary)
                Text(peakDescription)
                    .font(.system(size: 15))
                    .foregroundColor(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: Derived data

    private var totalWords: Int { completedEntries.reduce(0) { $0 + $1.wordCount } }
    private var progress: Double { Double(totalWords % milestone) / Double(milestone) }
    private var wordsToNextMilestone: Int { milestone - (totalWords % milestone) }
    private var createdDate: Date { completedEntries.map { $0.date }.min() ?? Date() }

    private var topCategory: AppCategory {
        var counts: [AppCategory: Int] = [:]
        for e in completedEntries { counts[AppCategory.classify(e.app), default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? .other
    }

    private var topApp: String {
        let names = completedEntries.compactMap { $0.app }
        return Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? "your apps"
    }

    private var avgWords: Int {
        completedEntries.isEmpty ? 0 : totalWords / completedEntries.count
    }

    private var profileName: String {
        switch topCategory {
        case .ai: return "AI Collaborator"
        case .messaging: return "Quick Messenger"
        case .email: return "Inbox Operator"
        case .documents: return "Document Writer"
        case .notes: return "Note Taker"
        case .code: return "Code Narrator"
        case .browser: return "Web Researcher"
        case .other: return "Everyday Dictator"
        }
    }

    private var profileIcon: String { topCategory.icon }

    private var profileDescription: String {
        "Your dictations cluster around \(topCategory.title.lowercased()), most often in \(topApp). You average \(avgWords) words per dictation across \(completedEntries.count) sessions."
    }

    private var catchphrase: String {
        guard let recent = completedEntries.first?.text else { return "—" }
        let clean = recent.replacingOccurrences(of: "\n", with: " ")
        return "“\(clean.count > 70 ? String(clean.prefix(70)) + "…" : clean)”"
    }

    private var mostUsedWord: String {
        let words = completedEntries
            .flatMap { $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
            .filter { $0.count >= 4 }
        return Dictionary(grouping: words, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? "—"
    }

    private var peakTitle: String {
        guard let (weekday, hour) = peakBucket else { return "Anytime" }
        let day = Self.weekdayNames[(weekday - 1) % 7]
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "a.m." : "p.m."
        return "\(day) at \(h12) \(ampm)"
    }

    private var peakDescription: String {
        guard peakBucket != nil else { return "Dictate more to reveal your rhythm." }
        return "That's when you dictate most — usually in \(topApp), \(topCategory.title.lowercased())."
    }

    private var peakBucket: (Int, Int)? {
        let cal = Calendar.current
        let buckets = completedEntries.map { entry -> String in
            let w = cal.component(.weekday, from: entry.date)
            let h = cal.component(.hour, from: entry.date)
            return "\(w)-\(h)"
        }
        guard let topKey = Dictionary(grouping: buckets, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key else { return nil }
        let parts = topKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()
}

// `AppearStagger` / `.appearStagger` now live in FlowTheme.swift (shared by all
// sidebar tabs). Insights re-arms its own `appeared` flag in onAppear above.
