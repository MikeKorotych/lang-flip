enum STTTranscriptionPrompt {
    static let defaultText = """
    Українська. Русский. English. Суржик.
    затестить фічу переводить язык но.
    GitHub Sayful speech-to-text pipeline.
    """

    static func current() -> String {
        Settings.shared.sttTranscriptionPromptTemplate
    }
}
