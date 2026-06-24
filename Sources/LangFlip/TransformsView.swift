import SwiftUI

/// Transforms tab: manage LLM "transform" presets. Each transform applies its
/// prompt to the current text selection when its Option+digit hotkey is pressed
/// (handled in EventTap). Modeled on the reference.
struct TransformsView: View {
    @ObservedObject private var store = TransformStore.shared
    @State private var editing: Transform?
    @State private var showingNew = false
    @State private var showingDemo = false
    @State private var appeared = false

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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
        .sheet(isPresented: $showingNew) { TransformEditor(existing: nil) }
        .sheet(item: $editing) { t in TransformEditor(existing: t) }
        .sheet(isPresented: $showingDemo) { TransformDemo() }
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
    @State private var shortcut: Int?

    init(existing: Transform?) {
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _subtitle = State(initialValue: existing?.subtitle ?? "")
        _prompt = State(initialValue: existing?.prompt ?? "")
        _shortcut = State(initialValue: existing?.shortcut)
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
                Picker("", selection: $shortcut) {
                    Text("None").tag(Int?.none)
                    ForEach(1...9, id: \.self) { d in Text("⌥\(d)").tag(Int?.some(d)) }
                }
                .labelsHidden()
                .frame(width: 120)
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
        if var existing {
            existing.name = n
            existing.subtitle = sub.isEmpty ? "Custom transform" : sub
            existing.prompt = prompt
            existing.shortcut = shortcut
            store.update(existing)
        } else {
            store.add(name: n, subtitle: sub.isEmpty ? "Custom transform" : sub, prompt: prompt, shortcut: shortcut)
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
