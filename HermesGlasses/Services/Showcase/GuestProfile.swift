//
// GuestProfile.swift
//
// The guest's "morning" for the showcase: assumed, picked from a preset, or
// built from four quick questions. Each becomes an ordinary
// PhysiologySnapshot, so the recommender stays untouched. Numbers are those
// of a believable watch (sleep 4.5 to 8.2 h, HRV 30 to 65 ms against a
// baseline of 52, resting HR 50 to 66). Foundation only; tested in
// tests/showcase-profile.
//

import Foundation

enum GuestPreset: String, CaseIterable, Equatable {
    case assumed, rested, shortSleep, stressed, postWorkout
}

enum SleepAnswer: Equatable {
    case great, ok, poor
}

struct GuestAnswers: Equatable {
    var sleep: SleepAnswer
    var busyDay: Bool
    var exercised: Bool
    var hadCoffee: Bool
}

enum GuestProfile: Equatable {
    case preset(GuestPreset)
    case answers(GuestAnswers)

    static let hrvBaseline = 52.0
    static let restingHRBaseline = 58.0

    func snapshot(date: String) -> PhysiologySnapshot {
        switch self {
        case .preset(let preset): return Self.snapshot(for: preset, date: date)
        case .answers(let answers): return Self.snapshot(for: answers, date: date)
        }
    }

    private static func make(date: String, source: String, hours: Double, score: Int, hrv: Double,
                             hr: Double, steps: Int, stress: Int) -> PhysiologySnapshot {
        PhysiologySnapshot(date: date, source: source,
                           sleep: SleepSummary(hours: hours, score: score),
                           hrvMs: hrv, hrvBaselineMs: hrvBaseline,
                           restingHR: hr, restingHRBaseline: restingHRBaseline,
                           steps: steps, stress: stress)
    }

    // Preset table (recovery / arousal in the last column):
    //   assumed     5.6 h  58  HRV 40  HR 60  1200 steps  stress 40  low / mid
    //   rested      7.9 h  86  HRV 58  HR 55  2000 steps  stress 20  high / mid
    //   shortSleep  4.8 h  41  HRV 38  HR 61   900 steps  stress 45  low / mid
    //   stressed    6.4 h  66  HRV 44  HR 64  1500 steps  stress 74  mid / high
    //   postWorkout 7.6 h  82  HRV 56  HR 52 11200 steps  stress 22  high / mid
    private static func snapshot(for preset: GuestPreset, date: String) -> PhysiologySnapshot {
        switch preset {
        case .assumed:
            return make(date: date, source: "assumed morning", hours: 5.6, score: 58, hrv: 40, hr: 60, steps: 1200, stress: 40)
        case .rested:
            return make(date: date, source: "sample: well rested", hours: 7.9, score: 86, hrv: 58, hr: 55, steps: 2000, stress: 20)
        case .shortSleep:
            return make(date: date, source: "sample: short night", hours: 4.8, score: 41, hrv: 38, hr: 61, steps: 900, stress: 45)
        case .stressed:
            return make(date: date, source: "sample: tense morning", hours: 6.4, score: 66, hrv: 44, hr: 64, steps: 1500, stress: 74)
        case .postWorkout:
            return make(date: date, source: "sample: after a workout", hours: 7.6, score: 82, hrv: 56, hr: 52, steps: 11200, stress: 22)
        }
    }

    /// Four quick questions. Coffee raises arousal (heart rate up, stress
    /// felt) rather than touching the recommender, so no energise pick follows.
    private static func snapshot(for a: GuestAnswers, date: String) -> PhysiologySnapshot {
        let hours: Double, score: Int, hrv: Double
        switch a.sleep {
        case .great: (hours, score, hrv) = (7.8, 85, 56)
        case .ok: (hours, score, hrv) = (6.6, 68, 51)
        case .poor: (hours, score, hrv) = (5.0, 45, 42)
        }
        var hr = a.busyDay ? 63.0 : 57.0
        var stress = a.busyDay ? 72 : 35
        if a.hadCoffee {
            hr = max(hr, restingHRBaseline + 6)
            stress = max(stress, 66)
        }
        return make(date: date, source: "from your answers", hours: hours, score: score, hrv: hrv,
                    hr: hr, steps: a.exercised ? 9800 : 2100, stress: stress)
    }
}
