//
// Standalone tests for ShowcaseDirector (run, deck, cards).
// Run from the repo root (the test reads the catalogue JSON off disk):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/DrinkRecommender.swift \
//     HermesGlasses/Services/Showcase/VendingMachine.swift \
//     HermesGlasses/Services/Showcase/GuestProfile.swift \
//     HermesGlasses/Services/Showcase/ShowcaseStrings.swift \
//     HermesGlasses/Services/Showcase/ShowcaseDirector.swift \
//     tests/showcase-director/main.swift -o $TMPDIR/showcase-director && $TMPDIR/showcase-director
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let date = "2026-10-21"
let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
let sample = VendingMachine.sample
let assumed = GuestProfile.preset(.assumed)

func makeRun(_ m: VendingMachine = sample, _ p: GuestProfile = assumed, _ l: Language = .en) -> ShowcaseRun {
    try! ShowcaseRun(machine: m, profile: p, catalog: catalog, language: l, date: date)
}

// Steps
var run = makeRun()
expect(run.steps == [.navigate, .morning, .scan, .deck], "steps with navigation")
var noNav = sample; noNav.navigationEnabled = false
expect(makeRun(noNav).steps == [.morning, .scan, .deck], "no navigate step when off")
expect(run.duration(of: .navigate) == 10 && run.duration(of: .morning) == 12 && run.duration(of: .scan) == 10, "durations")
expect(ShowcaseTiming.hour == 9 && ShowcaseTiming.idleRotate == 8 && ShowcaseTiming.idleEnd == 45, "timing constants")
expect(ShowcaseDefaults.defaultLanguage == .en, "default language en")

// Deck
expect(run.deck.cards.count == 3, "deck has 3 cards")
expect(run.deck.cards.allSatisfy { sample.drinkIDs.contains($0.drinkID) }, "every card is in the machine")
expect(run.machineDrinks.count == 9, "machineDrinks has nine")
let machineCatalog = DrinkCatalog(drinks: run.machineDrinks)
let rec = DrinkRecommender.recommend(snapshot: run.snapshot, catalog: machineCatalog, hour: 9, lowSugar: false, language: .en)!
expect(run.deck.cards[0].drinkID == rec.pick.id, "front card is the recommender pick")
expect(run.deck.cards.map(\.drinkID) == ([rec.pick] + rec.alternates).map(\.id), "deck is pick + alternates")
expect(run.snapshot == assumed.snapshot(date: date), "snapshot comes from the profile")
expect(makeRun().deck == makeRun().deck, "same run twice gives equal decks")

// next / previous
var d = run.deck
let original = d
d.next(); d.next(); d.next()
expect(d == original, "next x3 returns to original")
var d2 = original
d2.next()
expect(d2.cards[0].drinkID == original.cards[1].drinkID && d2.cards[2].drinkID == original.cards[0].drinkID, "next rotates front to back")
d2.previous()
expect(d2 == original, "previous undoes next")

// bringToFront
var b = run.deck
let outside = sample.drinkIDs.first { id in !b.cards.contains { $0.drinkID == id } }!
expect(b.bringToFront(drinkID: outside), "bringToFront outside-deck drink returns true")
expect(b.cards[0].drinkID == outside && b.cards.count == 3, "inserted at front, still 3 cards")
expect(b.cards.dropFirst().map(\.drinkID) == Array(original.cards.map(\.drinkID).prefix(2)), "last card dropped, rest keep order")
var c = run.deck
let third = original.cards[2].drinkID
expect(c.bringToFront(drinkID: third), "bringToFront in-deck drink returns true")
expect(c.cards.map(\.drinkID) == [third, original.cards[0].drinkID, original.cards[1].drinkID], "in-deck move keeps order of the rest")
var e = run.deck
expect(!e.bringToFront(drinkID: "coca-cola"), "bringToFront unknown drink is false")
expect(e == run.deck, "deck unchanged after failure")

// Two drinks
var two = sample; two.drinkIDs = Array(sample.drinkIDs.prefix(2))
let twoRun = makeRun(two)
expect(twoRun.deck.cards.count == 2, "deckWithTwoDrinks: two cards")
var t = twoRun.deck
let t0 = t
t.next()
expect(t.cards[0].drinkID == t0.cards[1].drinkID, "two-card next alternates")
t.next()
expect(t == t0, "two-card next twice returns")

// Empty machine
var empty = sample; empty.drinkIDs = []; empty.customDrinks = []
var threw = false
do { _ = try ShowcaseRun(machine: empty, profile: assumed, catalog: catalog, language: .en, date: date) }
catch { threw = (error == .emptyMachine) }
expect(threw, "emptyMachineCannotStart")

// Unknown catalogue ids are skipped, not fatal
var ghost = sample; ghost.drinkIDs = ["nope"]; ghost.customDrinks = []
var ghostThrew = false
do { _ = try ShowcaseRun(machine: ghost, profile: assumed, catalog: catalog, language: .en, date: date) }
catch { ghostThrew = (error == .emptyMachine) }
expect(ghostThrew, "machine with only unknown ids is empty")

// Japanese names, custom drinks
let ja = makeRun(sample, assumed, .ja)
let jaFront = catalog.drink(id: ja.deck.cards[0].drinkID)!
expect(ja.deck.cards[0].name == jaFront.nameJa, "Japanese card uses nameJa")
expect(makeRun().deck.cards[0].name == catalog.drink(id: run.deck.cards[0].drinkID)!.name, "English card uses name")
var cm = sample
cm.drinkIDs = []
cm.customDrinks = [CustomDrink(id: "custom-x", name: "Mystery Soda")]
let cmRun = makeRun(cm, assumed, .ja)
let cc = cmRun.deck.cards[0]
expect(cc.drinkID == "custom-x" && cc.name == "Mystery Soda", "custom drink keeps typed name in ja")
expect(cc.tag.isEmpty && cc.colorHex == "#D9D4CC" && cc.emoji == "🥤", "custom card: empty tag, grey, fallback emoji")
expect(cmRun.machineDrinks[0].kind == "custom" && cmRun.machineDrinks[0].functions.isEmpty, "custom drink is kind custom, no functions")
expect(makeRun(cm).deck.cards[0].name == "Mystery Soda", "custom keeps name in en")

// Tags and reasons
let sr = ShowcaseStrings(language: .en)
let coffee = catalog.drinks.first { $0.caffeineMg > 30 && !$0.functions.isEmpty }!
var cof = sample; cof.drinkIDs = [coffee.id]
let cofEN = makeRun(cof).deck.cards[0]
expect(cofEN.tag == sr.tag(for: coffee.functions[0]) + " · \(coffee.caffeineMg) MG", "English tag with caffeine")
let cofJA = makeRun(cof, assumed, .ja).deck.cards[0]
expect(cofJA.tag == ShowcaseStrings(language: .ja).tag(for: coffee.functions[0]) + " · \(coffee.caffeineMg)mg", "Japanese tag with caffeine")
let plain = catalog.drinks.first { $0.caffeineMg <= 30 && !$0.functions.isEmpty }!
var pl = sample; pl.drinkIDs = [plain.id]
expect(makeRun(pl).deck.cards[0].tag == sr.tag(for: plain.functions[0]), "no caffeine suffix at or under 30 mg")
expect(run.deck.cards.allSatisfy { $0.reasons == sr.reasons(for: run.snapshot) }, "every card carries the guest reasons")
expect(run.deck.cards.allSatisfy { !$0.emoji.isEmpty && $0.colorHex.hasPrefix("#") }, "cards have emoji and colour")
expect(DeckMode.reveal != DeckMode.why && DeckMode.chosen == .chosen, "DeckMode cases")
expect(ShowcaseStep.chosen(drinkID: "a") != ShowcaseStep.chosen(drinkID: "b"), "chosen step carries id")

// Report: front card per preset
for l in [Language.en, .ja] {
    for p in GuestPreset.allCases {
        let r = makeRun(sample, .preset(p), l)
        let f = r.deck.cards[0]
        print("FRONT \(l.rawValue) \(p.rawValue): \(f.emoji) \(f.name) | \(f.tag) | \(f.colorHex) | \(f.reasons.map(\.label).joined(separator: ", "))")
    }
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
