//
// GuestProfileView.swift
//
// The guest's morning, as a sheet from the showcase home: one of the five
// presets, or four quick questions asked out loud. Choosing either sets
// ShowcaseViewModel.profile at once; Done only closes. Taka's labels.
//

import SwiftUI

extension GuestPreset {
    var title: String {
        switch self {
        case .assumed: return "Assumed morning"
        case .rested: return "Well rested"
        case .shortSleep: return "Short sleep"
        case .stressed: return "Stressed"
        case .postWorkout: return "After a workout"
        }
    }

    var explanation: String {
        switch self {
        case .assumed: return "The default: slightly short sleep, a little tense"
        case .rested: return "A full night and a calm start"
        case .shortSleep: return "Under five hours, HRV down"
        case .stressed: return "Pulse and stress up"
        case .postWorkout: return "Rested, with a morning workout behind them"
        }
    }

    var icon: String {
        switch self {
        case .assumed: return "person"
        case .rested: return "sun.max"
        case .shortSleep: return "moon.zzz"
        case .stressed: return "bolt.heart"
        case .postWorkout: return "figure.run"
        }
    }
}

extension GuestProfile {
    /// The home's Guest row value.
    var title: String {
        switch self {
        case .preset(let preset): return preset.title
        case .answers: return "Quick answers"
        }
    }

    /// The numbers the lens will show, for Taka at a glance.
    var detail: String {
        let s = snapshot(date: "")
        var parts = [String(format: "%.1f h", s.sleep.hours)]
        if let hrv = s.hrvMs { parts.append("HRV \(Int(hrv.rounded()))") }
        if let hr = s.restingHR { parts.append("HR \(Int(hr.rounded()))") }
        return parts.joined(separator: " · ")
    }
}

struct GuestProfileView: View {
    @Bindable var vm: ShowcaseViewModel
    @Environment(\.dismiss) private var dismiss
    /// The questions' answers, kept even while a preset is chosen.
    @State private var answers = GuestAnswers(sleep: .ok, busyDay: false, exercised: false, hadCoffee: false)

    var body: some View {
        NavigationStack {
            HermesScrollPage {
                presetsSection
                questionsSection
            }
            .navigationTitle("Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .tint(HermesTheme.accent)
        .onAppear {
            if case .answers(let saved) = vm.profile { answers = saved }
        }
    }

    // MARK: Presets

    private var presetsSection: some View {
        HermesSection(header: "Presets", footer: "Pick the one that sounds like your guest.") {
            ForEach(Array(GuestPreset.allCases.enumerated()), id: \.element) { index, preset in
                if index > 0 { HermesDivider() }
                Button { vm.profile = .preset(preset) } label: {
                    HermesRow(title: preset.title, icon: preset.icon,
                              subtitle: preset.explanation, showsChevron: false) {
                        selectionMark(vm.profile == .preset(preset))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Questions

    private var usingAnswers: Bool {
        if case .answers = vm.profile { return true }
        return false
    }

    private var questionsSection: some View {
        HermesSection(header: "Quick questions",
                      footer: usingAnswers
                        ? "Using these answers: \(vm.profile.detail)."
                        : "Ask the guest; answering switches the run to their answers.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    HermesIconTile(systemName: "bed.double")
                    Text("How did you sleep?").font(.system(size: 17)).kerning(-0.43)
                    Spacer(minLength: 0)
                    selectionMark(usingAnswers)
                }
                Picker("How did you sleep?", selection: answerBinding(\.sleep)) {
                    Text("Great").tag(SleepAnswer.great)
                    Text("OK").tag(SleepAnswer.ok)
                    Text("Poor").tag(SleepAnswer.poor)
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            HermesDivider()
            question("Busy day ahead?", icon: "calendar", value: \.busyDay)
            HermesDivider()
            question("Exercised this morning?", icon: "figure.run", value: \.exercised)
            HermesDivider()
            question("Coffee already?", icon: "cup.and.saucer", value: \.hadCoffee)
            if !usingAnswers {
                HermesDivider()
                Button { vm.profile = .answers(answers) } label: {
                    HermesRow("Use these answers", icon: "checkmark.circle", showsChevron: false)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func question(_ title: String, icon: String, value: WritableKeyPath<GuestAnswers, Bool>) -> some View {
        Toggle(isOn: answerBinding(value)) {
            HermesRow(title, icon: icon, showsChevron: false)
        }
        .padding(.trailing, 16)
    }

    /// Answering a question chooses the answers.
    private func answerBinding<T>(_ path: WritableKeyPath<GuestAnswers, T>) -> Binding<T> {
        Binding(
            get: { answers[keyPath: path] },
            set: { newValue in
                answers[keyPath: path] = newValue
                vm.profile = .answers(answers)
            })
    }

    private func selectionMark(_ on: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(HermesTheme.accent)
            .opacity(on ? 1 : 0)
            .accessibilityHidden(!on)
    }
}
