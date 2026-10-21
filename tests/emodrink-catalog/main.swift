//
// Standalone tests for DrinkCatalog + the bundled JSON. Run from the repo
// root (the test reads the JSON off disk, the app reads it from the bundle):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     tests/emodrink-catalog/main.swift -o /tmp/ed-catalog && /tmp/ed-catalog
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let data = FileManager.default.contents(atPath: DrinkCatalog.repoPath)
expect(data != nil, "bundled JSON exists at \(DrinkCatalog.repoPath)")
let catalog = try! DrinkCatalog.decode(data!)

let originalTwelveIDs = ["oishii-mizu", "wilkinson-tansan", "mitsuya-cider", "mitsuya-cider-zero", "calpis-water", "calpis-soda", "juroku-cha", "rokujo-mugicha", "wonda-morning-shot", "wonda-kin-no-bito-black", "super-h2o", "dodekamin"]
expect(catalog.drinks.count >= 25, "catalogue covers the Asahi range (\(catalog.drinks.count))")
expect(Set(catalog.drinks.map(\.id)).count == catalog.drinks.count, "ids are unique")
expect(catalog.drinks.allSatisfy { !$0.functions.isEmpty }, "every drink has at least one function")
expect(catalog.drinks.allSatisfy { !$0.nameJa.isEmpty }, "every drink has a Japanese name")
expect(catalog.drinks.allSatisfy { $0.caffeineMg >= 0 }, "caffeine is non-negative")

let rokujo = catalog.drink(id: "rokujo-mugicha")
expect(rokujo?.functions == [.calm, .hydrate] && rokujo?.caffeineMg == 0 && rokujo?.sugar == SugarLevel.none,
       "Rokujo Mugicha is calm + hydrate, caffeine-free, no sugar")
expect(catalog.drink(id: "wonda-morning-shot")?.functions == [.energise], "Wonda Morning Shot is energise only")
expect(catalog.drink(id: "nope") == nil, "unknown id is nil")

expect(catalog.drinks.allSatisfy { !$0.nameJa.isEmpty && $0.displayColorHex.hasPrefix("#") }, "every drink has a Japanese name and a colour")
expect(catalog.drinks.allSatisfy { !$0.displayEmoji.isEmpty }, "every drink has an emoji")
expect(catalog.drink(id: "calpis-water")?.aliases.contains("カルピス") == true, "aliases decode")
expect(catalog.drinks(ids: ["super-h2o", "nope", "wilkinson-tansan"]).map(\.id) == ["super-h2o", "wilkinson-tansan"], "drinks(ids:) keeps order, drops unknown")
expect(Array(catalog.drinks.prefix(12).map(\.id)) == originalTwelveIDs, "the original twelve stay first, in order")
let allAliases = catalog.drinks.flatMap { d in d.aliases.map { $0.lowercased() } }
expect(Set(allAliases).count == allAliases.count, "no alias is shared by two drinks")
expect(catalog.drinks.dropFirst(12).allSatisfy { (2...4).contains($0.aliases.count) }, "new drinks carry 2-4 aliases")

// Validation.
let empty = "{\"drinks\":[]}".data(using: .utf8)!
expect((try? DrinkCatalog.decode(empty)) == nil, "empty catalogue is rejected")
let dup = """
{"drinks":[
 {"id":"a","name":"A","name_ja":"あ","kind":"water","functions":["hydrate"],"caffeine_mg":0,"sugar":"none","served":"cold"},
 {"id":"a","name":"A2","name_ja":"あ","kind":"water","functions":["hydrate"],"caffeine_mg":0,"sugar":"none","served":"cold"}]}
""".data(using: .utf8)!
expect((try? DrinkCatalog.decode(dup)) == nil, "duplicate ids are rejected")
let badFunction = """
{"drinks":[{"id":"a","name":"A","name_ja":"あ","kind":"water","functions":["sparkle"],"caffeine_mg":0,"sugar":"none","served":"cold"}]}
""".data(using: .utf8)!
expect((try? DrinkCatalog.decode(badFunction)) == nil, "unknown function is rejected")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
