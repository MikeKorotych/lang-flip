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
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, subtitle: String, prompt: String, shortcut: Int?, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.prompt = prompt
        self.shortcut = shortcut
        self.isBuiltIn = isBuiltIn
    }

    var shortcutLabel: String { shortcut.map { "⌥\($0)" } ?? "—" }
}

/// Persisted transforms + lookup. Seeds built-in presets on first run.
final class TransformStore: ObservableObject {
    static let shared = TransformStore()

    @Published private(set) var transforms: [Transform] = []

    private let key = "lf.transforms"

    private init() {
        load()
        if transforms.isEmpty {
            transforms = Self.defaults
            save()
        }
    }

    // MARK: Presets

    static var defaults: [Transform] { [polish, promptEngineer] }

    static let polish = Transform(
        name: "Polish",
        subtitle: "Improve clarity and conciseness",
        prompt: "Rewrite the text to be clearer and more concise while keeping the original meaning, voice, and tone. Fix grammar, spelling and punctuation. Don't add new information.",
        shortcut: 1,
        isBuiltIn: true
    )

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
        shortcut: 2,
        isBuiltIn: true
    )

    // MARK: CRUD

    func add(name: String, subtitle: String, prompt: String, shortcut: Int?) {
        let new = Transform(name: name, subtitle: subtitle, prompt: prompt, shortcut: shortcut)
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

    /// A digit can be bound to only one transform; assigning it elsewhere
    /// clears it from whoever held it, so `transform(forShortcut:)` is
    /// deterministic.
    private func clearShortcutCollisions(for transform: Transform) {
        guard let digit = transform.shortcut else { return }
        for i in transforms.indices where transforms[i].id != transform.id && transforms[i].shortcut == digit {
            transforms[i].shortcut = nil
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
