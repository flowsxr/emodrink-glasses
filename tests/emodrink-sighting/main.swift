//
// Standalone tests for DrinkSighting: reading the vision reply (JSON, with
// the YES/NO fallback) and turning it into what drink mode offers. Run from
// the repo root (the test reads the catalogue JSON off disk):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/VendingMachineDetector.swift \
//     HermesGlasses/Services/Showcase/DrinkNameMatcher.swift \
//     HermesGlasses/Services/EmoDrink/DrinkSighting.swift \
//     tests/emodrink-sighting/main.swift -o /tmp/ed-sighting && /tmp/ed-sighting
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
func drink(_ id: String) -> Drink { catalog.drinks.first { $0.id == id }! }
typealias S = DrinkSighting

// MARK: parse

let machine = S.parse(#"{"scene": "machine", "drinks": ["Calpis Water", "Wonda Morning Shot", "Pocari Sweat"]}"#)
expect(machine.scene == .machine, "parse: machine scene")
expect(machine.drinks == ["Calpis Water", "Wonda Morning Shot", "Pocari Sweat"], "parse: names in order")

let fenced = S.parse("```json\n{\"scene\":\"drinks\",\"drinks\":[\"Monster Energy\"]}\n```")
expect(fenced.scene == .drinks && fenced.drinks == ["Monster Energy"], "parse: a fenced JSON block")

let dupes = S.parse(#"{"scene":"drinks","drinks":["Calpis Water"," calpis water ","", "Red Bull"]}"#)
expect(dupes.drinks == ["Calpis Water", "Red Bull"], "parse: blanks dropped, duplicates once")

let many = S.parse(#"{"scene":"machine","drinks":[\#((1...20).map { "\"Drink \($0)\"" }.joined(separator: ","))]}"#)
expect(many.drinks.count == S.maxNames, "parse: at most \(S.maxNames) names")

expect(S.parse("YES").scene == .machine && S.parse("YES").drinks.isEmpty, "parse: a bare YES is a machine")
expect(S.parse("NO").scene == .none, "parse: a bare NO is nothing")
expect(S.parse("I can't tell").scene == .none, "parse: prose is nothing")
expect(S.parse(#"{"scene":"bottles","drinks":[]}"#).scene == .none, "parse: an unknown scene with no drinks is nothing")
expect(S.parse(#"{"scene":"none","drinks":["Calpis Water"]}"#).scene == .drinks,
       "parse: drinks named under scene none still count as drinks")

// MARK: plan

let machinePlan = S.plan(machine, catalog: catalog)
expect(machinePlan == .offer(pool: [drink("calpis-water"), drink("wonda-morning-shot")],
                             seen: [drink("calpis-water"), drink("wonda-morning-shot")],
                             unknown: ["Pocari Sweat"]),
       "plan: a machine with two known drinks offers only those, and names the unknown one")

let ja = S.plan(S.parse(#"{"scene":"drinks","drinks":["カルピスウォーター","十六茶"]}"#), catalog: catalog)
expect(ja == .offer(pool: [drink("calpis-water"), drink("juroku-cha")],
                    seen: [drink("calpis-water"), drink("juroku-cha")], unknown: []),
       "plan: Japanese label names match")

let oneKnownOnMachine = S.plan(S.parse(#"{"scene":"machine","drinks":["Calpis Water","Coca-Cola"]}"#), catalog: catalog)
expect(oneKnownOnMachine == .offer(pool: [], seen: [drink("calpis-water")], unknown: ["Coca-Cola"]),
       "plan: fewer than two known drinks offers from the whole list")

let bareMachine = S.plan(S.parse("YES"), catalog: catalog)
expect(bareMachine == .offer(pool: [], seen: [], unknown: []), "plan: a machine with nothing readable offers the whole list")

let unreadable = S.plan(S.parse(#"{"scene":"drinks","drinks":[]}"#), catalog: catalog)
expect(unreadable == .offer(pool: [], seen: [], unknown: []), "plan: drinks with no readable label offer the whole list")

let singleKnown = S.plan(S.parse(#"{"scene":"drinks","drinks":["Monster Energy"]}"#), catalog: catalog)
expect(singleKnown == .single(known: drink("monster-energy"), name: "Monster Energy"), "plan: one known drink is a single")

let singleUnknown = S.plan(S.parse(#"{"scene":"drinks","drinks":["Pocari Sweat"]}"#), catalog: catalog)
expect(singleUnknown == .single(known: nil, name: "Pocari Sweat"), "plan: one unknown drink is a single, by its name")

let machineOne = S.plan(S.parse(#"{"scene":"machine","drinks":["Calpis Water"]}"#), catalog: catalog)
expect(machineOne == .offer(pool: [], seen: [drink("calpis-water")], unknown: []),
       "plan: a machine with one readable drink is still a machine, not a single")

let twoUnknown = S.plan(S.parse(#"{"scene":"drinks","drinks":["Pocari Sweat","Red Bull"]}"#), catalog: catalog)
expect(twoUnknown == .offer(pool: [], seen: [], unknown: ["Pocari Sweat", "Red Bull"]),
       "plan: only unknown drinks names them and offers from the whole list")

let sameDrinkTwice = S.plan(S.parse(#"{"scene":"drinks","drinks":["Calpis Water","カルピスウォーター"]}"#), catalog: catalog)
expect(sameDrinkTwice == .single(known: drink("calpis-water"), name: "Calpis Water"),
       "plan: one drink read in two languages is one drink")

expect(S.plan(S.parse("NO"), catalog: catalog) == .none, "plan: nothing seen, nothing offered")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
