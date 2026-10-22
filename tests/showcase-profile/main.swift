//
// Standalone tests for GuestProfile and ShowcaseStrings.
// Run from the repo root (the test reads the catalogue JSON off disk):
//   xcrun swiftc \
//     HermesGlasses/Services/EmoDrink/PhysiologySnapshot.swift \
//     HermesGlasses/Services/EmoDrink/EmoDrinkLanguage.swift \
//     HermesGlasses/Services/EmoDrink/DrinkCatalog.swift \
//     HermesGlasses/Services/EmoDrink/DrinkRecommender.swift \
//     HermesGlasses/Services/Showcase/GuestProfile.swift \
//     HermesGlasses/Services/Showcase/ShowcaseStrings.swift \
//     tests/showcase-profile/main.swift -o $TMPDIR/showcase-profile && $TMPDIR/showcase-profile
//
import Foundation

var failures = 0
func expect(_ cond: Bool, _ label: String) {
    if cond { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}

let d = "2026-10-21"

expect(GuestProfile.preset(.assumed).snapshot(date: d).bodyState == BodyState(recovery: .low, arousal: .mid), "assumed is low recovery, mid arousal")
expect(GuestProfile.preset(.rested).snapshot(date: d).bodyState.recovery == .high, "rested is high recovery")
expect(GuestProfile.preset(.stressed).snapshot(date: d).bodyState.arousal == .high, "stressed is high arousal")
expect((GuestProfile.preset(.postWorkout).snapshot(date: d).steps ?? 0) > 8000, "post-workout steps above 8000")
expect(GuestProfile.preset(.shortSleep).snapshot(date: d).bodyState.recovery == .low, "short sleep is low recovery")

let poor = GuestAnswers(sleep: .poor, busyDay: true, exercised: false, hadCoffee: false)
expect(GuestProfile.answers(poor).snapshot(date: d).bodyState.recovery == .low, "poor sleep answer is low recovery")
expect(GuestProfile.answers(GuestAnswers(sleep: .great, busyDay: false, exercised: false, hadCoffee: false)).snapshot(date: d).bodyState.recovery == .high, "great sleep answer is high recovery")

// every preset and answer stays in a believable watch range
var allSnaps: [PhysiologySnapshot] = GuestPreset.allCases.map { GuestProfile.preset($0).snapshot(date: d) }
for s in [SleepAnswer.great, .ok, .poor] {
    for busy in [false, true] { for ex in [false, true] { for coffee in [false, true] {
        allSnaps.append(GuestProfile.answers(GuestAnswers(sleep: s, busyDay: busy, exercised: ex, hadCoffee: coffee)).snapshot(date: d))
    } } }
}
expect(allSnaps.allSatisfy { $0.date == d && $0.hrvBaselineMs == 52 }, "date carried, HRV baseline 52")
expect(allSnaps.allSatisfy { (4.5...8.2).contains($0.sleep.hours) }, "sleep within 4.5 to 8.2 h")
expect(allSnaps.allSatisfy { (30...65).contains($0.hrvMs ?? 0) }, "HRV within 30 to 65")
expect(allSnaps.allSatisfy { (50...66).contains($0.restingHR ?? 0) }, "resting HR within 50 to 66")

// hadCoffee never ends in an energise pick at 9
let catalog = try! DrinkCatalog.decode(FileManager.default.contents(atPath: DrinkCatalog.repoPath)!)
var coffeeOK = true
for s in [SleepAnswer.great, .ok, .poor] {
    for busy in [false, true] { for ex in [false, true] {
        let snap = GuestProfile.answers(GuestAnswers(sleep: s, busyDay: busy, exercised: ex, hadCoffee: true)).snapshot(date: d)
        let rec = DrinkRecommender.recommend(snapshot: snap, catalog: catalog, hour: 9, lowSugar: false)
        if rec == nil || rec!.pick.functions.contains(.energise) { coffeeOK = false; print("  coffee pick for \(s) busy=\(busy) ex=\(ex): \(rec?.pick.id ?? "nil")") }
    } }
}
expect(coffeeOK, "hadCoffee never recommends an energise drink at hour 9")
let coffeeSnap = GuestProfile.answers(GuestAnswers(sleep: .poor, busyDay: false, exercised: false, hadCoffee: true)).snapshot(date: d)
let coffeeRec = DrinkRecommender.recommend(snapshot: coffeeSnap, catalog: catalog, hour: 9, lowSugar: false)
expect(coffeeSnap.bodyState.arousal == .high && !(coffeeRec?.pick.functions.contains(.energise) ?? true), "hadCoffee raises arousal (poor sleep case)")

// reasons
let shortSleepSnapshot = GuestProfile.preset(.shortSleep).snapshot(date: d)
expect(ShowcaseStrings(language: .en).reasons(for: shortSleepSnapshot).map(\.label) == ["Short sleep", "HRV low"], "short sleep reasons")
expect(ShowcaseStrings(language: .en).reasons(for: shortSleepSnapshot).map(\.colorHex) == ["#6B5CFF", "#FF4F7A"], "short sleep dot colours")
expect(ShowcaseStrings(language: .ja).reasons(for: shortSleepSnapshot).map(\.label) == ["睡眠不足", "HRV低め"], "short sleep reasons in Japanese")
for lang in Language.allCases {
    let str = ShowcaseStrings(language: lang)
    expect(allSnaps.allSatisfy { str.reasons(for: $0).count <= 2 }, "at most two reasons \(lang)")
    let labels = allSnaps.flatMap { str.reasons(for: $0).map(\.label) }
    let limit: (String) -> Bool = lang == .en ? { $0.split(separator: " ").count <= 2 } : { $0.count <= 6 }
    expect(labels.allSatisfy(limit), "reason labels short enough \(lang)")
}
let stressedReasons = ShowcaseStrings(language: .en).reasons(for: GuestProfile.preset(.stressed).snapshot(date: d)).map(\.label)
expect(stressedReasons.contains("Tense") || stressedReasons.contains("Pulse up"), "stressed preset shows a stress or heart reason")
expect(ShowcaseStrings(language: .en).reasons(for: GuestProfile.preset(.rested).snapshot(date: d)).map(\.label).first == "Well rested", "rested shows Well rested")
expect(ShowcaseStrings(language: .en).reasons(for: GuestProfile.preset(.postWorkout).snapshot(date: d)).map(\.label).contains("Active morning"), "post-workout shows Active morning")

// Spoken reveal grammar
let jaStr = ShowcaseStrings(language: .ja)
let jaLabels = [jaStr.shortSleepLabel, jaStr.hrvLowLabel, jaStr.heartRateUpLabel, jaStr.stressedLabel, jaStr.wellRestedLabel, jaStr.activeMorningLabel]
expect(jaLabels.allSatisfy { !jaStr.spokenReveal(drink: "ドリンク", reason: $0).contains("たなので") }, "no たなので in any Japanese spoken reveal")
expect(jaLabels.allSatisfy { jaStr.spokenReveal(drink: "ドリンク", reason: $0).contains("ので、") }, "Japanese reveal joins with ので")
expect(ShowcaseStrings(language: .en).summary(for: BodyState(recovery: .low, arousal: .mid)).contains("lift") && jaStr.summary(for: BodyState(recovery: .low, arousal: .mid)).contains("すっきり"), "default-path summary agrees across languages")

// Japanese run has no English
func asciiLetters(_ s: String) -> Bool {
    let stripped = s.replacingOccurrences(of: "HRV", with: "")
    return stripped.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
}
let jaAll = ShowcaseStrings(language: .ja).all
expect(jaAll.count > 30, "ja string list is populated")
expect(jaAll.allSatisfy { !$0.isEmpty }, "no empty ja strings")
let offenders = jaAll.filter(asciiLetters)
if !offenders.isEmpty { print("  offenders: \(offenders)") }
expect(offenders.isEmpty, "japaneseRunNoEnglishStrings")
let enAll = ShowcaseStrings(language: .en).all
expect(enAll.count == jaAll.count, "same string count in both languages")
expect(enAll.allSatisfy { !$0.isEmpty }, "no empty en strings")

// The default guest's Why card carries two reasons, not one.
let assumedSnap = GuestProfile.preset(.assumed).snapshot(date: d)
expect(ShowcaseStrings(language: .en).reasons(for: assumedSnap).count == 2, "assumed preset yields 2 reasons (en)")
expect(ShowcaseStrings(language: .ja).reasons(for: assumedSnap).count == 2, "assumed preset yields 2 reasons (ja)")

// GuestProfile round-trips through JSON (the showcase_profile default).
for p in [GuestProfile.preset(.stressed),
          .answers(GuestAnswers(sleep: .poor, busyDay: true, exercised: false, hadCoffee: true))] {
    let data = try! JSONEncoder().encode(p)
    expect((try? JSONDecoder().decode(GuestProfile.self, from: data)) == p, "profile Codable round trip \(p)")
}

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
