//
// ShowcaseStrings.swift
//
// Every lens, voice and phone string the showcase adds, in both languages,
// in one place. Copy is short, warm and suggestive, never diagnostic. A
// Japanese run carries no English except "HRV" and the arrows. Foundation
// only; tested in tests/showcase-profile.
//

import Foundation

struct ShowcaseReason: Equatable {
    let label: String
    let colorHex: String
}

struct ShowcaseStrings {
    let language: Language
    private var ja: Bool { language == .ja }

    // MARK: Step headings

    var navigateHeading: String { ja ? "自販機へ" : "On the way" }
    var morningHeading: String { ja ? "今朝のあなた" : "Your morning" }
    var scanHeading: String { ja ? "ラインナップ" : "The lineup" }
    var pickedHeading: String { ja ? "あなたにおすすめ" : "Picked for you" }

    // MARK: Buttons

    var choose: String { ja ? "これにする" : "Choose" }
    var next: String { ja ? "次へ" : "Next" }
    var why: String { ja ? "なぜ？" : "Why" }
    var previousArrow: String { "◀" }
    var nextArrow: String { "▶" }
    func backTo(_ name: String) -> String { ja ? "\(name)に戻る" : "Back to \(name)" }

    // MARK: Lines

    func scanLine(count: Int) -> String { ja ? "\(count)種類のドリンクが見つかりました" : "Found \(count) drinks" }
    func navigationLine(distance: String, name: String) -> String {
        ja ? "\(name)まで\(distance)" : "\(distance) to \(name)"
    }
    var confirmLine: String { ja ? "いい選択ですね。ごゆっくりどうぞ。" : "Nice choice. Enjoy it." }
    var fallbackConversation: String {
        ja ? "少し考えますね。今はカードのおすすめをどうぞ。" : "Let me think about that. The card shows my pick for now."
    }

    // MARK: Clip labels (morning and navigate)

    var sleepWord: String { ja ? "睡眠" : "sleep" }
    var hrvLabel: String { "HRV" }
    var restingHRLabel: String { ja ? "安静時心拍" : "Resting HR" }
    var hrvUnit: String { ja ? "ミリ秒" : "ms" }
    var bpmUnit: String { ja ? "拍/分" : "bpm" }
    var distanceUnit: String { ja ? "メートル" : "m" }
    var here: String { ja ? "到着" : "Here" }

    /// "5h48" / "5時間48分".
    func sleepDuration(hours: Double) -> String {
        let minutes = max(0, Int((hours * 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        return ja ? "\(h)時間\(m)分" : "\(h)h" + String(format: "%02d", m)
    }

    /// A figure against the guest's usual: "↓12 vs your usual" / "いつもより↓12".
    func versusUsual(_ delta: Int) -> String {
        if delta == 0 { return ja ? "いつもどおり" : "Your usual" }
        let arrow = delta < 0 ? "↓" : "↑"
        return ja ? "いつもより\(arrow)\(abs(delta))" : "\(arrow)\(abs(delta)) vs your usual"
    }

    // MARK: Spoken step lines

    var spokenNavigate: String { ja ? "自販機までご案内しますね。" : "Let me walk you to the machine." }
    var spokenMorning: String { ja ? "今朝の体のようすを見てみましょう。" : "Here is how your morning looks." }
    var spokenScan: String { ja ? "この自販機のラインナップを見ていますね。" : "Looking at what this machine has." }
    func spokenReveal(drink: String, reason: String) -> String {
        ja ? "\(Self.spokenReasonJa(reason))、\(drink)はいかがでしょう。" : "\(reason), so how about \(drink)?"
    }

    /// Japanese label -> a phrase that joins with ので; unknown labels pass through.
    static func spokenReasonJa(_ label: String) -> String {
        switch label {
        case "睡眠不足": return "睡眠が足りていないので"
        case "HRV低め": return "HRVが低めなので"
        case "心拍高め": return "心拍が高めなので"
        case "張りつめ気味": return "張りつめ気味なので"
        case "よく眠れた": return "よく眠れたので"
        case "よく歩いた": return "よく歩いたので"
        default: return label + "ので"
        }
    }

    // MARK: Morning summary, one line per recovery / arousal pair

    func summary(for state: BodyState) -> String {
        switch (state.recovery, state.arousal) {
        case (.low, .low): return ja ? "ゆっくりな朝。やさしく目覚めましょう。" : "A slow start. Ease into the day."
        case (.low, .mid): return ja ? "少し眠そうな朝。一杯で、すっきりいきましょう。" : "A little sleepy. Time for a lift."
        case (.low, .high): return ja ? "眠いのに落ち着かない朝。まず深呼吸を。" : "Tired but wired. Slow down first."
        case (.mid, .low): return ja ? "穏やかな朝。のんびりいきましょう。" : "A calm morning. No rush."
        case (.mid, .mid): return ja ? "ほどよい朝。さっぱりしたいですね。" : "A steady morning. Something fresh."
        case (.mid, .high): return ja ? "少し張りつめた朝。肩の力を抜いて。" : "A bit keyed up. Soften the edges."
        case (.high, .low): return ja ? "ぐっすり眠れた朝。気持ちよく始めましょう。" : "Well rested. A gentle start."
        case (.high, .mid): return ja ? "よく眠れた朝。さわやかにいきましょう。" : "Well rested. Keep it bright."
        case (.high, .high): return ja ? "元気いっぱいの朝。水分を忘れずに。" : "Full of energy. Keep sipping."
        }
    }

    // MARK: Function tags

    func tag(for function: DrinkFunction) -> String {
        switch function {
        case .calm: return ja ? "落ち着く" : "CALM"
        case .energise: return ja ? "元気" : "ENERGISE"
        case .hydrate: return ja ? "うるおい" : "HYDRATE"
        case .recover: return ja ? "回復" : "RECOVER"
        case .refresh: return ja ? "さわやか" : "REFRESH"
        }
    }

    // MARK: Reason labels

    var shortSleepLabel: String { ja ? "睡眠不足" : "Short sleep" }
    var hrvLowLabel: String { ja ? "HRV低め" : "HRV low" }
    var heartRateUpLabel: String { ja ? "心拍高め" : "Pulse up" }
    var stressedLabel: String { ja ? "張りつめ気味" : "Tense" }
    var wellRestedLabel: String { ja ? "よく眠れた" : "Well rested" }
    var activeMorningLabel: String { ja ? "よく歩いた" : "Active morning" }

    /// At most two, worst signal first: short sleep, HRV, heart rate,
    /// stress, then the good news (well rested, active morning).
    func reasons(for s: PhysiologySnapshot) -> [ShowcaseReason] {
        var out: [ShowcaseReason] = []
        if s.sleep.hours < 6 { out.append(ShowcaseReason(label: shortSleepLabel, colorHex: "#6B5CFF")) }
        if (s.hrvDelta ?? 0) < -10 { out.append(ShowcaseReason(label: hrvLowLabel, colorHex: "#FF4F7A")) }
        if (s.restingHRDelta ?? 0) >= 5 { out.append(ShowcaseReason(label: heartRateUpLabel, colorHex: "#FFB36B")) }
        if (s.stress ?? 0) >= 65 { out.append(ShowcaseReason(label: stressedLabel, colorHex: "#FF8A3D")) }
        if s.sleep.hours >= 7, (s.sleep.score ?? 0) >= 80 {
            out.append(ShowcaseReason(label: wellRestedLabel, colorHex: "#6B5CFF"))
        }
        if (s.steps ?? 0) > 8000 { out.append(ShowcaseReason(label: activeMorningLabel, colorHex: "#FFB36B")) }
        return Array(out.prefix(2))
    }

    // MARK: Enumeration (for the no-English-in-Japanese test)

    /// Every string, templates filled with sample values.
    var all: [String] {
        var out = [navigateHeading, morningHeading, scanHeading, pickedHeading,
                   choose, next, why, previousArrow, nextArrow, backTo("ドリンク"),
                   scanLine(count: 5), navigationLine(distance: "40メートル", name: "自販機"),
                   confirmLine, fallbackConversation,
                   spokenNavigate, spokenMorning, spokenScan, spokenReveal(drink: "ドリンク", reason: "睡眠不足"),
                   shortSleepLabel, hrvLowLabel, heartRateUpLabel, stressedLabel, wellRestedLabel, activeMorningLabel,
                   sleepWord, hrvLabel, restingHRLabel, hrvUnit, bpmUnit, distanceUnit, here,
                   sleepDuration(hours: 5.8), versusUsual(-12), versusUsual(3), versusUsual(0)]
        for l in BodyLevel.allCasesForStrings { for a in BodyLevel.allCasesForStrings {
            out.append(summary(for: BodyState(recovery: l, arousal: a)))
        } }
        out += DrinkFunction.allCases.map(tag(for:))
        return out
    }
}

private extension BodyLevel {
    static let allCasesForStrings: [BodyLevel] = [.low, .mid, .high]
}

/// A native lens button under a showcase card. Labels come from the run's
/// strings, so a Japanese run never shows English.
enum ShowcaseButton: Equatable, Sendable {
    case previous, why, next, choose
    case back(name: String)

    /// `.next` is the ▶ arrow beside ◀, and the word "Next" otherwise.
    func label(in strings: ShowcaseStrings, among buttons: [ShowcaseButton]) -> String {
        switch self {
        case .previous: return strings.previousArrow
        case .why: return strings.why
        case .next: return buttons.contains(.previous) ? strings.nextArrow : strings.next
        case .choose: return strings.choose
        case .back(let name): return strings.backTo(name)
        }
    }

    /// The one filled button: Why on the deck, Choose on the Why card.
    var isPrimary: Bool { self == .why || self == .choose }
}
