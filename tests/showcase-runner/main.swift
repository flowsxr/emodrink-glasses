//
// Standalone tests for ShowcaseRunner (the showcase autopilot) with a
// recording fake effects object and the test clock.
// Run from the repo root (the test reads the catalogue JSON off disk):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/DrinkRecommender.swift \
//     HermesGlasses/Services/EmoDrink/Intents.swift \
//     HermesGlasses/Services/EmoDrink/IntentDetector.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkPersona.swift \
//     HermesGlasses/Services/Showcase/VendingMachine.swift \
//     HermesGlasses/Services/Showcase/GuestProfile.swift \
//     HermesGlasses/Services/Showcase/ShowcaseStrings.swift \
//     HermesGlasses/Services/Showcase/ShowcaseDirector.swift \
//     HermesGlasses/Services/Showcase/ShowcasePersona.swift \
//     HermesGlasses/Services/Showcase/ShowcaseClock.swift \
//     HermesGlasses/Services/Showcase/ShowcaseRunner.swift \
//     HermesGlasses/Services/Showcase/SpeechFinishGate.swift \
//     tests/showcase-runner/main.swift -o $TMPDIR/showcase-runner && $TMPDIR/showcase-runner
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)

/// Records every effect as a short string; `ask` answers from `replies`.
@MainActor
final class FakeEffects: ShowcaseEffects {
    var events: [String] = []
    var said: [String] = []
    var asks: [(system: String, user: String)] = []
    var lastDeck: ShowcaseDeck?
    var lastMode: DeckMode?
    var lastButtons: [ShowcaseButton] = []
    /// nil entries mean "the AI timed out".
    var replies: [String?] = []
    var defaultReply: String? = "A fresh start."

    func play(clip: ShowcaseClipKind) async { events.append("play:\(clip)") }

    func show(deck: ShowcaseDeck, mode: DeckMode, buttons: [ShowcaseButton]) {
        events.append("show:\(mode):\(deck.cards[0].drinkID)")
        lastDeck = deck
        lastMode = mode
        lastButtons = buttons
    }

    /// Test-clock seconds each line takes (0 = instant); stopSpeaking ends it.
    var sayDuration: TimeInterval = 0
    var clock: TestShowcaseClock?
    private var speaking: Task<Void, Never>?

    func say(_ text: String) async {
        events.append("say:\(text)")
        said.append(text)
        guard sayDuration > 0, let clock else { return }
        let d = sayDuration
        let t = Task { _ = try? await clock.sleep(d) }
        speaking = t
        await t.value
    }

    func stopSpeaking() {
        events.append("stop")
        speaking?.cancel()
    }

    func ask(system: String, user: String) async -> String? {
        events.append("ask")
        asks.append((system, user))
        return replies.isEmpty ? defaultReply : replies.removeFirst()
    }

    func clearLens() { events.append("clear") }

    var nonSpeech: [String] { events.filter { !$0.hasPrefix("say:") && $0 != "ask" && $0 != "stop" } }
}

func settle() async { for _ in 0..<60 { await Task.yield() } }

func makeRun(navigation: Bool = true, language: Language = .en) -> ShowcaseRun {
    var machine = VendingMachine.sample
    machine.navigationEnabled = navigation
    return try! ShowcaseRun(machine: machine, profile: .preset(.assumed), catalog: catalog,
                            language: language, date: "2026-10-21")
}

@MainActor struct Rig {
    let runner: ShowcaseRunner
    let fx: FakeEffects
    let clock: TestShowcaseClock
    let run: ShowcaseRun
}

@MainActor func rig(navigation: Bool = true, language: Language = .en) -> Rig {
    let run = makeRun(navigation: navigation, language: language)
    let fx = FakeEffects()
    let clock = TestShowcaseClock()
    fx.clock = clock
    let runner = ShowcaseRunner(run: run, strings: ShowcaseStrings(language: language), effects: fx, clock: clock)
    return Rig(runner: runner, fx: fx, clock: clock, run: run)
}

/// Starts the run and plays it through to the interactive deck.
@MainActor func toDeck(_ r: Rig) async {
    Task { await r.runner.start() }
    await settle()
    for step in r.run.steps { await r.clock.advance(by: r.run.duration(of: step)) }
    await settle()
}

let strings = ShowcaseStrings(language: .en)

// MARK: effect order

do {
    let r = rig()
    let first = r.run.deck.cards[0].drinkID
    Task { await r.runner.start() }
    await settle()
    expect(r.runner.step == .navigate, "order: starts on navigate")
    expect(r.runner.isActive, "order: active once started")
    await r.clock.advance(by: 9)
    expect(r.runner.step == .navigate, "order: navigate holds for its 10 s")
    await r.clock.advance(by: 1)
    expect(r.runner.step == .morning, "order: morning after 10 s")
    await r.clock.advance(by: 12)
    expect(r.runner.step == .scan, "order: scan after 12 s more")
    await r.clock.advance(by: 10)
    expect(r.runner.step == .deck, "order: deck after scan")
    let expected = ["play:navigate", "play:morning", "play:scan", "show:reveal:\(first)", "show:why:\(first)"]
    expect(r.fx.nonSpeech == expected, "order: navigate, morning, scan, deck reveal, deck why (got \(r.fx.nonSpeech))")
    expect(r.fx.said.prefix(3) == [strings.spokenNavigate, strings.spokenMorning, strings.spokenScan][...],
           "order: each clip step speaks its line")
    expect(r.fx.said.count == 4 && r.fx.said[3] == "A fresh start.", "order: the AI reveal line is spoken")
    // Reveal: show .reveal, ask, say, show .why.
    let tail = Array(r.fx.events.suffix(4))
    expect(tail == ["show:reveal:\(first)", "ask", "say:A fresh start.", "show:why:\(first)"],
           "order: reveal, ask, say, why (got \(tail))")
    expect(r.fx.asks.first?.system == ShowcasePersona.revealLine(run: r.run, language: .en),
           "order: the reveal asks with the revealLine prompt")
    expect(r.fx.lastButtons == [.choose, .next], "order: the why card has Choose and Next")
    r.runner.reset()
}

// MARK: reveal line

do {
    let r = rig()
    r.fx.defaultReply = "Start slow today. [[drink:wonda-morning-shot]]"
    Task { await r.runner.start() }
    await settle()
    for step in r.run.steps where step != .deck { await r.clock.advance(by: r.run.duration(of: step)) }
    await settle()
    expect(r.fx.said.last == "Start slow today.", "reveal: tags stripped from the AI line")
    expect(r.runner.deck.cards[0].drinkID == r.run.deck.cards[0].drinkID, "reveal: a tag in the reveal moves nothing")
    r.runner.reset()
}

do {
    // No AI reply: the scripted reveal line.
    let r = rig(navigation: false)
    let first = r.run.deck.cards[0]
    r.fx.defaultReply = nil
    Task { await r.runner.start() }
    await settle()
    await r.clock.advance(by: 22)
    await settle()
    expect(r.fx.events.contains("show:reveal:\(first.drinkID)"), "reveal: the deck is shown in reveal mode")
    let fallback = strings.spokenReveal(drink: first.name, reason: first.reasons.first?.label ?? "")
    expect(r.fx.said.last == fallback, "reveal: nil reply speaks the scripted reveal line")
    r.runner.reset()
}

// MARK: navigation off

do {
    let r = rig(navigation: false)
    Task { await r.runner.start() }
    await settle()
    expect(r.runner.step == .morning, "nav off: starts on morning")
    await r.clock.advance(by: 22)
    await settle()
    expect(!r.fx.events.contains("play:navigate"), "nav off: no navigate clip")
    expect(!r.fx.said.contains(strings.spokenNavigate), "nav off: no navigate line")
    expect(r.runner.step == .deck, "nav off: deck after 22 s")
    r.runner.reset()
}

// MARK: commands

do {
    let r = rig()
    await toDeck(r)
    let before = r.runner.deck.cards.map(\.drinkID)
    r.runner.handle(.next)
    await settle()
    expect(r.fx.lastDeck?.cards[0].drinkID == before[1], "next: the deck is shown with a new front card")
    expect(r.runner.deck.cards[0].drinkID == before[1], "next: runner deck moved")
    expect(r.fx.lastMode == .reveal && r.fx.lastButtons == [.previous, .why, .next], "next: reveal buttons ◀ Why ▶")
    r.runner.handle(.previous)
    await settle()
    expect(r.fx.lastDeck?.cards[0].drinkID == before[0], "previous: back to the first card")
    r.runner.handle(.why)
    await settle()
    expect(r.fx.lastMode == .why && r.fx.lastButtons == [.choose, .next], "why: why card with Choose and Next")
    let front = r.runner.deck.cards[0]
    expect(r.fx.said.last == strings.spokenReveal(drink: front.name, reason: front.reasons.first?.label ?? ""),
           "why: the reason is spoken")
    r.runner.reset()
}

// MARK: conversation focus

do {
    let r = rig()
    await toDeck(r)
    // The assumed morning already leads with wonda: move it back first.
    if r.runner.deck.cards[0].drinkID == "wonda-morning-shot" { r.runner.handle(.next) }
    let before = r.runner.deck.cards[0]
    expect(before.drinkID != "wonda-morning-shot", "focus: premise, wonda is not already in front")
    r.fx.replies = ["Try a coffee. [[drink:wonda-morning-shot]]"]
    let claimed = await r.runner.handleUtterance("big meeting at 10, anything stronger?")
    await settle()
    expect(claimed, "focus: the utterance is claimed")
    expect(r.fx.asks.last?.user == "big meeting at 10, anything stronger?", "focus: the utterance is the user text")
    expect(r.fx.asks.last?.system == ShowcasePersona.systemPrompt(run: r.run, language: .en),
           "focus: asked with the showcase persona")
    expect(r.runner.deck.cards[0].drinkID == "wonda-morning-shot", "focus: wonda brought to the front")
    expect(r.fx.said.last == "Try a coffee.", "focus: say(\"Try a coffee.\")")
    expect(r.fx.lastMode == .why && r.fx.lastDeck?.cards[0].drinkID == "wonda-morning-shot", "focus: why card for wonda")
    expect(r.fx.lastButtons == [.choose, .back(name: before.name)], "focus: Choose and Back to the previous front")
    r.runner.handle(.back)
    await settle()
    expect(r.runner.deck.cards[0].drinkID == before.drinkID, "back: the previous front returns")
    expect(r.fx.lastButtons == [.choose, .next], "back: why buttons again")
    r.runner.reset()
}

do {
    let r = rig()
    await toDeck(r)
    let front = r.runner.deck.cards[0].drinkID
    r.fx.replies = ["Water is a fine idea."]
    _ = await r.runner.handleUtterance("what about water")
    expect(r.fx.said.last == "Water is a fine idea.", "untagged reply: spoken")
    expect(r.runner.deck.cards[0].drinkID == front, "untagged reply: front unchanged")
    r.fx.replies = ["Something else. [[drink:not-on-this-machine]]"]
    _ = await r.runner.handleUtterance("got any beer")
    expect(r.runner.deck.cards[0].drinkID == front, "off-machine tag: front unchanged")
    r.fx.replies = ["[[drink:super-h2o]]"]
    _ = await r.runner.handleUtterance("only a tag")
    expect(r.fx.said.last == ShowcaseReply.fallbackLine(strings: strings), "empty spoken part: fallback line")
    r.runner.reset()
}

// MARK: fallbackWhenNoReply

do {
    let r = rig()
    await toDeck(r)
    let front = r.runner.deck.cards[0].drinkID
    let shows = r.fx.events.filter { $0.hasPrefix("show:") }.count
    r.fx.replies = [nil]
    let claimed = await r.runner.handleUtterance("tell me something")
    expect(claimed, "fallbackWhenNoReply: claimed")
    expect(r.fx.said.last == ShowcaseReply.fallbackLine(strings: strings), "fallbackWhenNoReply: say(fallbackLine)")
    expect(r.runner.deck.cards[0].drinkID == front, "fallbackWhenNoReply: deck front unchanged")
    expect(r.fx.events.filter { $0.hasPrefix("show:") }.count == shows, "fallbackWhenNoReply: no redraw")
    r.runner.reset()
}

// MARK: spoken commands and claiming

do {
    let r = rig()
    Task { await r.runner.start() }
    await settle()
    let early = await r.runner.handleUtterance("next")
    expect(early, "claim: an utterance before the deck is still claimed")
    expect(r.runner.step == .navigate && !r.fx.events.contains("ask"), "claim: and ignored before the deck")
    for step in r.run.steps { await r.clock.advance(by: r.run.duration(of: step)) }
    await settle()
    let asks = r.fx.asks.count
    let second = r.runner.deck.cards[1].drinkID
    _ = await r.runner.handleUtterance("Next")
    expect(r.runner.deck.cards[0].drinkID == second, "spoken next: handled as a command")
    expect(r.fx.asks.count == asks, "spoken next: no AI call")
    r.runner.reset()
    let after = await r.runner.handleUtterance("hello")
    expect(!after, "claim: not claimed once reset")
}

do {
    let r = rig()
    let idle = await r.runner.handleUtterance("hello")
    expect(!idle, "claim: not claimed before start")
    r.runner.handle(.next)
    expect(r.fx.events.isEmpty, "commands before start do nothing")
}

// MARK: idle timers

do {
    let r = rig()
    await toDeck(r)
    let order = r.runner.deck.cards.map(\.drinkID)
    expect(order.count == 3, "idle: premise, three cards")
    await r.clock.advance(by: 7)
    expect(r.runner.deck.cards[0].drinkID == order[0], "idle: nothing before 8 s")
    await r.clock.advance(by: 1)
    expect(r.runner.deck.cards[0].drinkID == order[1], "idle: one rotation at 8 s")
    expect(r.fx.lastDeck?.cards[0].drinkID == order[1], "idle: the rotation is shown")
    await r.clock.advance(by: 8)
    expect(r.runner.deck.cards[0].drinkID == order[2], "idle: second rotation at 16 s")
    await r.clock.advance(by: 8)
    expect(r.runner.deck.cards[0].drinkID == order[0], "idle: back to the first card at 24 s")
    let shows = r.fx.events.filter { $0.hasPrefix("show:") }.count
    await r.clock.advance(by: 20)
    expect(r.fx.events.filter { $0.hasPrefix("show:") }.count == shows, "idle: rests after one pass")
    expect(r.runner.step == .deck, "idle: still the deck at 44 s")
    await r.clock.advance(by: 1)
    expect(r.runner.step == .chosen(drinkID: order[0]), "idle: chooses the front card at 45 s")
    expect(r.fx.lastMode == .chosen && r.fx.lastButtons.isEmpty, "idle: confirm card, no buttons")
    expect(r.fx.said.last == strings.confirmLine, "idle: confirm line spoken")
    expect(r.runner.isActive, "chosen: still active while the confirm card shows")
    let early = await r.runner.handleUtterance("next")
    expect(early && r.runner.step == .chosen(drinkID: order[0]), "chosen: utterances claimed and ignored")
    await r.clock.advance(by: 2)
    expect(r.runner.step == .chosen(drinkID: order[0]), "chosen: holds for 3 s")
    await r.clock.advance(by: 1)
    expect(r.runner.step == .idle, "chosen: idle after 3 s")
    expect(r.fx.events.last == "clear", "chosen: lens cleared")
    expect(!r.runner.isActive, "chosen: run over")
}

do {
    let r = rig()
    await toDeck(r)
    let order = r.runner.deck.cards.map(\.drinkID)
    await r.clock.advance(by: 6)
    r.runner.handle(.why)  // input at 6 s restarts both timers
    await settle()
    await r.clock.advance(by: 6)
    expect(r.runner.deck.cards[0].drinkID == order[0], "idle restart: no rotation 12 s in (6 s since input)")
    await r.clock.advance(by: 2)
    expect(r.runner.deck.cards[0].drinkID == order[1], "idle restart: rotation 8 s after the input")
    await r.clock.advance(by: 36)
    expect(r.runner.step == .deck, "idle restart: no choose 44 s after the input")
    await r.clock.advance(by: 1)
    if case .chosen = r.runner.step { expect(true, "idle restart: choose 45 s after the input") }
    else { expect(false, "idle restart: choose 45 s after the input") }
    r.runner.reset()
}

do {
    let r = rig()
    await toDeck(r)
    let front = r.runner.deck.cards[0].drinkID
    r.runner.handle(.choose)
    await settle()
    expect(r.runner.step == .chosen(drinkID: front), "choose: chosen at once")
    expect(r.fx.said.last == strings.confirmLine, "choose: confirm line")
    await r.clock.advance(by: 3)
    expect(r.runner.step == .idle && r.fx.events.last == "clear", "choose: clear and idle after 3 s")
    await r.clock.advance(by: 60)
    expect(r.fx.events.last == "clear", "choose: nothing after the run ends")
}

// MARK: resetMidRun

do {
    let r = rig()
    Task { await r.runner.start() }
    await settle()
    await r.clock.advance(by: 10)
    await r.clock.advance(by: 4)
    expect(r.runner.step == .morning, "resetMidRun: premise, in the morning clip")
    r.runner.reset()
    await settle()
    expect(r.fx.events.last == "clear", "resetMidRun: clearLens()")
    expect(r.runner.step == .idle, "resetMidRun: step .idle")
    let count = r.fx.events.count
    await r.clock.advance(by: 120)
    await settle()
    expect(r.fx.events.count == count, "resetMidRun: no further effects (got \(r.fx.events.suffix(r.fx.events.count - count)))")
    expect(r.runner.step == .idle && !r.runner.isActive, "resetMidRun: stays idle")
    expect(r.clock.pendingSleepers == 0, "resetMidRun: no sleeper left behind")
}

do {
    // Reset while the reveal's AI call is in flight: its reply is dropped.
    final class SlowEffects: ShowcaseEffects {
        let inner = FakeEffects()
        var pending: CheckedContinuation<String?, Never>?
        func play(clip: ShowcaseClipKind) async { await inner.play(clip: clip) }
        func show(deck: ShowcaseDeck, mode: DeckMode, buttons: [ShowcaseButton]) {
            inner.show(deck: deck, mode: mode, buttons: buttons)
        }
        func say(_ text: String) async { await inner.say(text) }
        func ask(system: String, user: String) async -> String? {
            inner.events.append("ask")
            return await withCheckedContinuation { pending = $0 }
        }
        func clearLens() { inner.clearLens() }
        func stopSpeaking() { inner.stopSpeaking() }
    }
    let run = makeRun(navigation: false)
    let fx = SlowEffects()
    let clock = TestShowcaseClock()
    let runner = ShowcaseRunner(run: run, strings: strings, effects: fx, clock: clock)
    Task { await runner.start() }
    await settle()
    await clock.advance(by: 22)
    expect(fx.pending != nil, "reset in reveal: premise, ask pending")
    runner.reset()
    let count = fx.inner.events.count
    fx.pending?.resume(returning: "Late line.")
    await settle()
    await clock.advance(by: 60)
    expect(fx.inner.events.count == count, "reset in reveal: the late reply is dropped")

    // Reset then start again: a clean second run.
    Task { await runner.start() }
    await settle()
    expect(runner.step == .morning, "restart: a new run starts from the top")
    runner.reset()
}

do {
    // A reply that lands after a newer input is dropped.
    final class Held: ShowcaseEffects {
        let inner = FakeEffects()
        var pending: [CheckedContinuation<String?, Never>] = []
        var hold = false
        func play(clip: ShowcaseClipKind) async {}
        func show(deck: ShowcaseDeck, mode: DeckMode, buttons: [ShowcaseButton]) {
            inner.show(deck: deck, mode: mode, buttons: buttons)
        }
        func say(_ text: String) async { await inner.say(text) }
        func ask(system: String, user: String) async -> String? {
            guard hold else { return nil }
            return await withCheckedContinuation { pending.append($0) }
        }
        func clearLens() { inner.clearLens() }
        func stopSpeaking() { inner.stopSpeaking() }
    }
    let run = makeRun(navigation: false)
    let fx = Held()
    let clock = TestShowcaseClock()
    let runner = ShowcaseRunner(run: run, strings: strings, effects: fx, clock: clock)
    Task { await runner.start() }
    await settle()
    await clock.advance(by: 22)
    await settle()
    fx.hold = true
    Task { _ = await runner.handleUtterance("anything stronger") }
    await settle()
    let second = runner.deck.cards[1].drinkID
    runner.handle(.next)
    let saidCount = fx.inner.said.count
    fx.pending.first?.resume(returning: "Coffee. [[drink:wonda-morning-shot]]")
    await settle()
    expect(runner.deck.cards[0].drinkID == second, "stale reply: a newer tap wins")
    expect(fx.inner.said.count == saidCount, "stale reply: not spoken")
    runner.reset()
}

for yields in 1..<8 {
    // Reset within a few turns of Start: nothing goes out after the clear.
    let r = rig()
    Task { await r.runner.start() }
    for _ in 0..<yields { await Task.yield() }
    // Start not yet run: a later start is a fresh run, not a leak.
    guard r.runner.isActive else { r.runner.reset(); await settle(); continue }
    r.runner.reset()
    await settle()
    await r.clock.advance(by: 60)
    let afterClear = r.fx.events.drop { $0 != "clear" }.dropFirst()
    expect(afterClear.isEmpty, "reset after \(yields) yields: nothing after the clear (got \(Array(afterClear)))")
    expect(r.runner.step == .idle && r.clock.pendingSleepers == 0, "reset after \(yields) yields: idle, no sleepers")
}

// MARK: idle waits for speech (fix round 1)

do {
    // A 20 s reply: no rotation until 8 s after it ends.
    let r = rig()
    await toDeck(r)
    let order = r.runner.deck.cards.map(\.drinkID)
    r.fx.sayDuration = 20
    r.fx.replies = ["A long, thoughtful answer."]
    Task { _ = await r.runner.handleUtterance("tell me everything") }
    await settle()
    await r.clock.advance(by: 19)
    expect(r.runner.deck.cards[0].drinkID == order[0], "long reply: no rotation while speaking (19 s)")
    await r.clock.advance(by: 1)   // reply ends at 20 s
    await r.clock.advance(by: 7)
    expect(r.runner.deck.cards[0].drinkID == order[0], "long reply: no rotation 7 s after it ends")
    await r.clock.advance(by: 1)
    expect(r.runner.deck.cards[0].drinkID == order[1], "long reply: rotation 8 s after it ends")
    r.runner.reset()
}

do {
    // The Why line: idle counts from its end too.
    let r = rig()
    await toDeck(r)
    let order = r.runner.deck.cards.map(\.drinkID)
    r.fx.sayDuration = 20
    r.runner.handle(.why)
    await settle()
    await r.clock.advance(by: 27)
    expect(r.runner.deck.cards[0].drinkID == order[0], "why: no rotation 7 s after the reason ends")
    await r.clock.advance(by: 1)
    expect(r.runner.deck.cards[0].drinkID == order[1], "why: rotation 8 s after the reason ends")
    await r.clock.advance(by: 37)
    if case .chosen = r.runner.step { expect(true, "why: choose 45 s after the reason ends") }
    else { expect(false, "why: choose 45 s after the reason ends (step \(r.runner.step))") }
    r.runner.reset()
}

// MARK: a front change stops the old card's line (fix round 1)

do {
    let r = rig(navigation: false)
    let order = r.run.deck.cards.map(\.drinkID)
    Task { await r.runner.start() }
    await settle()
    await r.clock.advance(by: 22)          // clips done; the reveal is speaking
    r.fx.sayDuration = 20
    await settle()
    // The reveal line started instantly (sayDuration was 0); start a long one.
    r.runner.handle(.why)
    await settle()
    expect(!r.fx.events.contains("stop"), "front change: premise, nothing stopped yet")
    r.runner.handle(.next)
    await settle()
    expect(r.fx.events.last(where: { $0 == "stop" }) != nil, "front change: next stops the line about the old card")
    expect(r.fx.lastDeck?.cards[0].drinkID == order[1] && r.fx.lastMode == .reveal, "front change: new front shown")
    r.runner.reset()
}

do {
    // Next during the reveal speech itself: the line stops, no Why for the old card.
    let r = rig(navigation: false)
    r.fx.sayDuration = 0
    Task { await r.runner.start() }
    await settle()
    await r.clock.advance(by: 12)
    await r.clock.advance(by: 9.9)
    r.fx.sayDuration = 20                 // the reveal line will take 20 s
    await r.clock.advance(by: 0.1)        // scan ends: reveal shown, asked, speaking
    let first = r.run.deck.cards[0].drinkID
    expect(r.fx.events.contains("show:reveal:\(first)") && r.fx.said.last == "A fresh start.",
           "reveal stop: premise, the reveal line is speaking")
    r.runner.handle(.next)
    await settle()
    expect(r.fx.events.contains("stop"), "reveal stop: the reveal line is stopped")
    await r.clock.advance(by: 30)
    expect(!r.fx.events.contains("show:why:\(first)"), "reveal stop: no Why card for the old front")
    expect(r.runner.deck.cards[0].drinkID == r.run.deck.cards[1].drinkID, "reveal stop: the new front stays")
    r.runner.reset()
}

do {
    // Idle rotation with nothing speaking never stops speech.
    let r = rig()
    await toDeck(r)
    await r.clock.advance(by: 8)
    expect(!r.fx.events.contains("stop"), "rotation: no stop when nothing speaks")
    r.runner.reset()
}

// MARK: SpeechFinishGate

do {
    var g = SpeechFinishGate()
    expect(!g.isStale(stillSpeaking: true), "gate: nothing expected, a finish is real")
    g.expectStale()
    expect(g.isStale(stillSpeaking: true), "gate: replaced line's finish while the new one plays is stale")
    expect(!g.isStale(stillSpeaking: false), "gate: the next finish is real")
    g.expectStale()
    expect(!g.isStale(stillSpeaking: false), "gate: expected stale never came, nothing speaking: real finish")
    expect(!g.isStale(stillSpeaking: true), "gate: consumed either way")
    g.expectStale()
    g.reset()
    expect(!g.isStale(stillSpeaking: true), "gate: reset (stop) forgets the expectation")
}

// MARK: runsWithoutGlasses

do {
    // play returns at once (no lens): the runner's own clock holds each step.
    let r = rig()
    Task { await r.runner.start() }
    await settle()
    expect(r.runner.step == .navigate, "runsWithoutGlasses: navigate")
    await r.clock.advance(by: 9.5)
    expect(r.runner.step == .navigate, "runsWithoutGlasses: navigate holds its 10 s")
    await r.clock.advance(by: 0.5)
    expect(r.runner.step == .morning, "runsWithoutGlasses: morning at 10 s")
    await r.clock.advance(by: 11.5)
    expect(r.runner.step == .morning, "runsWithoutGlasses: morning holds its 12 s")
    await r.clock.advance(by: 0.5)
    expect(r.runner.step == .scan, "runsWithoutGlasses: scan at 22 s")
    await r.clock.advance(by: 10)
    expect(r.runner.step == .deck, "runsWithoutGlasses: step reaches .deck at 32 s")
    expect(r.fx.events.contains("show:why:\(r.run.deck.cards[0].drinkID)"), "runsWithoutGlasses: full sequence")
    r.runner.reset()
}

do {
    // Speech longer than the clip: the step waits for the speech.
    final class SlowSpeech: ShowcaseEffects {
        let inner = FakeEffects()
        let clock: TestShowcaseClock
        init(clock: TestShowcaseClock) { self.clock = clock }
        func play(clip: ShowcaseClipKind) async { await inner.play(clip: clip) }
        func show(deck: ShowcaseDeck, mode: DeckMode, buttons: [ShowcaseButton]) {
            inner.show(deck: deck, mode: mode, buttons: buttons)
        }
        func say(_ text: String) async {
            await inner.say(text)
            try? await clock.sleep(15)
        }
        func ask(system: String, user: String) async -> String? { nil }
        func clearLens() { inner.clearLens() }
        func stopSpeaking() { inner.stopSpeaking() }
    }
    let run = makeRun(navigation: true)
    let clock = TestShowcaseClock()
    let fx = SlowSpeech(clock: clock)
    let runner = ShowcaseRunner(run: run, strings: strings, effects: fx, clock: clock)
    Task { await runner.start() }
    await settle()
    await clock.advance(by: 12)
    expect(runner.step == .navigate, "long speech: navigate waits past its 10 s clip")
    await clock.advance(by: 3)
    expect(runner.step == .morning, "long speech: morning once the 15 s line ends")
    runner.reset()
    await settle()
    expect(clock.pendingSleepers == 0, "long speech: reset frees the speech sleeper")
}

// MARK: Japanese run

do {
    let r = rig(navigation: false, language: .ja)
    let ja = ShowcaseStrings(language: .ja)
    r.fx.defaultReply = nil
    Task { await r.runner.start() }
    await settle()
    await r.clock.advance(by: 22)
    await settle()
    expect(r.fx.said.first == ja.spokenMorning, "ja: Japanese step line")
    let front = r.run.deck.cards[0]
    expect(r.fx.said.last == ja.spokenReveal(drink: front.name, reason: front.reasons.first?.label ?? ""),
           "ja: Japanese scripted reveal")
    r.fx.replies = [nil]
    _ = await r.runner.handleUtterance("何かある？")
    expect(r.fx.said.last == ja.fallbackConversation, "ja: Japanese fallback line")
    _ = await r.runner.handleUtterance("次へ")
    expect(r.runner.deck.cards[0].drinkID == r.run.deck.cards[1].drinkID, "ja: spoken 次へ moves the deck")
    r.runner.reset()
}

// MARK: test clock

do {
    let clock = TestShowcaseClock()
    var woke: [Int] = []
    Task { try? await clock.sleep(5); woke.append(5) }
    Task { try? await clock.sleep(2); woke.append(2) }
    let cancelled = Task { () -> Bool in
        do { try await clock.sleep(3); return false } catch { return true }
    }
    await settle()
    expect(clock.pendingSleepers == 3, "clock: three sleepers")
    cancelled.cancel()
    await settle()
    expect(await cancelled.value, "clock: a cancelled sleep throws")
    await clock.advance(by: 4)
    expect(woke == [2], "clock: only deadlines passed wake")
    await clock.advance(by: 1)
    expect(woke == [2, 5], "clock: in deadline order")
    expect(clock.now == 5, "clock: now advanced")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
