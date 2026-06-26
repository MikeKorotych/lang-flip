import SwiftUI

/// Transforms tab: manage LLM "transform" presets. Each transform applies its
/// prompt to the current text selection when its Option+digit hotkey is pressed
/// (handled in EventTap). Modeled on the reference.
struct TransformsView: View {
    @ObservedObject private var store = TransformStore.shared
    @ObservedObject private var auth = SupabaseBackendAuth.shared
    @State private var editing: Transform?
    @State private var showingNew = false
    @State private var showingDemo = false
    @State private var appeared = false

    // Selection actions — single-Shift grammar fix + translate. These live here
    // (not in the AI settings tab, which is hidden for normal users) so everyone
    // can toggle them.
    @AppStorage("lf.grammarCheckOnSingleShift") private var grammarOnSingleShift = true
    @AppStorage("lf.translationHotkeyEnabled") private var translationHotkeyEnabled = true
    @AppStorage("lf.translationHotkeyPreset") private var translationHotkeyPreset = GlobalShortcutPreset.shiftSpace.rawValue
    @AppStorage("lf.translationHotkeyCustom") private var translationHotkeyCustom = ""
    @State private var aiReady = false

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DisplayText("Transforms", size: 26)
                .appearStagger(0, appeared)

            FlowHero(
                titleLeading: "Transform works anywhere you",
                titleEmphasis: "write",
                titleTrailing: ".",
                subtitle: "Apply a Transform to rewrite, clean up, or restructure selected text — press its shortcut in any app.",
                ctaTitle: "Try it out",
                ctaAction: { showingDemo = true }
            )
            .appearStagger(1, appeared)

            HStack {
                Text("My Transforms")
                    .font(.system(size: 18, weight: .semibold, design: .serif))
                    .foregroundColor(FlowTheme.ink)
                Spacer()
                FlowSmallButton(title: "Reset to defaults") { store.resetToDefaults() }
                FlowSmallButton(title: "Create New", prominent: true) { showingNew = true }
            }
            .appearStagger(2, appeared)

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(store.transforms) { transform in
                    TransformCard(transform: transform) { editing = transform }
                }
                CreateCard { showingNew = true }
            }
            .appearStagger(3, appeared)

            FlowSettingsGroup("Selection actions") {
                FlowToggleRow(
                    title: "Fix selected text with single Shift",
                    detail: aiReady
                        ? "A single clean Shift tap proofreads the selection — typos, punctuation, grammar — in place."
                        : "Sign in to Sayful Cloud (profile menu) to enable AI text fixes.",
                    isOn: Binding(get: { aiReady && grammarOnSingleShift },
                                  set: { grammarOnSingleShift = $0 }))
                    .disabled(!aiReady)

                FlowToggleRow(
                    title: "Translate selection with \(translationShortcutName)",
                    detail: aiReady
                        ? "\(translationShortcutName) translates the selection into your active keyboard layout's language."
                        : "Sign in to Sayful Cloud to enable translation.",
                    isOn: Binding(get: { aiReady && translationHotkeyEnabled },
                                  set: { translationHotkeyEnabled = $0 }))
                    .disabled(!aiReady)
            }
            .appearStagger(4, appeared)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
        .onAppear(perform: refreshAIReady)
        .onChange(of: auth.isSignedIn) { _ in refreshAIReady() }
        .sheet(isPresented: $showingNew) { TransformEditor(existing: nil) }
        .sheet(item: $editing) { t in TransformEditor(existing: t) }
        .sheet(isPresented: $showingDemo) { TransformDemo() }
    }

    private var translationShortcutName: String {
        GlobalShortcut.decode(translationHotkeyCustom)?.displayName
            ?? (GlobalShortcutPreset(rawValue: translationHotkeyPreset) ?? .shiftSpace).displayName
    }

    private func refreshAIReady() {
        Task {
            let ready = await Task.detached(priority: .userInitiated) {
                AIAssistantManager.shared.isReady
            }.value
            await MainActor.run { aiReady = ready }
        }
    }
}

private struct TransformCard: View {
    let transform: Transform
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        FlowCard(minHeight: 124) {
            VStack(alignment: .leading, spacing: 10) {
                Text(transform.shortcutLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FlowTheme.paper))
                Spacer(minLength: 4)
                Text(transform.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FlowTheme.ink)
                Text(transform.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                .stroke(FlowTheme.accent.opacity(hovering ? 0.5 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

private struct CreateCard: View {
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        FlowCard(minHeight: 124) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FlowTheme.inkSecondary)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(FlowTheme.paper))
                Spacer(minLength: 4)
                Text("Create your own")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FlowTheme.ink)
                Text("Write your own prompt and shortcut")
                    .font(.system(size: 12))
                    .foregroundColor(FlowTheme.inkSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(
            RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                .stroke(FlowTheme.accent.opacity(hovering ? 0.5 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}

// MARK: - Editor

private struct TransformEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = TransformStore.shared

    let existing: Transform?
    @State private var name: String
    @State private var subtitle: String
    @State private var prompt: String
    @State private var trigger: TriggerChoice

    /// How a transform is fired. Modeled as one choice so the picker can show
    /// "Both Shift" (the Prompt Engineer default) alongside the ⌥-digit slots.
    private enum TriggerChoice: Hashable {
        case none
        case bothShift
        case digit(Int)
    }

    init(existing: Transform?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _subtitle = State(initialValue: existing?.subtitle ?? "")
        _prompt = State(initialValue: existing?.prompt ?? "")
        if existing?.triggersOnBothShift == true {
            _trigger = State(initialValue: .bothShift)
        } else if let d = existing?.shortcut {
            _trigger = State(initialValue: .digit(d))
        } else {
            _trigger = State(initialValue: .none)
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisplayText(existing == nil ? "Create Transform" : "Edit Transform", size: 20)

            field("NAME") { FlowTextField(placeholder: "e.g. Boss Mode", text: $name) }
            field("SHORT DESCRIPTION") { FlowTextField(placeholder: "What it does", text: $subtitle) }

            field("KEYBOARD SHORTCUT") {
                Picker("", selection: $trigger) {
                    Text("None").tag(TriggerChoice.none)
                    Text("Both Shift (left + right)").tag(TriggerChoice.bothShift)
                    ForEach(1...9, id: \.self) { d in Text("⌥\(d)").tag(TriggerChoice.digit(d)) }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            field("PROMPT") {
                TextEditor(text: $prompt)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowTheme.paper))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlowTheme.cardStroke, lineWidth: 1))
            }

            HStack(spacing: 10) {
                if existing != nil {
                    FlowSmallButton(title: "Delete") {
                        if let existing { store.remove(existing) }
                        dismiss()
                    }
                }
                Spacer()
                FlowSmallButton(title: "Cancel") { dismiss() }
                FlowSmallButton(title: existing == nil ? "Create" : "Save", prominent: true) {
                    save(); dismiss()
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(FlowTheme.paper)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundColor(FlowTheme.inkSecondary)
            content()
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        let sub = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)

        let digit: Int?
        let bothShift: Bool?
        switch trigger {
        case .none:          digit = nil; bothShift = nil
        case .bothShift:     digit = nil; bothShift = true
        case .digit(let d):  digit = d;   bothShift = nil
        }

        if var existing {
            existing.name = n
            existing.subtitle = sub.isEmpty ? "Custom transform" : sub
            existing.prompt = prompt
            existing.shortcut = digit
            existing.bothShift = bothShift
            store.update(existing)
        } else {
            store.add(name: n, subtitle: sub.isEmpty ? "Custom transform" : sub,
                      prompt: prompt, shortcut: digit, bothShift: bothShift)
        }
    }
}

// MARK: - Demo

private struct TransformDemo: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                DisplayText("How Transforms work", size: 20)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(FlowTheme.inkSecondary)
                }.buttonStyle(.plain)
            }

            Text("Select text in any app, then press a Transform's shortcut. Sayful rewrites the selection in place.")
                .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                demoCard(title: "Original", tint: FlowTheme.inkSecondary,
                         text: "make a blog post about our new cold brew coffee, keep it casual and fun")
                demoCard(title: "Polish ✦", tint: FlowTheme.accent,
                         text: "Write a blog post about our new cold brew coffee. Keep the tone casual and fun.")
            }

            HStack(spacing: 8) {
                Text("Highlight text, then press")
                    .font(.system(size: 13)).foregroundColor(FlowTheme.ink)
                Text("⌥1")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(FlowTheme.rowHover))
                Text("to Transform.")
                    .font(.system(size: 13)).foregroundColor(FlowTheme.ink)
            }
            .padding(.top, 2)

            HStack {
                Spacer()
                FlowSmallButton(title: "Got it", prominent: true) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(FlowTheme.paper)
    }

    private func demoCard(title: String, tint: Color, text: String) -> some View {
        FlowCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(tint)
                Text(text).font(.system(size: 13)).foregroundColor(FlowTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
