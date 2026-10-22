//
// SpeechFinishGate.swift
//
// Tells a stale "speech finished" from a real one. Replacing an on-device
// line fires one onFinished for the CANCELLED line while the new line is
// already playing; treating it as real flips the voice loop to listening
// and unsuspends the recognizer over the app's own voice (no echo
// cancellation), which the showcase claimer would then send to the AI.
//
// A finish is stale only when one was expected AND something is still
// speaking; if the expected stale finish never comes, the real finish
// (nothing speaking) still counts. Foundation only; tested in
// tests/showcase-runner.
//

import Foundation

struct SpeechFinishGate: Equatable {
    private(set) var pendingStale = 0

    /// A playing on-device line is about to be replaced.
    mutating func expectStale() { pendingStale = 1 }

    mutating func reset() { pendingStale = 0 }

    /// True when this finish belongs to a replaced line and must be ignored.
    mutating func isStale(stillSpeaking: Bool) -> Bool {
        guard pendingStale > 0 else { return false }
        pendingStale = 0
        return stillSpeaking
    }
}
