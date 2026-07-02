enum STTTranscriptionPrompt {
    static let defaultText = ""
    static let legacyVocabularyPrompt = """
    Українська. Русский. English. Суржик.
    затестить фічу переводить язык но.
    GitHub Sayful speech-to-text pipeline.
    """

    static func current() -> String? {
        let prompt = Settings.shared.sttTranscriptionPromptTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }
}
