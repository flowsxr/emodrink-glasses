//
// MachineDictation.swift
//
// "Add by voice" in the machine editor: Taka reads a machine's drinks aloud
// once and gets the text back. A one-shot SFSpeechRecognizer in the run's
// language on its own AVAudioEngine tap, separate from the voice loop's
// HermesSpeechRecognizer and HermesAudioManager (never touched here).
//
// The caller must not start it while a showcase run or a voice session is
// active: both own the mic. It ends on a final result, after 2 s of silence
// once something was heard, after 8 s of nothing at all, or at 45 s.
// A pause of 0.35 s or more between words becomes a comma, so "Wilkinson
// ... Calpis water ... Juroku-cha" splits into three phrases for matchAll.
//

import AVFoundation
import Foundation
import Observation
import Speech

@MainActor
@Observable
final class MachineDictation {
    enum Phase: Equatable {
        case idle, starting, listening, finishing
    }

    enum DictationError: LocalizedError, Equatable {
        case permissionDenied
        case recognizerUnavailable
        case audio(String)
        case nothingHeard

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone and speech recognition are needed. Allow them in iOS Settings."
            case .recognizerUnavailable:
                return "Speech recognition is not available for this language right now."
            case .audio(let message):
                return "The microphone could not start (\(message))."
            case .nothingHeard:
                return "Nothing was heard. Tap the mic and read the drinks again."
            }
        }
    }

    static let silenceTimeout: TimeInterval = 2
    static let initialTimeout: TimeInterval = 8
    static let maxDuration: TimeInterval = 45
    /// A gap between two words at least this long becomes a separator.
    static let phraseGap: TimeInterval = 0.35

    private(set) var phase: Phase = .idle
    /// The words so far, for the sheet to show while Taka speaks.
    private(set) var transcript = ""

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var continuation: CheckedContinuation<Result<String, DictationError>, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastChange = Date()
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var heardSomething = false
    @ObservationIgnored private var separator = ", "
    /// Bumped per dictation: a cancelled task's late callback is ignored.
    @ObservationIgnored private var generation = 0

    /// Listens once and returns the final text (phrases comma-separated).
    func dictate(language: Language, contextualStrings: [String] = []) async -> Result<String, DictationError> {
        guard phase == .idle else { return .failure(.audio("already listening")) }
        phase = .starting
        transcript = ""

        let permissions = PermissionsCoordinator()
        guard await permissions.request(.speechRecognition) == .granted,
              await permissions.request(.microphone) == .granted else {
            phase = .idle
            return .failure(.permissionDenied)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.sttLocale)),
              recognizer.isAvailable else {
            phase = .idle
            return .failure(.recognizerUnavailable)
        }
        separator = language == .ja ? "、" : ", "

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = Array(contextualStrings.prefix(100))

        let engine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let input = engine.inputNode
            // format: nil follows the node's live format (an explicit one
            // can raise mid route change; see HermesAudioManager).
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            phase = .idle
            return .failure(.audio(error.localizedDescription))
        }

        generation += 1
        let gen = generation
        self.engine = engine
        self.request = request
        startedAt = Date()
        lastChange = Date()
        heardSomething = false
        phase = .listening

        let sep = separator
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result.map { Self.text(of: $0.bestTranscription, separator: sep) }
                let isFinal = result?.isFinal ?? false
                let failed = error != nil
                Task { @MainActor [weak self] in
                    self?.received(text: text, isFinal: isFinal, failed: failed, gen: gen)
                }
            }
            self.watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, gen == self.generation else { return }
                    self.tick()
                }
            }
        }
    }

    /// Taka tapped Done: finish with what was heard.
    func finishNow() {
        guard phase == .listening else { return }
        finish()
    }

    /// The sheet went away: stop without a result.
    func cancel() {
        guard phase != .idle else { return }
        complete(.failure(.nothingHeard))
    }

    // MARK: Private

    private func received(text: String?, isFinal: Bool, failed: Bool, gen: Int) {
        guard gen == generation, phase != .idle else { return }
        if let text = text.map({ Self.clean($0, separator: separator) }), text != transcript {
            transcript = text
            lastChange = Date()
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { heardSomething = true }
        }
        if isFinal || failed {
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            complete(trimmed.isEmpty ? .failure(.nothingHeard) : .success(trimmed))
        }
    }

    private func tick() {
        guard phase == .listening else { return }
        let now = Date()
        if heardSomething, now.timeIntervalSince(lastChange) >= Self.silenceTimeout {
            finish()
        } else if !heardSomething, now.timeIntervalSince(startedAt) >= Self.initialTimeout {
            complete(.failure(.nothingHeard))
        } else if now.timeIntervalSince(startedAt) >= Self.maxDuration {
            finish()
        }
    }

    /// Stops the audio and gives the recognizer a moment for its final
    /// result (which carries word timings, so pauses become commas).
    private func finish() {
        phase = .finishing
        stopAudio()
        request?.endAudio()
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, gen == self.generation, self.phase == .finishing else { return }
            let trimmed = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            self.complete(trimmed.isEmpty ? .failure(.nothingHeard) : .success(trimmed))
        }
    }

    private func complete(_ result: Result<String, DictationError>) {
        generation += 1
        watchdog?.cancel()
        watchdog = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }

    private func stopAudio() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Sentence punctuation the recognizer adds becomes a phrase separator.
    nonisolated static func clean(_ text: String, separator: String) -> String {
        var out = text
        for mark in [".", "。", "?", "？", "!", "！"] {
            out = out.replacingOccurrences(of: mark, with: separator)
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ,、"))
    }

    /// The transcription with a separator wherever the speaker paused.
    /// Partial results often carry no timings; then it is the plain string.
    nonisolated static func text(of transcription: SFTranscription, separator: String) -> String {
        let segments = transcription.segments
        guard segments.count > 1, segments.contains(where: { $0.timestamp > 0 }) else {
            return transcription.formattedString
        }
        let joiner = separator == "、" ? "" : " "
        var out = segments[0].substring
        for (previous, segment) in zip(segments, segments.dropFirst()) {
            let gap = segment.timestamp - (previous.timestamp + previous.duration)
            let alreadySeparated = previous.substring.hasSuffix(",") || previous.substring.hasSuffix("、")
                || previous.substring.hasSuffix(".") || previous.substring.hasSuffix("。")
            out += (gap >= phraseGap && !alreadySeparated) ? separator : joiner
            out += segment.substring
        }
        return out
    }
}
