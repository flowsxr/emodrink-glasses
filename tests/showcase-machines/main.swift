//
// Standalone tests for VendingMachine, MachineStore and DrinkNameMatcher.
// Run from the repo root (the test reads the catalogue JSON off disk):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/Showcase/VendingMachine.swift \
//     HermesGlasses/Services/Showcase/DrinkNameMatcher.swift \
//     tests/showcase-machines/main.swift -o $TMPDIR/showcase-machines && $TMPDIR/showcase-machines
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let data = FileManager.default.contents(atPath: DrinkCatalog.repoPath)
expect(data != nil, "catalogue JSON exists")
let catalog = try! DrinkCatalog.decode(data!)

// split
expect(DrinkNameMatcher.split("Wilkinson, Calpis Soda and 十六茶") == ["Wilkinson", "Calpis Soda", "十六茶"], "split English list")
expect(DrinkNameMatcher.split("カルピスと十六茶、ドデカミン") == ["カルピス", "十六茶", "ドデカミン"], "split Japanese list")
expect(DrinkNameMatcher.split("a・b\nc") == ["a", "b", "c"], "split on middle dot and newline")
expect(DrinkNameMatcher.split(" , ,x, ") == ["x"], "split drops empties")
expect(DrinkNameMatcher.split("Brandy AND Soda") == ["Brandy", "Soda"], "split ' and ' ignores case")

// match
expect(DrinkNameMatcher.match("calpis soda", in: catalog)?.id == "calpis-soda", "calpis soda -> calpis-soda")
expect(DrinkNameMatcher.match("Calpis Soda please", in: catalog)?.id == "calpis-soda", "longest contained key beats brand word")
expect(DrinkNameMatcher.match("十六茶", in: catalog)?.id == "juroku-cha", "十六茶 -> juroku-cha")
expect(DrinkNameMatcher.match("sixteen tea", in: catalog)?.id == "juroku-cha", "alias sixteen tea")
expect(DrinkNameMatcher.match("Wilkinson", in: catalog)?.id == "wilkinson-tansan", "brand word -> flagship")
expect(DrinkNameMatcher.match("ＷＩＬＫＩＮＳＯＮ", in: catalog)?.id == "wilkinson-tansan", "full-width input normalised")
expect(DrinkNameMatcher.match("Coca-Cola", in: catalog) == nil, "Coca-Cola is nil")
expect(DrinkNameMatcher.match("", in: catalog) == nil, "empty is nil")
expect(DrinkNameMatcher.match("a", in: catalog) == nil, "one character is nil")
// every drink is reachable by its own English and Japanese name
expect(catalog.drinks.allSatisfy { DrinkNameMatcher.match($0.name, in: catalog)?.id == $0.id }, "every English name matches itself")
expect(catalog.drinks.allSatisfy { DrinkNameMatcher.match($0.nameJa, in: catalog)?.id == $0.id }, "every Japanese name matches itself")

let all = DrinkNameMatcher.matchAll("Wilkinson, Coca-Cola", in: catalog)
expect(all.unmatched == ["Coca-Cola"], "matchAll reports Coca-Cola unmatched")
expect(all.matched.map(\.id) == ["wilkinson-tansan"], "matchAll matches Wilkinson")
let dup = DrinkNameMatcher.matchAll("Wilkinson, wilkinson", in: catalog)
expect(dup.matched.count == 1, "matchAll de-duplicates")

// 「と」 inside catalogue names must not split them
func ids(_ u: String) -> ([String], [String]) { let r = DrinkNameMatcher.matchAll(u, in: catalog); return (r.matched.map(\.id), r.unmatched) }
expect(ids("ほっと十六茶") == (["hot-juroku-cha"], []), "ほっと十六茶 -> hot-juroku-cha, nothing unmatched")
expect(ids("アサヒ ほっと十六茶") == (["hot-juroku-cha"], []), "アサヒ ほっと十六茶 -> hot-juroku-cha only")
expect(ids("カルピスとほっと十六茶") == (["calpis-water", "hot-juroku-cha"], []), "カルピスとほっと十六茶 -> two drinks")
expect(ids("カルピスと十六茶") == (["calpis-water", "juroku-cha"], []), "カルピスと十六茶 still splits")
expect(catalog.drinks.allSatisfy { ids($0.nameJa) == ([$0.id], []) }, "every nameJa round-trips through matchAll")

// machines
let sample = VendingMachine.sample
expect(sample.id == "sample" && sample.name == "Asahi lobby" && sample.navigationEnabled && sample.distanceMeters == 40 && sample.customDrinks.isEmpty, "sample fields")
expect(sample.drinkIDs.count == 9, "sample has nine drinks")
expect(catalog.drinks(ids: sample.drinkIDs).count == sample.drinkIDs.count, "sample references only real ids")
let covered = Set(catalog.drinks(ids: sample.drinkIDs).flatMap(\.functions))
expect(covered == Set(DrinkFunction.allCases), "sample covers all five functions")

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("showcase-machines-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let store = MachineStore(directory: dir)
expect(store.load() == [VendingMachine.sample], "missing file loads the sample")
let a = VendingMachine(id: "a", name: "Station", drinkIDs: ["oishii-mizu"], customDrinks: [CustomDrink(id: "custom-1", name: "Mystery")], navigationEnabled: false, distanceMeters: 120)
let b = VendingMachine(id: "b", name: "Office", drinkIDs: [], customDrinks: [], navigationEnabled: true, distanceMeters: 5)
try! store.save([a, b])
expect(MachineStore(directory: dir).load() == [a, b], "round trip")
try! "not json".write(to: dir.appendingPathComponent("machines.json"), atomically: true, encoding: .utf8)
expect(store.load() == [VendingMachine.sample], "corrupt file loads the sample")
try? FileManager.default.removeItem(at: dir)

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
