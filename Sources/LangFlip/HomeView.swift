import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Renders a shortcut display name ("Shift+Command+S", "Shift Shift") in
/// compact macOS symbol form ("⇧⌘S", "⇧⇧") so it always fits on one line.
private func compactShortcut(_ name: String) -> String {
    let map: [String: String] = [
        "command": "⌘", "cmd": "⌘",
        "option": "⌥", "opt": "⌥", "alt": "⌥",
        "control": "⌃", "ctrl": "⌃",
        "shift": "⇧",
    ]
    let tokens = name
        .replacingOccurrences(of: "+", with: " ")
        .split(separator: " ")
        .map(String.init)
    return tokens.map { map[$0.lowercased()] ?? $0 }.joined()
}

/// Home screen: a dictation-first hero (the lead feature — an internal Wispr
/// Flow), with the "bonus superpowers" listed in a right rail. The dictation
/// orb is a live control — clicking it starts/stops a hands-free recording
/// through the same `VoiceDictationController` the global hotkey uses.
struct HomeView: View {
    @State private var appeared = false
    @AppStorage("lf.aiMode") private var aiMode = AIMode.backend.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            DisplayText("Welcome back", size: 28)
                .appearStagger(0, appeared)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 22) {
                    DictationHeroCard()
                    HomeHistoryPanel()
                }

                VStack(spacing: 18) {
                    StatsCard()
                    if AIMode(rawValue: aiMode) == .backend {
                        DictationTranscriptionModeCard()
                    }
                    SuperpowersCard()
                }
                .frame(width: 290)
            }
            .appearStagger(1, appeared)
        }
        .appearTrigger($appeared)
    }
}

// MARK: - Dictation mode

private struct DictationTranscriptionModeCard: View {
    var body: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation Mode")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                    Text("Choose speed or quality.")
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                }

                DictationTranscriptionModePicker(expands: true)
            }
        }
    }
}

// MARK: - Stats

private struct StatsCard: View {
    @ObservedObject private var history = DictationHistory.shared
    private var completedEntries: [DictationEntry] { history.entries.filter(\.isTranscribed) }

    var body: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 14) {
                statRow(Self.formatCount(totalWords), "total words")
                statRow("\(completedEntries.count)", completedEntries.count == 1 ? "dictation" : "dictations")
                statRow("\(streak)", streak == 1 ? "day streak" : "day streaks")
            }
        }
    }

    private func statRow(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundColor(FlowTheme.ink)
            Text(unit)
                .font(.system(size: 13))
                .foregroundColor(FlowTheme.inkSecondary)
        }
    }

    private var totalWords: Int {
        completedEntries.reduce(0) { $0 + $1.wordCount }
    }

    /// Consecutive days, ending today, that have at least one dictation.
    private var streak: Int {
        let cal = Calendar.current
        let days = Set(completedEntries.map { cal.startOfDay(for: $0.date) })
        guard !days.isEmpty else { return 0 }
        var count = 0
        var day = cal.startOfDay(for: Date())
        while days.contains(day) {
            count += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    static func formatCount(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fK", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: - Dictation hero

private struct DictationHeroCard: View {
    var body: some View {
        FlowHeroSurface {
            VStack(alignment: .leading, spacing: 10) {
                (
                    Text("Speak - ")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                    + Text("It types")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .italic()
                )
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

                Text("Dictate in any app and Sayful writes it wherever your cursor is.")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Press \(compactShortcut(Settings.shared.dictationHandsFreeShortcut.displayName)) anywhere to dictate, or use the island at the bottom of the screen.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            // Fixed height keeps the banner stable inside the page ScrollView.
            .frame(height: 200)
        }
    }
}

// MARK: - Home history tabs

private enum HomeHistoryTab: String, CaseIterable {
    case dictation = "Dictation"
    case screenText = "Screen Text"
    case speech = "Speech"
}

private struct HomeHistoryPanel: View {
    @State private var tab: HomeHistoryTab = .dictation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FlowSegmented(
                items: HomeHistoryTab.allCases.map { (value: $0, label: $0.rawValue) },
                selection: $tab,
                expands: true
            )

            switch tab {
            case .dictation:
                DictationHistoryList()
            case .screenText:
                OCRHistoryList()
            case .speech:
                TTSHistoryList()
            }
        }
    }
}

// MARK: - Dictation history (full, scrollable, grouped by day)

private struct DictationHistoryList: View {
    @ObservedObject private var history = DictationHistory.shared

    /// Show the most recent page first and reveal older entries on demand, so the
    /// tab opens to a bounded, scannable list rather than the whole history at
    /// once. Rendering is already lazy — this is purely a UX cap.
    private static let pageSize = 50
    @State private var visibleCount = DictationHistoryList.pageSize

    var body: some View {
        if history.entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                FlowSectionLabel("Today")
                FlowCard {
                    HStack(spacing: 12) {
                        Image(systemName: "text.bubble").foregroundColor(FlowTheme.inkSecondary)
                        Text("Your recent dictations will show up here.")
                            .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
                    }
                }
            }
        } else {
            // One flat LazyVStack so only on-screen rows are realized. The
            // history can hold hundreds of entries in a single day; a non-lazy
            // stack laid every row out at once, which scaled scroll jank and
            // hover lag with the entry count. Day grouping is preserved by
            // drawing each row's card segment with rounded top/bottom ends.
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    switch item {
                    case .header(let label, let day):
                        HistoryDayHeader(
                            label: label,
                            noun: "dictations",
                            onDeleteDay: { history.delete(entriesOn: day) },
                            onDeleteAll: { history.deleteAll() }
                        )
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                    case .row(let entry, let isFirst, let isLast):
                        rowCard(entry, isFirst: isFirst, isLast: isLast)
                    }
                }

                if visibleCount < history.entries.count {
                    showMoreButton
                }
            }
        }
    }

    private var showMoreButton: some View {
        Button { visibleCount += Self.pageSize } label: {
            HStack {
                Spacer()
                Text("Show older")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FlowTheme.accent)
                Spacer()
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// One row drawn as its day group's card segment: rounded only at the group's
    /// top/bottom, with the 1px stroke doubling as the inter-row divider where
    /// adjacent segments meet.
    private func rowCard(_ entry: DictationEntry, isFirst: Bool, isLast: Bool) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? FlowTheme.cornerRadius : 0,
            bottomLeadingRadius: isLast ? FlowTheme.cornerRadius : 0,
            bottomTrailingRadius: isLast ? FlowTheme.cornerRadius : 0,
            topTrailingRadius: isFirst ? FlowTheme.cornerRadius : 0,
            style: .continuous
        )
        return DictationRow(entry: entry)
            .background(shape.fill(FlowTheme.card))
            .clipShape(shape)
            .overlay(shape.stroke(FlowTheme.cardStroke, lineWidth: 1))
    }

    /// Headers + rows flattened into one sequence so the whole list is a single
    /// LazyVStack. Each row carries its position in the day group for rounding.
    private var items: [DictationListItem] {
        var result: [DictationListItem] = []
        for group in groups {
            result.append(.header(label: group.label, day: group.day))
            let last = group.entries.count - 1
            for (i, entry) in group.entries.enumerated() {
                result.append(.row(entry: entry, isFirst: i == 0, isLast: i == last))
            }
        }
        return result
    }

    private var groups: [(label: String, day: Date, entries: [DictationEntry])] {
        let cal = Calendar.current
        var result: [(label: String, day: Date, entries: [DictationEntry])] = []
        var currentDay: Date?
        for entry in history.entries.prefix(visibleCount) { // newest first, capped
            let day = cal.startOfDay(for: entry.date)
            if day != currentDay {
                result.append((Self.dayLabel(day), day, []))
                currentDay = day
            }
            result[result.count - 1].entries.append(entry)
        }
        return result
    }

    private static func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: day)
    }
}

/// Flattened list element for the dictation history's single LazyVStack.
private enum DictationListItem: Identifiable {
    case header(label: String, day: Date)
    case row(entry: DictationEntry, isFirst: Bool, isLast: Bool)

    var id: String {
        switch self {
        case .header(let label, _): return "h:\(label)"
        case .row(let entry, _, _): return "r:\(entry.id.uuidString)"
        }
    }
}

// MARK: - OCR history

private struct OCRHistoryList: View {
    @ObservedObject private var history = OCRHistory.shared

    var body: some View {
        if history.entries.isEmpty {
            EmptyHistoryCard(icon: "viewfinder", text: "Captured screen text will show up here.")
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HistoryDayHeader(
                            label: group.label,
                            noun: "captures",
                            onDeleteDay: { history.delete(entriesOn: group.day) },
                            onDeleteAll: { history.deleteAll() }
                        )
                        FlowCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().overlay(FlowTheme.cardStroke) }
                                    OCRHistoryRow(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var groups: [(label: String, day: Date, entries: [OCRHistoryEntry])] {
        groupedByDay(history.entries)
    }
}

private struct OCRHistoryRow: View {
    let entry: OCRHistoryEntry

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(shortTime(entry.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTheme.inkSecondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundColor(FlowTheme.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(entry.wordCount) words")
                    .font(.system(size: 11))
                    .foregroundColor(FlowTheme.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rowIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy text") { copy() }
                .foregroundColor(copied ? FlowTheme.accent : FlowTheme.inkSecondary)
            rowIconButton("trash", help: "Delete") { OCRHistory.shared.delete(entry) }
                .foregroundColor(.red.opacity(0.75))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(hovering ? FlowTheme.rowHover.opacity(0.4) : .clear)
        .onHover { hovering = $0 }
    }

    private func rowIconButton(_ system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? FlowTheme.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .opacity(hovering ? 1 : 0)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - TTS history

private struct TTSHistoryList: View {
    @ObservedObject private var history = TTSHistory.shared

    var body: some View {
        if history.entries.isEmpty {
            EmptyHistoryCard(icon: "speaker.wave.2", text: "Generated speech files will show up here.")
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        HistoryDayHeader(
                            label: group.label,
                            noun: "recordings",
                            onDeleteDay: { history.delete(entriesOn: group.day) },
                            onDeleteAll: { history.deleteAll() }
                        )
                        FlowCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().overlay(FlowTheme.cardStroke) }
                                    TTSHistoryRow(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var groups: [(label: String, day: Date, entries: [TTSHistoryEntry])] {
        groupedByDay(history.entries)
    }
}

private struct TTSHistoryRow: View {
    let entry: TTSHistoryEntry

    @State private var hovering = false
    @State private var playbackRefresh = 0

    var body: some View {
        let isCurrent = AudioFilePlayer.shared.isCurrent(entry.audioURL)
        let isPlaying = isCurrent && AudioFilePlayer.shared.isPlaying

        HStack(alignment: .top, spacing: 14) {
            Text(shortTime(entry.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTheme.inkSecondary)
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundColor(FlowTheme.ink)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(entry.fileExists ? FlowTheme.inkSecondary : .orange)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rowIconButton(isPlaying ? "pause.fill" : "play.fill",
                          help: isPlaying ? "Pause audio" : "Play audio",
                          disabled: !entry.fileExists) {
                SpeechReader.shared.toggleGeneratedAudio(entry.audioURL)
            }
            .foregroundColor(entry.fileExists ? FlowTheme.accent : FlowTheme.inkSecondary.opacity(0.5))
            rowIconButton("trash", help: "Delete") { TTSHistory.shared.delete(entry) }
                .foregroundColor(.red.opacity(0.75))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(hovering ? FlowTheme.rowHover.opacity(0.4) : .clear)
        .animation(.easeInOut(duration: 0.15), value: playbackRefresh)
        .onHover { hovering = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .langFlipTTSStateChanged)) { _ in
            playbackRefresh &+= 1
        }
    }

    private var detail: String {
        if !entry.fileExists { return "Audio file is missing" }
        let pieces = [
            entry.voice,
            entry.model,
            "\(entry.wordCount) words"
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: " · ")
    }

    private func rowIconButton(_ system: String,
                               help: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? FlowTheme.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .disabled(disabled)
        .opacity(hovering ? 1 : 0)
    }
}

/// A day section header ("TODAY") with a quiet trash control on the trailing
/// edge. Tapping it opens a small popover offering to clear just that day or the
/// whole history — shared by the dictation / screen-text / speech lists so the
/// affordance lives in the same spot on every tab.
private struct HistoryDayHeader: View {
    let label: String
    let noun: String
    let onDeleteDay: () -> Void
    let onDeleteAll: () -> Void

    @State private var showMenu = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FlowSectionLabel(label)
            Spacer()
            Button { showMenu = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .frame(width: 24, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hovering ? FlowTheme.rowHover : .clear)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .onHover { hovering = $0 }
            .help("Delete \(noun)")
            .popover(isPresented: $showMenu, arrowEdge: .bottom) {
                // No title and width-to-content: the two actions are
                // self-explanatory, so the popover stays compact with no
                // filler text or empty space.
                VStack(alignment: .leading, spacing: 4) {
                    MenuRowButton(icon: "calendar", title: "\(label) only") {
                        showMenu = false
                        onDeleteDay()
                    }
                    MenuRowButton(icon: "trash", title: "All \(noun)", destructive: true) {
                        showMenu = false
                        onDeleteAll()
                    }
                }
                .padding(8)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// One tappable row inside `HistoryDayHeader`'s popover.
private struct MenuRowButton: View {
    let icon: String
    let title: String
    var destructive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundColor(destructive ? .red.opacity(0.9) : FlowTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? (destructive ? Color.red.opacity(0.12) : FlowTheme.rowHover) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct EmptyHistoryCard: View {
    let icon: String
    let text: String

    var body: some View {
        FlowCard {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundColor(FlowTheme.inkSecondary)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundColor(FlowTheme.inkSecondary)
            }
        }
    }
}

private func groupedByDay<Entry>(_ entries: [Entry]) -> [(label: String, day: Date, entries: [Entry])] {
    let cal = Calendar.current
    var result: [(label: String, day: Date, entries: [Entry])] = []
    var currentDay: Date?
    for entry in entries {
        let date: Date
        if let dictation = entry as? DictationEntry {
            date = dictation.date
        } else if let ocr = entry as? OCRHistoryEntry {
            date = ocr.date
        } else if let tts = entry as? TTSHistoryEntry {
            date = tts.date
        } else {
            continue
        }
        let day = cal.startOfDay(for: date)
        if day != currentDay {
            result.append((dayLabel(day), day, []))
            currentDay = day
        }
        result[result.count - 1].entries.append(entry)
    }
    return result
}

private func dayLabel(_ day: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(day) { return "Today" }
    if cal.isDateInYesterday(day) { return "Yesterday" }
    let f = DateFormatter()
    f.dateFormat = "EEEE, MMM d"
    return f.string(from: day)
}

private func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
}

/// One dictation row. Hovering reveals a copy button (like the reference).
private struct DictationRow: View {
    let entry: DictationEntry

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(FlowTheme.inkSecondary)
                .frame(width: 60, alignment: .leading)
            if entry.isFailed || entry.isRetrying {
                retryableContent
            } else {
                transcriptContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(hovering ? FlowTheme.rowHover.opacity(0.4) : .clear)
        .onHover { hovering = $0 }
    }

    private var transcriptContent: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                if entry.isRecovered {
                    statusPill("Recovered", icon: "checkmark.circle.fill", color: FlowTheme.accent)
                }
                Text(entry.text)
                    .font(.system(size: 14))
                    .foregroundColor(FlowTheme.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(copied ? FlowTheme.accent : FlowTheme.inkSecondary)
                    .frame(width: 26, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(hovering ? FlowTheme.rowHover : .clear)
                    )
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Copy transcript")
            .opacity(hovering ? 1 : 0)
            deleteButton
        }
    }

    private var deleteButton: some View {
        Button { DictationHistory.shared.delete(entry) } label: {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(.red.opacity(0.75))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? FlowTheme.rowHover : .clear)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Delete")
        .opacity(hovering ? 1 : 0)
    }

    private var retryableContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: entry.isRetrying ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundColor(entry.isRetrying ? FlowTheme.accent : .orange)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.isRetrying ? "Retrying transcription" : "Transcription failed")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(FlowTheme.ink)
                Text(retryDetail)
                    .font(.system(size: 12))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                VoiceDictationController.shared.retryFailedTranscription(entry: entry)
            } label: {
                HStack(spacing: 5) {
                    if entry.isRetrying {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(entry.isRetrying ? "Retrying" : "Retry")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(FlowTheme.accent))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Retry transcription")
            .disabled(entry.isRetrying || entry.audioURL == nil)
            deleteButton
        }
    }

    private var retryDetail: String {
        if entry.isRetrying {
            return "Using the saved recording."
        }
        if entry.audioURL != nil {
            let message = entry.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? "Recording saved. Try transcribing it again." : "Recording saved. \(message)"
        }
        return "Recording is no longer available."
    }

    private func statusPill(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    private func copy() {
        guard entry.isTranscribed else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
}

// MARK: - Superpowers rail

private struct SuperpowersCard: View {
    private enum EditablePower: String, Identifiable {
        case dictation, fix, flip, translate, capture, read

        var id: String { rawValue }
    }

    private struct Power: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let shortcut: String
        let editable: EditablePower?
    }

    @AppStorage("lf.homeSuperpowersAttentionShown") private var attentionShown = false
    @AppStorage("lf.translationHotkeyEnabled") private var translationHotkeyEnabled = true
    @AppStorage("lf.translationHotkeyPreset") private var translationHotkeyPreset = GlobalShortcutPreset.shiftSpace.rawValue
    @AppStorage("lf.translationHotkeyCustom") private var translationHotkeyCustom = ""
    @AppStorage("lf.screenTextCaptureHotkeyPreset") private var screenTextCaptureHotkeyPreset = GlobalShortcutPreset.commandShiftS.rawValue
    @AppStorage("lf.screenTextCaptureHotkeyCustom") private var screenTextCaptureHotkeyCustom = ""
    @AppStorage("lf.readSelectionHotkeyPreset") private var readSelectionHotkeyPreset = GlobalShortcutPreset.commandShiftX.rawValue
    @AppStorage("lf.readSelectionHotkeyCustom") private var readSelectionHotkeyCustom = ""
    @AppStorage("lf.hotkeyPreset") private var hotkeyPreset = HotkeyPreset.doubleShift.rawValue
    @AppStorage("lf.dictationHandsFreeEnabled") private var dictationHandsFreeEnabled = true
    @AppStorage("lf.dictationHandsFreeShortcut") private var dictationHandsFreeShortcut = DictationHandsFreeShortcut.leftOption.rawValue
    @AppStorage("lf.dictationPushToTalkShortcut") private var dictationPushToTalkShortcut = DictationPushToTalkShortcut.anyShift.rawValue

    @State private var highlighting = false
    @State private var recording: EditablePower?
    @State private var recordingWarning = ""
    @State private var monitor: Any?

    private var powers: [Power] {
        [
            Power(icon: "mic.fill", title: "Start Dictation", shortcut: compactShortcut(handsFreeShortcutName), editable: .dictation),
            Power(icon: "wand.and.stars", title: "Fix Selected Text", shortcut: coreTapSymbol, editable: .fix),
            Power(icon: "arrow.2.squarepath", title: "Flip Layout", shortcut: coreTapSymbol + coreTapSymbol, editable: .flip),
            Power(icon: "globe", title: "Translate Selected Text", shortcut: shortcutDisplay(for: .translate), editable: .translate),
            Power(icon: "viewfinder", title: "Capture Screen Text", shortcut: shortcutDisplay(for: .capture), editable: .capture),
            Power(icon: "speaker.wave.2", title: "Read Selected Text", shortcut: shortcutDisplay(for: .read), editable: .read),
        ]
    }

    var body: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Superpowers")
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundColor(FlowTheme.ink)
                        Text("Everything else Sayful does, by hotkey.")
                            .font(.system(size: 12))
                            .foregroundColor(FlowTheme.inkSecondary)
                    }
                    Spacer()
                    if hasCustomizedHotkeys {
                        Button(action: resetHotkeys) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(FlowTheme.inkSecondary)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(FlowTheme.paper))
                        }
                        .buttonStyle(.plain)
                        .help("Reset hotkeys")
                    }
                }

                ForEach(powers) { power in
                    SuperpowerRow(
                        icon: power.icon,
                        title: power.title,
                        shortcut: power.shortcut,
                        isEditable: power.editable != nil,
                        isRecording: power.editable != nil && recording == power.editable,
                        onShortcutTap: {
                            if let editable = power.editable {
                                toggleRecording(editable)
                            }
                        }
                    )
                }

                if !recordingWarning.isEmpty {
                    Text(recordingWarning)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .scaleEffect(highlighting ? 1.018 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                .stroke(FlowTheme.accent.opacity(highlighting ? 0.75 : 0), lineWidth: 2)
        )
        .shadow(color: FlowTheme.accent.opacity(highlighting ? 0.20 : 0), radius: 22, y: 10)
        .animation(.spring(response: 0.72, dampingFraction: 0.82), value: highlighting)
        .onAppear(perform: playFirstOpenHighlight)
        .onDisappear(perform: stopRecording)
    }

    private var handsFreeShortcutName: String {
        (DictationHandsFreeShortcut(rawValue: dictationHandsFreeShortcut) ?? .leftOption).displayName
    }

    private var hasCustomizedHotkeys: Bool {
        translationHotkeyCustom.isEmpty == false ||
        screenTextCaptureHotkeyCustom.isEmpty == false ||
        readSelectionHotkeyCustom.isEmpty == false ||
        translationHotkeyPreset != GlobalShortcutPreset.shiftSpace.rawValue ||
        screenTextCaptureHotkeyPreset != GlobalShortcutPreset.commandShiftS.rawValue ||
        readSelectionHotkeyPreset != GlobalShortcutPreset.commandShiftX.rawValue ||
        hotkeyPreset != HotkeyPreset.doubleShift.rawValue ||
        dictationHandsFreeShortcut != DictationHandsFreeShortcut.leftOption.rawValue ||
        dictationPushToTalkShortcut != DictationPushToTalkShortcut.anyShift.rawValue ||
        !dictationHandsFreeEnabled ||
        !translationHotkeyEnabled
    }

    private var coreTapSymbol: String {
        switch HotkeyPreset(rawValue: hotkeyPreset) ?? .doubleShift {
        case .doubleShift: return "⇧"
        case .doubleRightCmd: return "⌘"
        case .doubleRightOption: return "⌥"
        }
    }

    private func shortcutDisplay(for power: EditablePower) -> String {
        compactShortcut(shortcut(for: power).displayName)
    }

    private func shortcut(for power: EditablePower) -> GlobalShortcut {
        switch power {
        case .dictation, .fix, .flip:
            return GlobalShortcutPreset.shiftSpace.shortcut
        case .translate:
            return GlobalShortcut.decode(translationHotkeyCustom)
                ?? (GlobalShortcutPreset(rawValue: translationHotkeyPreset) ?? .shiftSpace).shortcut
        case .capture:
            return GlobalShortcut.decode(screenTextCaptureHotkeyCustom)
                ?? (GlobalShortcutPreset(rawValue: screenTextCaptureHotkeyPreset) ?? .commandShiftS).shortcut
        case .read:
            return GlobalShortcut.decode(readSelectionHotkeyCustom)
                ?? (GlobalShortcutPreset(rawValue: readSelectionHotkeyPreset) ?? .commandShiftX).shortcut
        }
    }

    private func choices(for power: EditablePower) -> [GlobalShortcutPreset] {
        switch power {
        case .dictation, .fix, .flip: return []
        case .translate: return GlobalShortcutPreset.translationChoices
        case .capture: return GlobalShortcutPreset.screenCaptureChoices
        case .read: return GlobalShortcutPreset.readAloudChoices
        }
    }

    private func startRecording(_ power: EditablePower) {
        stopRecording()
        recording = power
        recordingWarning = ""
        ShortcutRecordingState.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event: event, power: power)
        }
    }

    private func toggleRecording(_ power: EditablePower) {
        if recording == power {
            recordingWarning = ""
            stopRecording()
        } else {
            startRecording(power)
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = nil
        ShortcutRecordingState.isRecording = false
    }

    private func handle(event: NSEvent, power: EditablePower) -> NSEvent? {
        if event.keyCode == UInt16(kVK_Escape) {
            recordingWarning = ""
            stopRecording()
            return nil
        }
        switch power {
        case .dictation:
            return handleDictationShortcutEvent(event)
        case .fix, .flip:
            return handleCoreGestureEvent(event)
        case .translate, .capture, .read:
            return handleGlobalShortcutEvent(event, power: power)
        }
    }

    private func handleGlobalShortcutEvent(_ event: NSEvent, power: EditablePower) -> NSEvent? {
        guard event.type == .keyDown else { return nil }
        guard let shortcut = GlobalShortcut.from(event: event) else {
            recordingWarning = "Use modifiers plus a key."
            return nil
        }
        if shortcut.modifiers == GlobalShortcut.shift && shortcut.keyCode != CGKeyCode(kVK_Space) {
            recordingWarning = "Add Control, Option, or Command."
            return nil
        }
        save(shortcut, for: power)
        recordingWarning = ""
        stopRecording()
        return nil
    }

    private func handleDictationShortcutEvent(_ event: NSEvent) -> NSEvent? {
        guard event.type == .flagsChanged else { return nil }
        guard let shortcut = dictationShortcut(from: event) else {
            recordingWarning = "Use Left Option, Left Command, or a supported modifier pair."
            return nil
        }
        dictationHandsFreeEnabled = true
        dictationHandsFreeShortcut = shortcut.rawValue
        recordingWarning = ""
        stopRecording()
        return nil
    }

    private func handleCoreGestureEvent(_ event: NSEvent) -> NSEvent? {
        guard event.type == .flagsChanged else { return nil }
        guard let preset = coreHotkeyPreset(from: event) else {
            recordingWarning = "Use Shift, right Command, or right Option."
            return nil
        }
        hotkeyPreset = preset.rawValue
        recordingWarning = ""
        stopRecording()
        return nil
    }

    private func dictationShortcut(from event: NSEvent) -> DictationHandsFreeShortcut? {
        let keyCode = CGKeyCode(event.keyCode)
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let function = flags.contains(.function)
        let isShiftKey = keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift)
        let isCommandKey = keyCode == CGKeyCode(kVK_Command) || keyCode == CGKeyCode(kVK_RightCommand)
        let isControlKey = keyCode == CGKeyCode(kVK_Control) || keyCode == CGKeyCode(kVK_RightControl)
        let isOptionKey = keyCode == CGKeyCode(kVK_Option) || keyCode == CGKeyCode(kVK_RightOption)

        if function, option, !shift, !command, !control,
           isOptionKey || keyCode == CGKeyCode(kVK_Function) {
            return .fnOption
        }
        if command, shift, !option, !control, isCommandKey || isShiftKey {
            return .commandShift
        }
        if control, shift, !option, !command, isControlKey || isShiftKey {
            return .controlShift
        }
        if option, shift, !command, !control, isOptionKey || isShiftKey {
            return .optionShift
        }
        if keyCode == CGKeyCode(kVK_Option), option, !shift, !command, !control {
            return .leftOption
        }
        if keyCode == CGKeyCode(kVK_Command), command, !shift, !option, !control {
            return .leftCommand
        }
        return nil
    }

    private func coreHotkeyPreset(from event: NSEvent) -> HotkeyPreset? {
        let keyCode = CGKeyCode(event.keyCode)
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)

        if (keyCode == CGKeyCode(kVK_Shift) || keyCode == CGKeyCode(kVK_RightShift)),
           shift, !command, !option, !control {
            return .doubleShift
        }
        if keyCode == CGKeyCode(kVK_RightCommand), command, !shift, !option, !control {
            return .doubleRightCmd
        }
        if keyCode == CGKeyCode(kVK_RightOption), option, !shift, !command, !control {
            return .doubleRightOption
        }
        return nil
    }

    private func save(_ shortcut: GlobalShortcut, for power: EditablePower) {
        if let preset = choices(for: power).first(where: { $0.shortcut == shortcut }) {
            setPreset(preset, for: power)
            setCustom("", for: power)
        } else {
            setCustom(shortcut.encoded, for: power)
        }
    }

    private func setPreset(_ preset: GlobalShortcutPreset, for power: EditablePower) {
        switch power {
        case .dictation, .fix, .flip: break
        case .translate: translationHotkeyPreset = preset.rawValue
        case .capture: screenTextCaptureHotkeyPreset = preset.rawValue
        case .read: readSelectionHotkeyPreset = preset.rawValue
        }
    }

    private func setCustom(_ value: String, for power: EditablePower) {
        switch power {
        case .dictation, .fix, .flip: break
        case .translate: translationHotkeyCustom = value
        case .capture: screenTextCaptureHotkeyCustom = value
        case .read: readSelectionHotkeyCustom = value
        }
    }

    private func resetHotkeys() {
        translationHotkeyEnabled = true
        translationHotkeyPreset = GlobalShortcutPreset.shiftSpace.rawValue
        translationHotkeyCustom = ""
        screenTextCaptureHotkeyPreset = GlobalShortcutPreset.commandShiftS.rawValue
        screenTextCaptureHotkeyCustom = ""
        readSelectionHotkeyPreset = GlobalShortcutPreset.commandShiftX.rawValue
        readSelectionHotkeyCustom = ""
        hotkeyPreset = HotkeyPreset.doubleShift.rawValue
        dictationHandsFreeEnabled = true
        dictationHandsFreeShortcut = DictationHandsFreeShortcut.leftOption.rawValue
        dictationPushToTalkShortcut = DictationPushToTalkShortcut.anyShift.rawValue
    }

    private func playFirstOpenHighlight() {
        guard !attentionShown else { return }
        attentionShown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            withAnimation { highlighting = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                withAnimation { highlighting = false }
            }
        }
    }
}

private struct SuperpowerRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let isEditable: Bool
    let isRecording: Bool
    let onShortcutTap: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(FlowTheme.accent)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .foregroundColor(FlowTheme.ink)
            Spacer()
            ShortcutPill(
                title: shortcut,
                isEditable: isEditable,
                isRecording: isRecording,
                action: onShortcutTap
            )
        }
    }
}

private struct ShortcutPill: View {
    let title: String
    let isEditable: Bool
    let isRecording: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: {
            if isEditable { action() }
        }) {
            Group {
                if isRecording {
                    Circle()
                        .fill(Color(red: 0.9, green: 0.18, blue: 0.16))
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulse ? 1.18 : 0.76)
                        .opacity(pulse ? 1 : 0.58)
                        .frame(width: 38, height: 24)
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(FlowTheme.inkSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: isRecording ? 12 : 6, style: .continuous)
                    .fill(isRecording ? Color(red: 0.9, green: 0.18, blue: 0.16).opacity(0.14) : FlowTheme.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isRecording ? 12 : 6, style: .continuous)
                    .stroke(borderColor, lineWidth: isRecording || hovering ? 1.4 : 0)
            )
            .shadow(color: shadowColor, radius: hovering || isRecording ? 7 : 0, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: isRecording ? 12 : 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = isEditable && $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isRecording)
        .onChange(of: isRecording) { recording in
            pulse = recording
        }
        .onAppear {
            pulse = isRecording
        }
        .animation(isRecording ? .easeInOut(duration: 0.62).repeatForever(autoreverses: true) : .default, value: pulse)
    }

    private var borderColor: Color {
        if isRecording { return Color(red: 0.9, green: 0.18, blue: 0.16).opacity(pulse ? 1 : 0.35) }
        if hovering { return FlowTheme.accent.opacity(0.55) }
        return .clear
    }

    private var shadowColor: Color {
        if isRecording { return Color(red: 0.9, green: 0.18, blue: 0.16).opacity(0.2) }
        if hovering { return FlowTheme.accent.opacity(0.16) }
        return .clear
    }
}
