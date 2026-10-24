//
// Standalone tests for VisualQueryDetector.shouldCapturePhoto: which
// questions get a camera photo. Run from the repo root:
//   xcrun swiftc \
//     HermesGlasses/Services/DirectClient.swift \
//     HermesGlasses/Services/Providers/AIProvider.swift \
//     HermesGlasses/Services/Providers/AnthropicProvider.swift \
//     HermesGlasses/Services/Providers/OpenAICompatibleProvider.swift \
//     HermesGlasses/Services/Providers/GeminiProvider.swift \
//     tests/visual-query/main.swift -o /tmp/visual-query && /tmp/visual-query
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
func photo(_ text: String) -> Bool { VisualQueryDetector.shouldCapturePhoto(text, lastPhotoAt: nil) }

// Already caught before this suite.
expect(photo("what is this"), "a fixed phrase")
expect(photo("is this bottle cold"), "this + a noun")
expect(!photo("this is a test"), "this + a copula is not visual")
expect(!photo("what time is it"), "no pointer at all")

// A bare pointer ending the question: the wearer is holding it up.
expect(photo("Shall I drink this?"), "a bare this at the end (the Red Bull case)")
expect(photo("should I buy that"), "a bare that at the end")
expect(photo("is this good for me?"), "is this + an adjective")
expect(photo("are these healthy"), "are these + an adjective")
expect(!photo("what do you think about that?"), "about that refers back to the talk")
expect(!photo("is that so"), "is that so is not visual")
expect(!photo("is that right?"), "is that right is not visual")
expect(!photo("that's it"), "that's it is not visual")

// Japanese: これ / この point at something in view.
expect(photo("これ飲んでいい？"), "ja: これ")
expect(photo("この飲み物はどう？"), "ja: この")
expect(!photo("今日の天気は？"), "ja: no pointer")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
