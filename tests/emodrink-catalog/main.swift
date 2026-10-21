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

// Alias hygiene: a key that is inside another drink's key is only allowed for
// intentional flagship brand words, and the siblings must then carry longer keys.
func norm(_ s: String) -> String {
    s.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
}
let brandWords = ["calpis", "カルピス", "wilkinson", "ウィルキンソン", "mitsuya", "三ツ矢", "juroku", "十六茶", "sixteentea", "dodekamin", "ドデカミン", "おいしい水", "oishiiwater"].map(norm)
let fullNamePrefixes = ["mitsuyacider", "三ツ矢サイダー", "wilkinsontansan", "ウィルキンソンタンサン", "dodekamin", "ドデカミン", "calpiswater", "カルピスウォーター", "asahijuroku-cha", "アサヒ十六茶", "asahioishiimizutennensui", "アサヒおいしい水天然水", "wondamorningshot", "ワンダモーニングショット"].map(norm)
let allowedInside = Set(brandWords + fullNamePrefixes)
func keys(_ d: Drink) -> [String] { ([d.name, d.nameJa] + d.aliases).map(norm) }
var insideViolations: [String] = []
for a in catalog.drinks {
    for k in keys(a) where k.count >= 2 && !allowedInside.contains(k) {
        for b in catalog.drinks where b.id != a.id {
            if keys(b).contains(where: { $0 != k && $0.contains(k) }) { insideViolations.append("\(a.id):\(k) inside \(b.id)") }
        }
    }
}
expect(insideViolations.isEmpty, "no alias or name hides inside another drink's key unless it is a flagship brand word \(insideViolations)")
var siblingViolations: [String] = []
for w in brandWords {
    for b in catalog.drinks {
        let ownsBare = b.aliases.map(norm).contains(w) || norm(b.name) == w || norm(b.nameJa) == w
        let mentions = keys(b).contains { $0.contains(w) }
        if mentions && !ownsBare && !b.aliases.map(norm).contains(where: { $0.contains(w) && $0.count > w.count }) {
            siblingViolations.append("\(b.id) lacks a longer alias for \(w)")
        }
    }
}
expect(siblingViolations.isEmpty, "every sibling of a flagship brand word has a longer alias \(siblingViolations)")
let everyKey = catalog.drinks.flatMap { Array(Set(keys($0))) }
expect(Set(everyKey).count == everyKey.count, "no key is shared by two drinks")
let genericAliases = ["energydrink", "sparklingwater", "barleytea", "greentea", "tonic", "sportsdrink"]
expect(catalog.drinks.allSatisfy { Set($0.aliases.map(norm)).isDisjoint(with: genericAliases) }, "no generic category aliases")
expect(catalog.drinks.allSatisfy { $0.colorHex == nil || $0.colorHex == $0.functions.first.map { f in Drink(id: "x", name: "x", nameJa: "x", kind: "x", functions: [f], caffeineMg: 0, sugar: .none, served: .cold).displayColorHex } }, "colour matches the first function")

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
