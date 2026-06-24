import AppKit
import SwiftUI

/// Snippets tab: manage trigger → expansion pairs. The expansion happens
/// automatically at the end of dictation (see SnippetStore.expand), so this
/// screen is purely for managing the list.
struct SnippetsView: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var showingAdd = false
    @State private var editing: Snippet?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                DisplayText("Snippets", size: 26)
                Spacer()
                FlowSmallButton(title: "Add new", prominent: true) { showingAdd = true }
            }
            .appearStagger(0, appeared)

            FlowHero(
                titleLeading: "The stuff",
                titleEmphasis: "you",
                titleTrailing: "shouldn’t have to re-type.",
                subtitle: "Save anything you say often — your email, an intro, a prompt — and dictate the trigger phrase to drop it in automatically.",
                ctaTitle: "Add new snippet",
                ctaAction: { showingAdd = true }
            )
            .appearStagger(1, appeared)

            Group {
                if store.snippets.isEmpty {
                    FlowCard {
                        HStack(spacing: 12) {
                            Image(systemName: "scissors").foregroundColor(FlowTheme.inkSecondary)
                            Text("No snippets yet. Add one and it'll expand automatically when you dictate its trigger.")
                                .font(.system(size: 14)).foregroundColor(FlowTheme.inkSecondary)
                        }
                    }
                } else {
                    FlowCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(store.snippets.enumerated()), id: \.element.id) { index, snippet in
                                if index > 0 { Divider().overlay(FlowTheme.cardStroke) }
                                SnippetRow(snippet: snippet,
                                           onEdit: { editing = snippet },
                                           onDelete: { store.remove(snippet) })
                            }
                        }
                        // Clip row hover backgrounds to the card's rounded corners so
                        // they don't bleed past the rounded edges.
                        .clipShape(RoundedRectangle(cornerRadius: FlowTheme.cornerRadius - 1, style: .continuous))
                    }
                }
            }
            .appearStagger(2, appeared)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .appearTrigger($appeared)
        .sheet(isPresented: $showingAdd) {
            SnippetEditor(existing: nil)
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(existing: snippet)
        }
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("“\(snippet.trigger)”")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FlowTheme.ink)
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "arrow.right")
                .font(.system(size: 11)).foregroundColor(FlowTheme.inkSecondary)
            Text(snippet.expansion.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 14))
                .foregroundColor(FlowTheme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // Always in the layout (opacity-toggled) so the row height/width
            // stays identical between default and hover.
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12)).foregroundColor(FlowTheme.inkSecondary)
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.plain).focusable(false).help("Delete snippet")
            .opacity(hovering ? 1 : 0)
            .disabled(!hovering)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(hovering ? FlowTheme.rowHover.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onEdit)
    }
}

/// Add/edit sheet for a snippet.
private struct SnippetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SnippetStore.shared

    let existing: Snippet?
    @State private var trigger: String
    @State private var expansion: String

    init(existing: Snippet?) {
        self.existing = existing
        _trigger = State(initialValue: existing?.trigger ?? "")
        _expansion = State(initialValue: existing?.expansion ?? "")
    }

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisplayText(existing == nil ? "Add snippet" : "Edit snippet", size: 20)

            VStack(alignment: .leading, spacing: 6) {
                Text("TRIGGER")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundColor(FlowTheme.inkSecondary)
                FlowTextField(placeholder: "e.g. my email", text: $trigger)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("EXPANSION")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundColor(FlowTheme.inkSecondary)
                TextEditor(text: $expansion)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 140)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FlowTheme.paper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(FlowTheme.cardStroke, lineWidth: 1)
                    )
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
                FlowSmallButton(title: existing == nil ? "Add snippet" : "Save", prominent: true) {
                    save()
                    dismiss()
                }
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(FlowTheme.paper)
    }

    private func save() {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if var existing {
            existing.trigger = t
            existing.expansion = expansion
            store.update(existing)
        } else {
            store.add(trigger: t, expansion: expansion)
        }
    }
}
