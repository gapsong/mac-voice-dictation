import Foundation

/// Recognises transcriptions that are Whisper's silence artifacts rather than
/// speech.
///
/// Whisper was trained on subtitled video, so when it is handed near-silence it
/// tends to emit the boilerplate that ends a subtitle track: in German almost
/// always "Untertitelung des ZDF, 2020" and its many variants, in English
/// "Subtitles by the Amara.org community" or "Thanks for watching!". The server
/// returns these as ordinary successful transcriptions, so without this the app
/// pastes them into whatever the user was typing in. Holding the key without
/// speaking should insert nothing instead.
///
/// **Deliberately narrow.** Only whole utterances that are unmistakably
/// subtitle-credit boilerplate or a bracketed sound cue are rejected. Short
/// polite phrases Whisper also emits on silence - "Vielen Dank.", "Thank
/// you." - are *not* filtered, because a user may well dictate exactly those
/// words, and silently swallowing real speech is the worse failure. A rejected
/// utterance surfaces as "No speech detected", so a false positive is visible
/// rather than silent.
public enum SilenceArtifactFilter {

    /// Whole-utterance patterns, matched against `normalize(_:)` output.
    ///
    /// Anchored end to end on purpose: "Das lief im ZDF" is real speech that
    /// merely mentions a broadcaster, and has to survive.
    private static let patterns: [String] = [
        // German subtitle credits. Broadcaster, wording and year all vary
        // ("Untertitelung des ZDF, 2020", "Untertitel im Auftrag des ZDF,
        // 2021", "Untertitelung für funk, 2017", "Untertitel von Stephanie
        // Geiges"), but they all open with the same word - which no real
        // dictation does.
        #"^untertitel\w*\b.*$"#,
        // English subtitle credits.
        #"^subtitle[sd]?\b.*$"#,
        #"^subtitling by\b.*$"#,
        #"^transcription by\b.*$"#,
        // "for watching" is what makes this an outro rather than a plain
        // "Thank you.", which stays.
        #"^thank(s| you)? for watching\b.*$"#,
        #"^amara org( community)?$"#,
        // Copyright stings, but only when a broadcaster follows - "copyright"
        // alone can be real dictation.
        #"^copyright\b.*\b(zdf|ard|wdr|swr|ndr|br|mdr|rbb|arte|orf|srf|bbc|cnn)\b.*$"#,
        // Bracketed or musical sound cues, which are never speech. The
        // brackets and notes are stripped by `normalize`, so match the bare word.
        #"^(musik|music|applaus|applause|lachen|laughter|silence|stille|rauschen|noise|blank audio)$"#,
    ]

    private static let expressions: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [])
    }

    /// True when the transcription carries no real speech and should be
    /// dropped instead of pasted.
    public static func isArtifact(_ text: String) -> Bool {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return true }

        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        return expressions.contains {
            $0.firstMatch(in: normalized, options: [], range: range) != nil
        }
    }

    /// Lowercased, punctuation-free, single-spaced form, so a pattern does not
    /// have to anticipate every way Whisper punctuates the same credit line.
    /// Musical notes and brackets are dropped here rather than matched, which
    /// is what reduces "♪ [Musik] ♪" to a plain "musik". Letters outside ASCII
    /// are kept, so "für" stays "für".
    static func normalize(_ text: String) -> String {
        let stripped = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
