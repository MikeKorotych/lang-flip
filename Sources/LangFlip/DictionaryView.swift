import SwiftUI

/// Dictionary section with two sub-tabs (like Insights' Usage/Voice):
/// Languages (default) and Learning. Both moved out of the old Settings tabs
/// (Languages tab, and General's Learning card) to start offloading Settings.
struct DictionaryView: View {
    enum Tab: String, CaseIterable { case languages = "Languages", learning = "Learning" }
    @State private var tab: Tab = .languages

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DisplayText("Dictionary", size: 26)
            tabBar
            if tab == .languages {
                LanguagesPane()
            } else {
                LearningPane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tabBar: some View {
        HStack(spacing: 22) {
            ForEach(Tab.allCases, id: \.self) { t in
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
}

// MARK: - Languages pane

private struct LanguagesPane: View {
    @AppStorage("lf.primaryLanguage") private var primary = "uk"
    @AppStorage("lf.secondaryLanguage") private var secondary = "ru"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FlowSettingsGroup {
                pickerRow(title: "Primary language", selection: $primary) {
                    Text("Українська").tag("uk")
                    Text("Русский").tag("ru")
                }
                .onChange(of: primary) { newValue in
                    if secondary == newValue { secondary = "" }
                }
                pickerRow(title: "Secondary language", selection: $secondary) {
                    Text("None").tag("")
                    if primary != "uk" { Text("Українська").tag("uk") }
                    if primary != "ru" { Text("Русский").tag("ru") }
                }
                Text("Double Shift uses the primary language for English-layout text. Triple Shift uses the secondary language. If the text is already Ukrainian or Russian, both gestures flip it back to English.")
                    .font(.system(size: 12))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowSettingsGroup("Dictionaries") {
                DictionaryPacks()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pickerRow<Content: View>(title: String, selection: Binding<String>, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 14)).foregroundColor(FlowTheme.ink)
            Spacer()
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .frame(width: 150)
        }
    }
}

/// Flow-styled extended-dictionary manager (rebuilt from the old grouped-Form
/// DictionaryPackView, reusing DictionaryManager).
private struct DictionaryPacks: View {
    @State private var stats = DictionaryManager.stats()

    private var hasInstalled: Bool { stats.values.contains { $0.installedCount > 0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dictRow("English", layout: .en)
            dictRow("Українська", layout: .uk)
            dictRow("Русский", layout: .ru)

            Text(hasInstalled
                 ? "Extended dictionaries are active — they install automatically on first launch."
                 : "Downloading extended dictionaries in the background… (installs automatically on first launch).")
                .font(.system(size: 12))
                .foregroundColor(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Uses \(DictionaryManager.extendedPackSource) (\(DictionaryManager.extendedPackLicense)). LangFlip keeps the most useful clean words for each language.")
                .font(.system(size: 11))
                .foregroundColor(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { stats = DictionaryManager.stats() }
        .onReceive(NotificationCenter.default.publisher(for: .langFlipDictionariesChanged)) { _ in
            stats = DictionaryManager.stats()
        }
    }

    private func dictRow(_ title: String, layout: Layout) -> some View {
        let item = stats[layout] ?? .init(bundledCount: 0, installedCount: 0, effectiveCount: 0)
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 14)).foregroundColor(FlowTheme.ink)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(format(item.effectiveCount)) active words")
                    .font(.system(size: 13)).foregroundColor(FlowTheme.inkSecondary)
                if item.installedCount > 0 {
                    Text("extended pack installed")
                        .font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
                }
            }
        }
    }

    private func format(_ value: Int) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
}

// MARK: - Learning pane (moved from General settings)

private struct LearningPane: View {
    @State private var learnedExceptions = LearningPane.sortedExceptions()
    @State private var alwaysFlipRules = LearningPane.sortedAlwaysFlipRules()
    @State private var newException = ""
    @State private var newAlwaysFlipWord = ""
    @State private var newAlwaysFlipTarget = Layout.uk.rawValue

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            FlowSettingsGroup("Always flip", spacing: 16) {
                HStack {
                    Text("Words always rewritten to a layout").font(.system(size: 13)).foregroundColor(FlowTheme.inkSecondary)
                    Spacer()
                    Text("\(alwaysFlipRules.count)").font(.system(size: 13)).foregroundColor(FlowTheme.inkSecondary)
                    FlowSmallButton(title: "Clear") {
                        AlwaysFlipRules.shared.clear(); refresh()
                    }
                    .disabled(alwaysFlipRules.isEmpty).opacity(alwaysFlipRules.isEmpty ? 0.5 : 1)
                }

                HStack(spacing: 8) {
                    FlowTextField(placeholder: "Word to always flip", text: $newAlwaysFlipWord)
                    Picker("Target", selection: $newAlwaysFlipTarget) {
                        // Always-flip turns wrong-layout English typing into a
                        // non-English language; `.en` would be a no-op target.
                        ForEach(Layout.nonEnglish, id: \.self) { layout in
                            Text(layout.displayName).tag(layout.rawValue)
                        }
                    }
                    .labelsHidden().frame(width: 130)
                    FlowSmallButton(title: "Add", prominent: true) {
                        if let target = Layout(rawValue: newAlwaysFlipTarget) {
                            AlwaysFlipRules.shared.add(word: newAlwaysFlipWord, target: target)
                            newAlwaysFlipWord = ""; refresh()
                        }
                    }
                    .disabled(newAlwaysFlipWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(newAlwaysFlipWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }

                if alwaysFlipRules.isEmpty {
                    hint("Add words you always want LangFlip to rewrite to a specific layout, even before the full dictionaries finish loading.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(alwaysFlipRules) { rule in
                            HStack(spacing: 8) {
                                Text(rule.word).font(.system(size: 13, design: .monospaced)).foregroundColor(FlowTheme.ink).lineLimit(1)
                                Image(systemName: "arrow.right").font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
                                Text(rule.target.displayName).font(.system(size: 13)).foregroundColor(FlowTheme.inkSecondary)
                                Spacer()
                                removeButton { AlwaysFlipRules.shared.remove(rule); refresh() }
                            }
                        }
                    }
                }
            }

            FlowSettingsGroup("Remembered exceptions", spacing: 16) {
                HStack {
                    Text("Words never auto-flipped").font(.system(size: 13)).foregroundColor(FlowTheme.inkSecondary)
                    Spacer()
                    Text("\(learnedExceptions.count)").font(.system(size: 13)).foregroundColor(FlowTheme.inkSecondary)
                    FlowSmallButton(title: "Forget all") {
                        BackspaceLearner.shared.clearExceptions(); refresh()
                    }
                    .disabled(learnedExceptions.isEmpty).opacity(learnedExceptions.isEmpty ? 0.5 : 1)
                }

                HStack(spacing: 8) {
                    FlowTextField(placeholder: "Add word to never auto-flip", text: $newException)
                    FlowSmallButton(title: "Add", prominent: true) {
                        BackspaceLearner.shared.addException(newException)
                        newException = ""; refresh()
                    }
                    .disabled(newException.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(newException.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                }

                if learnedExceptions.isEmpty {
                    hint("No learned exceptions yet. When you undo a bad auto-flip with Backspace, LangFlip remembers that word here.")
                } else {
                    VStack(spacing: 8) {
                        ForEach(learnedExceptions, id: \.self) { word in
                            HStack {
                                Text(word).font(.system(size: 13, design: .monospaced)).foregroundColor(FlowTheme.ink).lineLimit(1)
                                Spacer()
                                removeButton { BackspaceLearner.shared.removeException(word); refresh() }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill").foregroundColor(FlowTheme.inkSecondary)
        }
        .buttonStyle(.plain).focusable(false)
    }

    private func refresh() {
        learnedExceptions = Self.sortedExceptions()
        alwaysFlipRules = Self.sortedAlwaysFlipRules()
    }

    private static func sortedExceptions() -> [String] {
        BackspaceLearner.shared.exceptions.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private static func sortedAlwaysFlipRules() -> [AlwaysFlipRules.Rule] {
        AlwaysFlipRules.shared.rules.sorted { lhs, rhs in
            lhs.word == rhs.word
                ? lhs.target.displayName.localizedStandardCompare(rhs.target.displayName) == .orderedAscending
                : lhs.word.localizedStandardCompare(rhs.word) == .orderedAscending
        }
    }
}
