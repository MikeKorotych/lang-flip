import Foundation

/// Catalog of bundled-model options the user can choose from. All models
/// are downloaded on demand and stored in
/// `~/Library/Application Support/LangFlip/Models/<identifier>/`.
///
/// Sizes and URLs will be filled in once we cut Sprint D (MLX + first
/// model). For now this is a typed placeholder so Settings + the
/// Preferences > Models tab can compile cleanly.
struct AIModelDescriptor: Identifiable, Hashable {
    /// Stable identifier persisted in Settings.shared.activeModelID. e.g.
    /// "qwen-2.5-1.5b-int4".
    let id: String

    /// Short human-readable name. e.g. "Qwen 2.5 1.5B".
    let displayName: String

    /// Compressed size on disk after download, in bytes. Used to render
    /// "1.0 GB" in the UI; nil while we don't have a real number yet.
    let approxSizeBytes: Int?

    /// Brief one-liner shown under the name in the picker.
    let summary: String

    /// Source URL we fetch the model bundle from. nil while not yet
    /// implemented.
    let downloadURL: URL?

    /// Expected SHA-256 of the downloaded archive, hex-lowercase. nil
    /// while not yet implemented.
    let sha256: String?
}

enum ModelCatalog {
    static let all: [AIModelDescriptor] = [
        AIModelDescriptor(
            id: "qwen-2.5-1.5b-int4",
            displayName: "Qwen 2.5 1.5B",
            approxSizeBytes: nil,
            summary: "Multilingual, strong on Slavic languages. Recommended.",
            downloadURL: nil,
            sha256: nil
        ),
        AIModelDescriptor(
            id: "gemma-3-1b-int4",
            displayName: "Gemma 3 1B",
            approxSizeBytes: nil,
            summary: "Smallest option (~700 MB). Fast on entry-level Macs.",
            downloadURL: nil,
            sha256: nil
        ),
        AIModelDescriptor(
            id: "phi-3.5-mini-int4",
            displayName: "Phi-3.5 Mini 3.8B",
            approxSizeBytes: nil,
            summary: "Best reasoning quality at small-model size. Slowest.",
            downloadURL: nil,
            sha256: nil
        ),
    ]

    static func descriptor(forID id: String) -> AIModelDescriptor? {
        return all.first(where: { $0.id == id })
    }
}
