//
// ShowcaseRunner.swift
//
// The showcase autopilot: plays a ShowcaseRun's steps (navigate, morning,
// scan clips, then the deck with a spoken reveal), keeps the deck in step
// with the guest's taps and words, rotates it once when nobody touches it
// and chooses the front card after 45 s. Pure logic: the lens, the voice
// and the AI are ShowcaseEffects and time is a ShowcaseClock, so
// tests/showcase-runner drives it deterministically. No SwiftUI, no UIKit;
// ShowcaseViewModel renders.
//
// Cancellation: every await is followed by a generation check. reset()
// bumps the generation, cancels every task the runner owns, clears the
// lens and returns to .idle, so anything that resumes late does nothing.
//

import Foundation

enum ShowcaseClipKind: String, CaseIterable, Equatable {
    case navigate, morning, scan
}

@MainActor
protocol ShowcaseEffects: AnyObject {
    /// Starts a clip on the lens. The runner holds the step for the clip's
    /// duration on its own clock, so a missing lens keeps the timing.
    func play(clip: ShowcaseClipKind) async
    /// Draws the deck (`.chosen`: the confirm card for the front drink)
    /// with at most three lens buttons.
    func show(deck: ShowcaseDeck, mode: DeckMode, buttons: [ShowcaseButton])
    /// Speaks a line and returns when it has been spoken (or was stopped).
    func say(_ text: String) async
    /// Stops the line being spoken; its `say` returns.
    func stopSpeaking()
    /// One AI call; nil on timeout (6 s) or error.
    func ask(system: String, user: String) async -> String?
    func clearLens()
}

@MainActor
final class ShowcaseRunner {
    static let revealUserText = "Introduce the pick."
    static let confirmHold: TimeInterval = 3

    private(set) var step: ShowcaseStep = .idle {
        didSet { if step != oldValue { onStepChange?(step) } }
    }
    /// From start() until the run ends (chosen and cleared) or reset().
    private(set) var isActive = false
    private(set) var mode: DeckMode = .reveal
    private(set) var buttons: [ShowcaseButton] = []
    var deck: ShowcaseDeck { run.deck }
    let strings: ShowcaseStrings
    var onStepChange: ((ShowcaseStep) -> Void)?

    private var run: ShowcaseRun
    private let initialDeck: ShowcaseDeck
    private let effects: ShowcaseEffects
    private let clock: ShowcaseClock
    private let machineDrinkIDs: Set<String>

    /// Bumped by start, reset and the end of a run: work from an older
    /// generation stops at its next check.
    private var generation = 0
    /// Bumped by every guest input: an AI reply or an idle timer from
    /// before the newest input is dropped.
    private var inputSerial = 0
    /// After the conversation brought a card forward, the card it replaced.
    private var backTarget: ShowcaseCard?
    /// Deck lines (reveal, why, reply) being spoken: a line about the old
    /// front card is stopped when the front changes.
    private var deckLinesSpeaking = 0

    private var runTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var chooseTask: Task<Void, Never>?

    init(run: ShowcaseRun, strings: ShowcaseStrings, effects: ShowcaseEffects, clock: ShowcaseClock) {
        self.run = run
        self.initialDeck = run.deck
        self.strings = strings
        self.effects = effects
        self.clock = clock
        self.machineDrinkIDs = Set(run.machineDrinks.map(\.id))
    }

    // MARK: - Run

    /// Plays the steps up to the interactive deck; returns then, or on reset.
    func start() async {
        guard !isActive else { return }
        generation += 1
        let gen = generation
        isActive = true
        run.deck = initialDeck
        backTarget = nil
        inputSerial = 0
        let task = Task { await self.sequence(gen) }
        runTask = task
        await task.value
    }

    func reset() {
        generation += 1
        cancelTasks()
        backTarget = nil
        isActive = false
        effects.clearLens()
        step = .idle
    }

    private func alive(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func sequence(_ gen: Int) async {
        for s in run.steps {
            guard alive(gen) else { return }
            switch s {
            case .navigate: guard await clipStep(s, .navigate, line: strings.spokenNavigate, gen) else { return }
            case .morning: guard await clipStep(s, .morning, line: strings.spokenMorning, gen) else { return }
            case .scan: guard await clipStep(s, .scan, line: strings.spokenScan, gen) else { return }
            case .deck: await deckStep(gen)
            case .idle, .chosen: break
            }
        }
    }

    /// The clip and its line together; the step lasts the longer of the
    /// clip's duration and the speech. The clip itself is not awaited: a
    /// slow lens never stretches the timing.
    private func clipStep(_ s: ShowcaseStep, _ kind: ShowcaseClipKind, line: String, _ gen: Int) async -> Bool {
        step = s
        let effects = self.effects, clock = self.clock
        let duration = run.duration(of: s)
        // A task cancelled before it first runs (reset right after it was
        // created) must not reach the lens or the voice.
        let clip = Task { if !Task.isCancelled { await effects.play(clip: kind) } }
        let speech = Task { if !Task.isCancelled { await effects.say(line) } }
        let timer = Task { try? await clock.sleep(duration) }
        await withTaskCancellationHandler {
            await speech.value
            await timer.value
        } onCancel: {
            clip.cancel()
            speech.cancel()
            timer.cancel()
        }
        return alive(gen)
    }

    private func deckStep(_ gen: Int) async {
        step = .deck
        present(.reveal)
        let front = run.deck.cards[0]
        let serial = inputSerial
        let reply = await effects.ask(system: ShowcasePersona.revealLine(run: run, language: strings.language),
                                      user: Self.revealUserText)
        guard alive(gen) else { return }
        if serial == inputSerial {
            let spoken = reply.map { ShowcaseReply.parse($0, machineDrinkIDs: machineDrinkIDs).spoken } ?? ""
            await sayDeckLine(spoken.isEmpty ? scriptedReveal(front) : spoken)
            guard alive(gen) else { return }
            if serial == inputSerial { present(.why) }
        }
        if serial == inputSerial { restartIdle() }
    }

    // MARK: - Guest input

    func handle(_ command: ShowcaseCommand) {
        guard isActive, step == .deck else { return }
        noteInput()
        switch command {
        case .next:
            run.deck.next()
            backTarget = nil
            frontChanged()
            present(.reveal)
        case .previous:
            run.deck.previous()
            backTarget = nil
            frontChanged()
            present(.reveal)
        case .why:
            present(.why)
            // Idle restarts once the reason has been spoken.
            speak(scriptedReveal(run.deck.cards[0]))
            return
        case .choose:
            choose()
            return
        case .back:
            if let target = backTarget {
                backTarget = nil
                run.deck.bringToFront(drinkID: target.drinkID)
                frontChanged()
                present(.why)
            } else {
                run.deck.previous()
                frontChanged()
                present(.reveal)
            }
        }
        restartIdle()
    }

    /// True for every utterance while a run is active: before the deck and
    /// while the confirm card shows it is ignored, at the deck it is a
    /// command or a question for the showcase persona.
    func handleUtterance(_ text: String) async -> Bool {
        guard isActive else { return false }
        guard step == .deck else { return true }
        if let command = ShowcaseCommand.spoken(text, language: strings.language) {
            handle(command)
            return true
        }
        noteInput()
        let gen = generation, serial = inputSerial
        let reply = await effects.ask(system: ShowcasePersona.systemPrompt(run: run, language: strings.language),
                                      user: text)
        guard alive(gen), serial == inputSerial, step == .deck else { return true }
        let parsed = reply.map { ShowcaseReply.parse($0, machineDrinkIDs: machineDrinkIDs) }
        if let id = parsed?.focusID, id != run.deck.cards[0].drinkID {
            let previous = run.deck.cards[0]
            if run.deck.bringToFront(drinkID: id) {
                backTarget = previous
                present(.why)
            }
        }
        let spoken = parsed?.spoken ?? ""
        speechTask?.cancel()
        await sayDeckLine(spoken.isEmpty ? ShowcaseReply.fallbackLine(strings: strings) : spoken)
        // The idle timers count from the end of the reply, not its start.
        if alive(gen), serial == inputSerial { restartIdle() }
        return true
    }

    // MARK: - Deck

    private func noteInput() {
        inputSerial += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func present(_ newMode: DeckMode) {
        mode = newMode
        switch newMode {
        case .reveal: buttons = [.previous, .why, .next]
        case .why: buttons = backTarget.map { [.choose, .back(name: $0.name)] } ?? [.choose, .next]
        case .chosen: buttons = []
        }
        effects.show(deck: run.deck, mode: newMode, buttons: buttons)
    }

    private func scriptedReveal(_ card: ShowcaseCard) -> String {
        guard let reason = card.reasons.first?.label, !reason.isEmpty else {
            return strings.spokenRevealPlain(drink: card.name)
        }
        return strings.spokenReveal(drink: card.name, reason: reason)
    }

    /// A spoken line the runner does not wait on (the Why answer); the
    /// idle timers restart when it ends, unless a newer input came first.
    private func speak(_ text: String) {
        speechTask?.cancel()
        let gen = generation, serial = inputSerial
        speechTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.sayDeckLine(text)
            if self.alive(gen), serial == self.inputSerial { self.restartIdle() }
        }
    }

    private func sayDeckLine(_ text: String) async {
        deckLinesSpeaking += 1
        defer { deckLinesSpeaking -= 1 }
        await effects.say(text)
    }

    /// The front card changed under a line about the old one: stop it.
    private func frontChanged() {
        if deckLinesSpeaking > 0 { effects.stopSpeaking() }
    }

    /// Idle: one `next()` every 8 s until the first card is back in front,
    /// then rest; 45 s after the last input, choose the front card.
    private func restartIdle() {
        idleTask?.cancel()
        idleTask = nil
        guard isActive, step == .deck else { return }
        let gen = generation, serial = inputSerial
        idleTask = Task { [weak self] in await self?.idleLoop(gen, serial) }
    }

    private func idleLoop(_ gen: Int, _ serial: Int) async {
        func current() -> Bool { alive(gen) && serial == inputSerial && step == .deck }
        let first = run.deck.cards.first?.drinkID
        var elapsed: TimeInterval = 0
        var rotations = 0
        while run.deck.cards.count > 1, rotations < run.deck.cards.count,
              elapsed + ShowcaseTiming.idleRotate < ShowcaseTiming.idleEnd {
            do { try await clock.sleep(ShowcaseTiming.idleRotate) } catch { return }
            guard current() else { return }
            elapsed += ShowcaseTiming.idleRotate
            rotations += 1
            run.deck.next()
            backTarget = nil
            present(.reveal)
            if run.deck.cards.first?.drinkID == first { break }
        }
        do { try await clock.sleep(ShowcaseTiming.idleEnd - elapsed) } catch { return }
        guard current() else { return }
        choose()
    }

    /// The confirm card and line, 3 s, then a clear lens and the end of the run.
    private func choose() {
        guard isActive, step == .deck, let front = run.deck.cards.first else { return }
        noteInput()
        speechTask?.cancel()
        speechTask = nil
        step = .chosen(drinkID: front.drinkID)
        present(.chosen)
        let gen = generation
        let effects = self.effects, clock = self.clock, line = strings.confirmLine
        chooseTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await effects.say(line)
            guard let self, self.alive(gen) else { return }
            do { try await clock.sleep(Self.confirmHold) } catch { return }
            guard self.alive(gen) else { return }
            effects.clearLens()
            self.finish()
        }
    }

    /// The run ended on its own (after a choice).
    private func finish() {
        generation += 1
        cancelTasks()
        backTarget = nil
        isActive = false
        step = .idle
    }

    private func cancelTasks() {
        runTask?.cancel(); runTask = nil
        idleTask?.cancel(); idleTask = nil
        speechTask?.cancel(); speechTask = nil
        chooseTask?.cancel(); chooseTask = nil
    }
}
