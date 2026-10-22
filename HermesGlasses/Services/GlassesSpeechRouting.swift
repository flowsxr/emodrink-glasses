//
// GlassesSpeechRouting.swift
//
// When the glasses' own speech recognition (MWDATSpeech, `MicSource
// .glassesSpeech`) may hear for the session. It is untested on hardware, so
// it sits behind the Developer setting `showcase_glasses_speech` (default
// OFF): with the setting off nothing here ever picks it. Pure; tested in
// tests/glasses-speech.
//

import Foundation

enum GlassesSpeechRouting {
    /// Developer setting: the showcase listens through the glasses' own
    /// speech recognition instead of the iPhone mic. Default off.
    static let settingKey = "showcase_glasses_speech"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: settingKey)
    }

    /// Whether the glasses' speech locale ("ja-JP", "en_US", "ja") hears
    /// `language`. Nil when the locale is not known yet.
    static func locale(_ locale: String?, matches language: Language) -> Bool? {
        guard let raw = locale?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let code = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        let prefix = language.rawValue
        return code == prefix || code.hasPrefix(prefix + "-")
    }

    /// The showcase's mic at Start: glasses speech only when the setting is
    /// on, a glasses session can start, and the locale does not contradict
    /// the run's language. An unknown locale is tried; the session view model
    /// falls back to the iPhone mic once it hears a mismatch or an error.
    static func showcaseUsesGlassesSpeech(enabled: Bool, glassesAvailable: Bool,
                                          locale: String?, language: Language) -> Bool {
        guard enabled, glassesAvailable else { return false }
        return Self.locale(locale, matches: language) ?? true
    }
}
