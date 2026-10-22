//
// Standalone tests for GlassesSpeechRouting. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/GlassesSpeechRouting.swift \
//     tests/glasses-speech/main.swift -o "$TMPDIR/glasses-speech" && "$TMPDIR/glasses-speech"
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

// Locale match: prefix on the language code, either separator, any case.
expect(GlassesSpeechRouting.locale("ja-JP", matches: .ja) == true, "ja-JP hears ja")
expect(GlassesSpeechRouting.locale("ja_JP", matches: .ja) == true, "ja_JP hears ja")
expect(GlassesSpeechRouting.locale("ja", matches: .ja) == true, "bare ja hears ja")
expect(GlassesSpeechRouting.locale("EN-us", matches: .en) == true, "EN-us hears en")
expect(GlassesSpeechRouting.locale("en-GB", matches: .en) == true, "en-GB hears en")
expect(GlassesSpeechRouting.locale("en-US", matches: .ja) == false, "en-US does not hear ja")
expect(GlassesSpeechRouting.locale("ja-JP", matches: .en) == false, "ja-JP does not hear en")
expect(GlassesSpeechRouting.locale("jav", matches: .ja) == false, "jav is not ja")
expect(GlassesSpeechRouting.locale("eng", matches: .en) == false, "eng is not en")
expect(GlassesSpeechRouting.locale(nil, matches: .en) == nil, "nil locale is unknown")
expect(GlassesSpeechRouting.locale("  ", matches: .ja) == nil, "blank locale is unknown")

// Showcase choice: the setting gates everything.
func uses(_ enabled: Bool, _ available: Bool, _ locale: String?, _ lang: Language) -> Bool {
    GlassesSpeechRouting.showcaseUsesGlassesSpeech(enabled: enabled, glassesAvailable: available,
                                                   locale: locale, language: lang)
}
expect(!uses(false, true, "en-US", .en), "setting off: phone even when everything matches")
expect(!uses(false, true, nil, .ja), "setting off: phone with an unknown locale")
expect(!uses(true, false, "en-US", .en), "no glasses: phone")
expect(uses(true, true, "en-US", .en), "match: glasses speech")
expect(uses(true, true, "ja-JP", .ja), "ja match: glasses speech")
expect(!uses(true, true, "en-US", .ja), "mismatch: phone")
expect(uses(true, true, nil, .ja), "unknown locale: try glasses speech")

// Default off.
let suite = UserDefaults(suiteName: "glasses-speech-tests")!
suite.removePersistentDomain(forName: "glasses-speech-tests")
expect(!GlassesSpeechRouting.isEnabled(in: suite), "setting defaults to off")
suite.set(true, forKey: GlassesSpeechRouting.settingKey)
expect(GlassesSpeechRouting.isEnabled(in: suite), "setting reads on")
expect(GlassesSpeechRouting.settingKey == "showcase_glasses_speech", "setting key")
suite.removePersistentDomain(forName: "glasses-speech-tests")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
