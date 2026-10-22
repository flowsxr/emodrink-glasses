//
// ShowcaseHomeView.swift
//
// Taka's screen, and the app's root. Top to bottom:
//   1. the live mirror: the simulated lens (what the guest sees), square,
//      with the run's step under it;
//   2. the run's settings: machine, guest, 日本語/English, navigation;
//   3. a big Start, which becomes Reset while a run plays, with why it is
//      blocked or what Taka should know about the run;
//   4. rows for Machines, Live drink mode and Settings.
// Everything it drives lives in ShowcaseViewModel. Taka's labels are
// English; drink names follow the run's language.
//

import SwiftUI

/// Pages pushed on the root NavigationStack.
enum ShowcaseRoute: Hashable {
    case machines
    case machine(String)
    case liveDrinkMode
}

struct ShowcaseHomeView: View {
    @Bindable var vm: ShowcaseViewModel
    let hermesVM: HermesSessionViewModel
    let openSettings: () -> Void

    @State private var showProfile = false

    var body: some View {
        // Start / Reset is pinned at the bottom; the mirror takes at most
        // 42% of the height left, so mirror, settings and Start share one
        // screen.
        GeometryReader { geo in
            HermesScrollPage {
                ShowcaseMirror(content: hermesVM.lensContent, stepLabel: stepLabel, live: vm.running)
                    .frame(width: min(geo.size.width - 32, geo.size.height * 0.42))
                    .frame(maxWidth: .infinity)

                setupSection
                moreSection
            }
        }
        .background(HermesTheme.groupedCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .navigationTitle("Showcase")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
        .sheet(isPresented: $showProfile) {
            GuestProfileView(vm: vm)
        }
    }

    // MARK: Step

    private var stepLabel: String {
        guard vm.running else { return vm.preparing ? "Preparing clips" : "Ready" }
        switch vm.step {
        case .idle: return vm.preparing ? "Preparing clips" : "Starting"
        case .navigate: return "Navigate"
        case .morning: return "Morning"
        case .scan: return "Scan"
        case .deck: return "Deck"
        case .chosen: return "Chosen"
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        HermesSection(header: "This run",
                      footer: vm.running ? "Settings are locked while the run plays. Reset to change them." : nil) {
            machineRow
            HermesDivider()
            Button { showProfile = true } label: {
                HermesRow(vm.profile.title, icon: "person", subtitle: "Guest · \(vm.profile.detail)")
            }
            .buttonStyle(.plain)
            HermesDivider()
            HermesRow(title: "Language", icon: "character.bubble", showsChevron: false) {
                Picker("Language", selection: $vm.language) {
                    Text("日本語").tag(Language.ja)
                    Text("English").tag(Language.en)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            HermesDivider()
            Toggle(isOn: navigationBinding) {
                HermesRow("Walk to the machine", icon: "figure.walk", subtitle: navigationSubtitle,
                          showsChevron: false)
            }
            .padding(.trailing, 16)
            .disabled(vm.selectedMachine == nil)
        }
        .disabled(vm.running)
    }

    private var machineRow: some View {
        Menu {
            Picker("Machine", selection: $vm.selectedMachineID) {
                ForEach(vm.machines) { machine in
                    Text(machine.name).tag(machine.id)
                }
            }
        } label: {
            HermesRow(title: "Machine", icon: "cup.and.saucer", subtitle: drinkCountText, showsChevron: false) {
                Text(vm.selectedMachine?.name ?? "None")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var drinkCountText: String? {
        guard let machine = vm.selectedMachine else { return nil }
        let count = machine.drinkIDs.count + machine.customDrinks.count
        return count == 1 ? "1 drink" : "\(count) drinks"
    }

    private var navigationSubtitle: String {
        guard let machine = vm.selectedMachine else { return "No machine" }
        return machine.navigationEnabled ? "Starts with a \(machine.distanceMeters) m walk" : "Off: starts with the morning"
    }

    /// The selected machine's own setting, saved with the machine.
    private var navigationBinding: Binding<Bool> {
        Binding(
            get: { vm.selectedMachine?.navigationEnabled ?? false },
            set: { on in
                guard var machine = vm.selectedMachine else { return }
                machine.navigationEnabled = on
                vm.update(machine)
            })
    }

    // MARK: Start

    /// Pinned under the scroll: the notices, then Start or Reset.
    private var startBar: some View {
        VStack(spacing: 8) {
            if let reason = vm.startBlockedReason, !vm.running {
                HermesNotice(text: reason, systemImage: "exclamationmark.circle")
            }
            if let notice = vm.runNotice {
                HermesNotice(text: notice, systemImage: "info.circle")
            }
            Group {
                if vm.running {
                    HermesPrimaryButton(title: "Reset for the next guest", systemImage: "arrow.counterclockwise") {
                        vm.reset()
                    }
                } else {
                    ShowcaseStartButton(preparing: vm.preparing,
                                        enabled: vm.startBlockedReason == nil && !vm.preparing) {
                        Task { await vm.start() }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(HermesTheme.groupedCanvas.opacity(0.96).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { HermesDivider() }
    }

    // MARK: More

    private var moreSection: some View {
        HermesSection {
            NavigationLink(value: ShowcaseRoute.machines) {
                HermesRow("Machines", icon: "square.grid.3x3", value: "\(vm.machines.count)")
            }
            .buttonStyle(.plain)
            HermesDivider()
            NavigationLink(value: ShowcaseRoute.liveDrinkMode) {
                HermesRow("Live drink mode", icon: "eye", subtitle: "The real camera and body data")
            }
            .buttonStyle(.plain)
            .disabled(vm.running)
            HermesDivider()
            Button(action: openSettings) {
                HermesRow("Settings", icon: "gearshape")
            }
            .buttonStyle(.plain)
            .disabled(vm.running)
        }
    }
}

// MARK: - Start button

/// The big Start: taller than the stock primary button, with a spinner
/// while the run's clips render.
private struct ShowcaseStartButton: View {
    let preparing: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if preparing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 17, weight: .semibold))
                }
                Text(preparing ? "Preparing…" : "Start")
                    .font(.system(size: 19, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(enabled || preparing ? HermesTheme.accent : Color.secondary.opacity(0.4),
                        in: Capsule())
            .opacity(preparing ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Mirror

/// What the lens shows right now, square, with the run's step on it. A
/// showcase card or clip fills the square edge to edge, exactly as the
/// 600 x 600 lens draws it; anything else (live drink mode's HUD) shows
/// in the simulated lens, and a blank lens is a quiet dark card.
struct ShowcaseMirror: View {
    let content: LensContent
    let stepLabel: String
    let live: Bool

    var body: some View {
        ZStack {
            HermesTheme.lensChrome
            switch content {
            case .showcase(let image, let clip):
                ShowcaseLensMedia(image: image, clip: clip)
            default:
                if content.isBlank {
                    VStack(spacing: 8) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 30, weight: .light))
                        Text("The lens is idle")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(HermesTheme.cream.opacity(0.45))
                } else {
                    SimulatedLensView(content: content, compact: true)
                        .padding(14)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) {
            stepPill.padding(10)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror of the lens")
    }

    private var stepPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live ? HermesTheme.online : HermesTheme.cream.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(stepLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HermesTheme.cream)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(HermesTheme.lensChrome.opacity(0.75), in: Capsule())
    }
}
