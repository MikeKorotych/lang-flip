import Foundation

/// A Transform: a custom LLM instruction applied to selected text via a hotkey
/// (Option + a digit). Built-in presets ship by default; users can add their own.
struct Transform: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var subtitle: String
    var prompt: String
    /// Option+digit hotkey (1…9), or nil for no shortcut.
    var shortcut: Int?
    /// Triggered by pressing both Shift keys at once (left+right). Optional so
    /// older persisted transforms decode cleanly (missing → not bound).
    var bothShift: Bool?
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, subtitle: String, prompt: String,
         shortcut: Int? = nil, bothShift: Bool? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.prompt = prompt
        self.shortcut = shortcut
        self.bothShift = bothShift
        self.isBuiltIn = isBuiltIn
    }

    var triggersOnBothShift: Bool { bothShift == true }

    /// Compact badge label for the card. "Both ⇧" (not "⇧⇧") so it reads as
    /// left+right Shift together, not a double-tap.
    var shortcutLabel: String {
        if triggersOnBothShift { return "Both ⇧" }
        return shortcut.map { "⌥\($0)" } ?? "—"
    }
}

/// Persisted transforms + lookup. Seeds built-in presets on first run.
final class TransformStore: ObservableObject {
    static let shared = TransformStore()

    @Published private(set) var transforms: [Transform] = []

    private let key = "lf.transforms"
    private static let schemaKey = "lf.transformsSchema"
    /// Bump when the built-in preset set changes meaningfully. v2: dropped the
    /// Polish preset (≡ single-Shift) and moved Prompt Engineer to both-Shift.
    private static let currentSchema = 2

    private init() {
        load()
        let schema = UserDefaults.standard.integer(forKey: Self.schemaKey)
        if transforms.isEmpty || schema < Self.currentSchema {
            transforms = Self.defaults
            save()
            UserDefaults.standard.set(Self.currentSchema, forKey: Self.schemaKey)
        }
    }

    // MARK: Presets

    // "Polish" used to live here on ⌥1, but it duplicates the single-Shift
    // grammar fix (same proofread action) — so it's gone, and the single-Shift
    // fix is the polish action. Prompt Engineer now fires on both-Shift.
    static var defaults: [Transform] { [promptEngineer] }

    static let promptEngineer = Transform(
        name: "Prompt Engineer",
        subtitle: "Constructs optimal prompts",
        prompt: """
        Take the user's messy, spoken, unstructured thoughts and convert them into a clean, optimized AI prompt using exactly this structure (omit a section only if it truly doesn't apply):

        **Title**
        (1 concise line)

        **Role & stance**
        (who the model is and how it should behave)

        **Task**
        (what the model must do)

        **Context**
        (only what the model needs to know)

        **Inputs available**
        (explicit list)

        **Output requirements**
        (format, structure, tone, length — only if specified; otherwise placeholders)

        **Constraints / Do-nots**
        (bulleted)

        **Examples / References**
        (include all examples verbatim)

        **Execution checklist**
        (short, factual verification list)

        **Conflict resolution**
        (only if applicable)
        """,
        bothShift: true,
        isBuiltIn: true
    )

    // MARK: CRUD

    func add(name: String, subtitle: String, prompt: String, shortcut: Int?, bothShift: Bool? = nil) {
        let new = Transform(name: name, subtitle: subtitle, prompt: prompt, shortcut: shortcut, bothShift: bothShift)
        clearShortcutCollisions(for: new)
        transforms.append(new)
        save()
    }

    func update(_ transform: Transform) {
        guard let idx = transforms.firstIndex(where: { $0.id == transform.id }) else { return }
        clearShortcutCollisions(for: transform)
        transforms[idx] = transform
        save()
    }

    /// A trigger (Option+digit or both-Shift) can be bound to only one
    /// transform; assigning it elsewhere clears it from whoever held it, so
    /// `transform(forShortcut:)` / `bothShiftTransform` stay deterministic.
    private func clearShortcutCollisions(for transform: Transform) {
        if let digit = transform.shortcut {
            for i in transforms.indices where transforms[i].id != transform.id && transforms[i].shortcut == digit {
                transforms[i].shortcut = nil
            }
        }
        if transform.triggersOnBothShift {
            for i in transforms.indices where transforms[i].id != transform.id && transforms[i].triggersOnBothShift {
                transforms[i].bothShift = nil
            }
        }
    }

    func remove(_ transform: Transform) {
        transforms.removeAll { $0.id == transform.id }
        save()
    }

    func resetToDefaults() {
        transforms = Self.defaults
        save()
    }

    /// The transform bound to a given Option+digit, if any.
    func transform(forShortcut digit: Int) -> Transform? {
        transforms.first { $0.shortcut == digit }
    }

    /// The transform fired by the both-Shift gesture (left+right Shift), if any.
    var bothShiftTransform: Transform? {
        transforms.first { $0.triggersOnBothShift }
    }

    /// Digits already taken (so the editor can avoid collisions).
    func usedShortcuts(excluding id: UUID?) -> Set<Int> {
        Set(transforms.filter { $0.id != id }.compactMap { $0.shortcut })
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Transform].self, from: data)
        else { return }
        transforms = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(transforms) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
