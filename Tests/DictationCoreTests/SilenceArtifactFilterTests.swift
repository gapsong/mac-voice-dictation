import Testing
@testable import DictationCore

/// Whisper answers near-silence with subtitle boilerplate rather than an empty
/// string. These tests pin both halves of the trade-off: the boilerplate is
/// rejected, and anything that could plausibly be real dictation is not.
@Suite struct SilenceArtifactFilterTests {

    // MARK: - Rejected

    @Test(arguments: [
        "Untertitelung des ZDF, 2020",
        "untertitelung des zdf, 2020",
        "Untertitel im Auftrag des ZDF, 2021",
        "Untertitelung für funk, 2017",
        "Untertitel der Deutschen Welle",
        "Untertitel von Stephanie Geiges",
        "Untertitelung aufgrund der Amara.org-Community",
        "Subtitles by the Amara.org community",
        "Subtitles created by the community",
        "Subtitling by ZDF",
        "Transcription by ESO, translated by —",
        "Thanks for watching!",
        "Thank you for watching.",
        "Copyright WDR 2021",
        "[Musik]",
        "♪ Musik ♪",
        "(applause)",
        "[BLANK_AUDIO]",
    ])
    func rejectsKnownSilenceArtifacts(_ text: String) {
        #expect(SilenceArtifactFilter.isArtifact(text))
    }

    @Test(arguments: ["", "   ", "\n\t ", "...", "♪♪♪", "[ ]"])
    func rejectsEmptyAndPunctuationOnly(_ text: String) {
        #expect(SilenceArtifactFilter.isArtifact(text))
    }

    // MARK: - Kept

    @Test(arguments: [
        // Mentions a broadcaster but is real speech.
        "Das lief gestern im ZDF.",
        "Ich habe die Doku auf ARTE gesehen.",
        "Schick mir bitte den Link zur Amara-Seite.",
        // Polite phrases Whisper also emits on silence. Deliberately kept: a
        // user may dictate exactly these, and dropping real speech is worse.
        "Vielen Dank.",
        "Danke schön!",
        "Thank you.",
        "Thanks!",
        // Ordinary dictation.
        "Bitte fahre morgen um acht Uhr zum Bahnhof.",
        "Der Server ist wieder erreichbar.",
        "Copyright liegt beim Autor.",
        "Music is important to me.",
        "Wir brauchen mehr Untertitel für die Videos.",
    ])
    func keepsRealSpeech(_ text: String) {
        #expect(!SilenceArtifactFilter.isArtifact(text))
    }

    // MARK: - Normalisation

    @Test func normalizeStripsPunctuationAndCollapsesWhitespace() {
        #expect(SilenceArtifactFilter.normalize("  Untertitelung   des ZDF, 2020! ") == "untertitelung des zdf 2020")
    }

    @Test func normalizeKeepsNonAsciiLetters() {
        #expect(SilenceArtifactFilter.normalize("Für Größe") == "für größe")
    }

    @Test func normalizeReducesMusicalCuesToTheBareWord() {
        #expect(SilenceArtifactFilter.normalize("♪ [Musik] ♪") == "musik")
    }
}
