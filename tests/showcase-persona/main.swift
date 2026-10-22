//
// Standalone tests for ShowcasePersona, ShowcaseReply and ShowcaseCommand.
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
//     tests/showcase-persona/main.swift -o $TMPDIR/showcase-persona && $TMPDIR/showcase-persona
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
let sample = VendingMachine.sample
let assumed = GuestProfile.preset(.assumed)
func makeRun(_ l: Language) -> ShowcaseRun {
    try! ShowcaseRun(machine: sample, profile: assumed, catalog: catalog, language: l, date: "2026-10-21")
}
let ids = Set(sample.drinkIDs)

// Parse
let a = ShowcaseReply.parse("A small coffee helps. [[drink:wonda-morning-shot]]", machineDrinkIDs: ids)
expect(a.spoken == "A small coffee helps." && a.focusID == "wonda-morning-shot", "parse tag")
let b = ShowcaseReply.parse("Try this [[drink:coca-cola]]", machineDrinkIDs: ids)
expect(b.focusID == nil && !b.spoken.contains("[") && b.spoken == "Try this", "outside id")
let c = ShowcaseReply.parse("No tag here", machineDrinkIDs: ids)
expect(c.focusID == nil && c.spoken == "No tag here", "no tag")
let d = ShowcaseReply.parse("Hmm [[drink:calpis-water]] or [[drink:juroku-cha]] and [[drink:coca-cola]] ok", machineDrinkIDs: ids)
expect(d.focusID == "juroku-cha", "last in-machine id wins")
expect(d.spoken == "Hmm or and ok", "gaps collapse: \(d.spoken)")
let e = ShowcaseReply.parse("Hi [[whatever]] there [[x:y]]", machineDrinkIDs: ids)
expect(e.spoken == "Hi there" && e.focusID == nil, "any [[...]] stripped")
let f = ShowcaseReply.parse("  [[drink:super-h2o]] ", machineDrinkIDs: ids)
expect(f.spoken == "" && f.focusID == "super-h2o", "tag only")

let g = ShowcaseReply.parse("Try this [[drink:wonda", machineDrinkIDs: ids)
expect(g.spoken == "Try this" && g.focusID == nil, "truncated tag dropped: \(g.spoken)")
let h = ShowcaseReply.parse("Nice. [[Drink:super-h2o]]", machineDrinkIDs: ids)
expect(h.focusID == "super-h2o", "case-insensitive prefix")

// Fallback
for l in Language.allCases {
    let s = ShowcaseReply.fallbackLine(strings: ShowcaseStrings(language: l))
    expect(!s.isEmpty, "fallback non-empty \(l)")
}
let jaFallback = ShowcaseReply.fallbackLine(strings: ShowcaseStrings(language: .ja))
expect(jaFallback.unicodeScalars.allSatisfy { !(($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)) }, "ja fallback no ASCII letters")

// Prompts
let en = ShowcasePersona.systemPrompt(run: makeRun(.en), language: .en)
let ja = ShowcasePersona.systemPrompt(run: makeRun(.ja), language: .ja)
for id in sample.drinkIDs { expect(en.contains(id), "prompt has \(id)") }
let outside = catalog.drinks.map(\.id).filter { !ids.contains($0) }
expect(!outside.isEmpty, "catalogue has outside ids")
for id in outside where en.contains(id) { expect(false, "prompt leaks \(id)") }
for d in catalog.drinks where !ids.contains(d.id) { expect(!en.contains(d.name), "prompt leaks name \(d.name)") }
expect(en.contains("[[drink:"), "prompt explains tag")
expect(en.lowercased().contains("never") && en.lowercased().contains("diagnos"), "suggestive rule")
expect(en.contains("two short") || en.contains("two sentences"), "two sentences")
expect(en.contains("HRV") && en.contains("sleep"), "numbers present")
expect(ja.contains("Japanese") && ja.contains(EmoDrinkPersona.languageRule(.ja)), "ja prompt asks Japanese")
expect(en.contains(EmoDrinkPersona.languageRule(.en)), "en uses shared language rule")
for w in EmoDrinkPersona.emotionDenylist {
    expect(!en.lowercased().contains(w), "en prompt free of \(w)")
    expect(!ja.lowercased().contains(w), "ja prompt free of \(w)")
}

expect(en.contains("[[drink:wilkinson-tansan]]") && !en.contains("<id>"), "concrete example tag")
expect(en.contains("at most one drink") && en.contains("even when asked for more") && en.contains("Put the tag last"), "required prompt rules")
for d in sample.drinkIDs.compactMap({ catalog.drink(id: $0) }) { expect(!ja.contains(d.name), "ja prompt lacks English name \(d.name)") }
for d in catalog.drinks where !ids.contains(d.id) { expect(!ja.contains(d.nameJa), "ja prompt lacks off-machine \(d.nameJa)") }
expect(ja.contains("Say drink names only as written in Japanese."), "ja name rule")

// Reveal line
let reveal = ShowcasePersona.revealLine(run: makeRun(.en), language: .en)
let front = makeRun(.en).deck.cards[0]
expect(reveal.contains(front.name), "reveal names front drink")
expect(front.reasons.prefix(2).allSatisfy { reveal.contains($0.label) }, "reveal has top two reasons")
expect(reveal.contains("20 words"), "reveal en limit")
let revealJa = ShowcasePersona.revealLine(run: makeRun(.ja), language: .ja)
expect(revealJa.contains("40") && revealJa.contains("Japanese"), "reveal ja limit")
expect(!reveal.contains("[[") && reveal.contains("Do not add any tag."), "reveal has no tag")
expect(!revealJa.contains("[["), "reveal ja has no tag")

// Commands
expect(ShowcaseCommand.spoken("次", language: .ja) == .next, "次")
expect(ShowcaseCommand.spoken("Next!", language: .en) == .next, "Next!")
expect(ShowcaseCommand.spoken("前の", language: .ja) == .previous, "前の")
expect(ShowcaseCommand.spoken("go back one", language: .en) == .previous, "go back one")
expect(ShowcaseCommand.spoken("go back", language: .en) == .back, "go back")
expect(ShowcaseCommand.spoken("back", language: .en) == .back, "back")
expect(ShowcaseCommand.spoken("戻る", language: .ja) == .back, "戻る")
expect(ShowcaseCommand.spoken("why", language: .en) == .why, "why")
expect(ShowcaseCommand.spoken("なぜ", language: .ja) == .why, "なぜ")
expect(ShowcaseCommand.spoken("I'll take it", language: .en) == .choose, "i'll take it")
expect(ShowcaseCommand.spoken("これにする", language: .ja) == .choose, "これにする")
expect(ShowcaseCommand.spoken("これください", language: .ja) == .choose, "これください")
expect(ShowcaseCommand.spoken("それで", language: .ja) == nil && ShowcaseCommand.spoken("これで", language: .ja) == nil, "filler not choose")
expect(ShowcaseCommand.spoken("what's next for me today", language: .en) == nil, "whole utterance")
expect(ShowcaseCommand.spoken("", language: .en) == nil, "empty")
let sets = ShowcaseCommand.phraseSets
var seen = Set<String>(); var dup = false
for (_, s) in sets { for p in s { if !seen.insert(p).inserted { dup = true; print("DUP \(p)") } } }
expect(!dup, "no phrase in two sets")
for (cmd, s) in sets { for p in s { expect(ShowcaseCommand.spoken(p, language: .en) == cmd, "phrase '\(p)' -> \(cmd)") } }

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
