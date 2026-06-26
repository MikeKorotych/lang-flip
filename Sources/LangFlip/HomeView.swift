import AppKit
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
                    DictationHistoryList()
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
                    Text("Pick speed or richer transcription.")
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                }

                DictationTranscriptionModePicker()
            }
        }
    }
}

// MARK: - Stats

private struct StatsCard: View {
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 14) {
                statRow(Self.formatCount(totalWords), "total words")
                statRow("\(history.entries.count)", history.entries.count == 1 ? "dictation" : "dictations")
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
        history.entries.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
    }

    /// Consecutive days, ending today, that have at least one dictation.
    private var streak: Int {
        let cal = Calendar.current
        let days = Set(history.entries.map { cal.startOfDay(for: $0.date) })
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
    @StateObject private var state = DictationState()

    private var statusText: String {
        if state.isTranscribing { return "Transcribing…" }
        if state.isRecording { return "Listening… click to stop" }
        return "Click the mic, or hold \(Settings.shared.dictationHandsFreeShortcut.displayName)"
    }

    var body: some View {
        FlowHeroSurface {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    (
                        Text("Speak. ")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                        + Text("It types.")
                            .font(.system(size: 30, weight: .semibold, design: .serif))
                            .italic()
                    )
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)

                    Text("Dictate in any app and Sayful writes it wherever your cursor is.")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DictationOrb(isRecording: state.isRecording,
                             isTranscribing: state.isTranscribing) {
                    VoiceDictationController.shared.toggleRecording()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Fixed height keeps the banner stable inside the page ScrollView.
            .frame(height: 200)
        }
    }
}

/// Circular mic button reflecting dictation state with a pulsing ring while
/// recording and a spinner while transcribing.
private struct DictationOrb: View {
    let isRecording: Bool
    let isTranscribing: Bool
    let action: () -> Void

    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 2)
                        .scaleEffect(pulse ? 1.35 : 1.0)
                        .opacity(pulse ? 0 : 0.7)
                }
                Circle()
                    .fill(isRecording ? Color(red: 0.85, green: 0.32, blue: 0.30) : FlowTheme.accent)
                    .frame(width: 86, height: 86)
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)

                if isTranscribing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 96, height: 96)
        }
        .buttonStyle(.plain)
        .disabled(isTranscribing)
        .onChange(of: isRecording) { recording in
            if recording {
                withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
    }
}

/// Polls `VoiceDictationController` so SwiftUI reflects recording/transcribing
/// state. The controller isn't observable; a lightweight timer keeps the orb
/// honest without invasive changes to the audio pipeline.
private final class DictationState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false

    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            let rec = VoiceDictationController.shared.isRecording
            let trans = VoiceDictationController.shared.isTranscribing
            if rec != self.isRecording { self.isRecording = rec }
            if trans != self.isTranscribing { self.isTranscribing = trans }
        }
    }

    deinit { timer?.invalidate() }
}

// MARK: - Dictation history (full, scrollable, grouped by day)

private struct DictationHistoryList: View {
    @ObservedObject private var history = DictationHistory.shared

    /// Lazy pagination: render only the newest `visibleCount` entries and reveal
    /// the next page when the footer scrolls into view. Keeps the first paint
    /// cheap even when the full history is large.
    private static let pageSize = 25
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
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        FlowSectionLabel(group.label)
                        FlowCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                    if index > 0 { Divider().overlay(FlowTheme.cardStroke) }
                                    DictationRow(entry: entry)
                                }
                            }
                        }
                    }
                }
                if visibleCount < history.entries.count {
                    loadMoreFooter
                }
            }
        }
    }

    /// Sentinel at the bottom of the list. Re-created on each page increment
    /// (via `.id`) so it fires `onAppear` again if it's still on screen —
    /// chaining loads until the viewport is filled or everything is shown.
    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            ProgressView().controlSize(.small)
            Spacer()
        }
        .frame(height: 36)
        .id(visibleCount)
        .onAppear {
            visibleCount = min(visibleCount + Self.pageSize, history.entries.count)
        }
    }

    private var groups: [(label: String, entries: [DictationEntry])] {
        let cal = Calendar.current
        var result: [(label: String, entries: [DictationEntry])] = []
        var currentDay: Date?
        for entry in history.entries.prefix(visibleCount) { // newest first, paginated
            let day = cal.startOfDay(for: entry.date)
            if day != currentDay {
                result.append((Self.dayLabel(day), []))
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
            Text(entry.text)
                .font(.system(size: 14))
                .foregroundColor(FlowTheme.ink)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(hovering ? FlowTheme.rowHover.opacity(0.4) : .clear)
        .onHover { hovering = $0 }
    }

    private func copy() {
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
    private struct Power: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let shortcut: String
    }

    private var powers: [Power] {
        [
            Power(icon: "mic.fill", title: "Start Dictation", shortcut: compactShortcut(Settings.shared.dictationHandsFreeShortcut.displayName)),
            Power(icon: "wand.and.stars", title: "Fix Selected Text", shortcut: compactShortcut("Shift")),
            Power(icon: "arrow.2.squarepath", title: "Flip Layout", shortcut: compactShortcut("Shift Shift")),
            Power(icon: "globe", title: "Translate Selected Text", shortcut: compactShortcut(Settings.shared.translationShortcut.displayName)),
            Power(icon: "viewfinder", title: "Capture Screen Text", shortcut: compactShortcut(Settings.shared.screenTextCaptureShortcut.displayName)),
            Power(icon: "speaker.wave.2", title: "Read Selected Text", shortcut: compactShortcut(Settings.shared.readSelectionShortcut.displayName)),
        ]
    }

    var body: some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Superpowers")
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundColor(FlowTheme.ink)
                    Text("Everything else Sayful does, by hotkey.")
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                }

                ForEach(powers) { power in
                    HStack(spacing: 11) {
                        Image(systemName: power.icon)
                            .font(.system(size: 14))
                            .foregroundColor(FlowTheme.accent)
                            .frame(width: 22)
                        Text(power.title)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .foregroundColor(FlowTheme.ink)
                        Spacer()
                        Text(power.shortcut)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundColor(FlowTheme.inkSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(FlowTheme.paper)
                            )
                    }
                }
            }
        }
    }
}
