//
// ShowcaseViewModel.swift
//
// Taka's Start button. Owns the showcase settings (machines, the selected
// machine, the guest's morning, the language), pre-renders the clips a run
// needs, prepares the session (language, iPhone mic) and wires a
// ShowcaseRunner to the real lens (HermesDisplayManager through the session
// view model), the voice (speakCueAndWait) and the AI (a 6 s one-shot call).
//
// While a run is active it claims every utterance (Ruling T8) through
// `HermesSessionViewModel.showcaseClaimer`; the claimer and the persona
// override are cleared when the run ends or is reset.
//

import Foundation
import Observation
import os
import SwiftUI
import UIKit

@MainActor
@Observable
final class ShowcaseViewModel {
    static let machineKey = "showcase_machine_id"
    static let languageKey = "showcase_language"
    static let profileKey = "showcase_profile"
    static let askTimeout: TimeInterval = 6
    static let askMaxTokens = 200
    /// Bump when clip art changes so cached files are re-rendered.
    nonisolated static let clipArtVersion = "v1"
    private static let prerenderDebounceNanos: UInt64 = 500_000_000
    private static let logger = Logger(subsystem: "com.flowsxr.emodrink", category: "showcase")

    // MARK: Settings

    var machines: [VendingMachine] {
        didSet {
            saveMachines()
            schedulePrerender()
        }
    }
    var selectedMachineID: String {
        didSet {
            defaults.set(selectedMachineID, forKey: Self.machineKey)
            schedulePrerender()
        }
    }
    var profile: GuestProfile {
        didSet {
            if let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: Self.profileKey) }
            schedulePrerender()
        }
    }
    /// Taka's 日本語/English switch; `ShowcaseDefaults.defaultLanguage` until he touches it.
    var language: Language {
        didSet {
            defaults.set(language.rawValue, forKey: Self.languageKey)
            schedulePrerender()
        }
    }

    // MARK: State

    private(set) var step: ShowcaseStep = .idle
    /// Clips are being rendered (Start waits for them).
    private(set) var preparing = false
    /// From Start until the run ends or is reset.
    private(set) var running = false

    let catalog: DrinkCatalog?

    var selectedMachine: VendingMachine? {
        machines.first { $0.id == selectedMachineID } ?? machines.first
    }

    /// Why Start cannot run, in Taka's language; nil when it can.
    var startBlockedReason: String? {
        let strings = ShowcaseStrings(language: language)
        guard let catalog else { return strings.catalogMissing }
        guard let machine = selectedMachine else { return strings.noMachine }
        let known = machine.drinkIDs.contains { catalog.drink(id: $0) != nil }
        return known || !machine.customDrinks.isEmpty ? nil : strings.machineEmpty
    }

    // MARK: Wiring

    @ObservationIgnored private let hermesVM: HermesSessionViewModel
    @ObservationIgnored private let store: MachineStore
    @ObservationIgnored private let stopLiveDrinkMode: () -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let oneShot = DirectClient()

    @ObservationIgnored private var runner: ShowcaseRunner?
    @ObservationIgnored private var currentRun: ShowcaseRun?
    @ObservationIgnored private var runJob: ClipJob?
    @ObservationIgnored private var runStrings = ShowcaseStrings(language: ShowcaseDefaults.defaultLanguage)
    /// Bumped by every start and reset: a start resuming after reset stops.
    @ObservationIgnored private var startGeneration = 0

    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderKey: String?

    init(hermesVM: HermesSessionViewModel, catalog: DrinkCatalog?, store: MachineStore,
         defaults: UserDefaults = .standard, stopLiveDrinkMode: @escaping () -> Void) {
        self.hermesVM = hermesVM
        self.catalog = catalog
        self.store = store
        self.defaults = defaults
        self.stopLiveDrinkMode = stopLiveDrinkMode
        let loaded = store.load()
        machines = loaded
        selectedMachineID = defaults.string(forKey: Self.machineKey) ?? loaded.first?.id ?? VendingMachine.sample.id
        profile = defaults.data(forKey: Self.profileKey)
            .flatMap { try? JSONDecoder().decode(GuestProfile.self, from: $0) } ?? .preset(.assumed)
        language = defaults.string(forKey: Self.languageKey).flatMap(Language.init(rawValue:))
            ?? ShowcaseDefaults.defaultLanguage
        schedulePrerender()
    }

    // MARK: Machines

    func addMachine() -> VendingMachine {
        let machine = VendingMachine(id: "machine-" + UUID().uuidString, name: "Machine \(machines.count + 1)",
                                     drinkIDs: [], customDrinks: [], navigationEnabled: false, distanceMeters: 40)
        machines.append(machine)
        return machine
    }

    func update(_ machine: VendingMachine) {
        guard let index = machines.firstIndex(where: { $0.id == machine.id }) else { return }
        machines[index] = machine
    }

    func delete(_ id: String) {
        machines.removeAll { $0.id == id }
        if selectedMachineID == id, let first = machines.first { selectedMachineID = first.id }
    }

    private func saveMachines() {
        do { try store.save(machines) } catch {
            Self.logger.error("Saving machines failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Start and reset

    func start() async {
        guard !running, startBlockedReason == nil, let catalog, let machine = selectedMachine else { return }
        startGeneration += 1
        let gen = startGeneration
        running = true
        let lang = language
        let strings = ShowcaseStrings(language: lang)
        // Claimed from the first moment: the guest may talk while clips render.
        hermesVM.showcaseClaimer = { [weak self] text in self?.claim(text) ?? false }

        // Two autopilots on one lens would fight (Ruling 3).
        stopLiveDrinkMode()

        // Language is resolved once per session: a running session in the
        // other language is restarted (Ruling T8).
        EmoDrinkLanguage.setSetting(lang == .ja ? .ja : .en)
        if hermesVM.connectionState != .disconnected, hermesVM.activeLanguage != lang {
            hermesVM.endSession()
            for _ in 0..<50 where hermesVM.connectionState != .disconnected {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard gen == startGeneration else { return }
        }

        _ = await hermesVM.setMicSource(.phone, announceFallback: false)
        guard gen == startGeneration else { return }
        if hermesVM.connectionState == .disconnected { await hermesVM.startSession() }
        guard gen == startGeneration else { return }

        let run: ShowcaseRun
        do {
            run = try ShowcaseRun(machine: machine, profile: profile, catalog: catalog, language: lang,
                                  date: EmoDrinkDay.string())
        } catch {
            teardown()
            return
        }
        let job = ClipJob(run: run, machine: machine, strings: strings)
        await ensureClips(job)
        guard gen == startGeneration else { return }

        currentRun = run
        runJob = job
        runStrings = strings
        let runner = ShowcaseRunner(run: run, strings: strings, effects: self, clock: RealShowcaseClock())
        runner.onStepChange = { [weak self] step in self?.runnerStepChanged(step) }
        self.runner = runner
        await runner.start()
    }

    func reset() {
        startGeneration += 1
        let active = runner
        runner = nil
        active?.reset()
        hermesVM.stopSpeaking()
        teardown()
    }

    private func runnerStepChanged(_ newStep: ShowcaseStep) {
        step = newStep
        switch newStep {
        case .deck:
            // Free talk falls back to the showcase persona, should anything
            // reach the assistant.
            if let currentRun {
                hermesVM.setPersonaOverride(ShowcasePersona.systemPrompt(run: currentRun, language: runStrings.language))
            }
        case .idle:
            teardown()
        default:
            break
        }
    }

    /// The run is over: release the voice loop back to the assistant.
    private func teardown() {
        hermesVM.showcaseClaimer = nil
        hermesVM.setPersonaOverride(nil)
        runner = nil
        currentRun = nil
        runJob = nil
        running = false
        step = .idle
    }

    private func claim(_ text: String) -> Bool {
        guard running else { return false }
        if let runner {
            Task { _ = await runner.handleUtterance(text) }
        }
        return true
    }

    private func tapped(_ button: ShowcaseButton) {
        let command: ShowcaseCommand
        switch button {
        case .previous: command = .previous
        case .why: command = .why
        case .next: command = .next
        case .choose: command = .choose
        case .back: command = .back
        }
        runner?.handle(command)
    }

    // MARK: Clip pre-render (Ruling T8)

    /// Everything one run's clips depend on, and where they live.
    private struct ClipJob {
        let run: ShowcaseRun
        let machine: VendingMachine
        let strings: ShowcaseStrings
        let key: String

        init(run: ShowcaseRun, machine: VendingMachine, strings: ShowcaseStrings) {
            self.run = run
            self.machine = machine
            self.strings = strings
            var snapshot = run.snapshot
            snapshot.date = ""
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let numbers = (try? encoder.encode(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            key = [ShowcaseViewModel.clipArtVersion, strings.language.rawValue, machine.id, machine.name,
                   machine.drinkIDs.joined(separator: ","),
                   machine.customDrinks.map { "\($0.id)=\($0.name)" }.joined(separator: ","),
                   String(machine.distanceMeters), numbers].joined(separator: "|")
        }

        var kinds: [ShowcaseClipKind] {
            run.steps.compactMap {
                switch $0 {
                case .navigate: return .navigate
                case .morning: return .morning
                case .scan: return .scan
                default: return nil
                }
            }
        }

        func url(_ kind: ShowcaseClipKind) -> URL {
            ClipRenderer.cacheURL(kind: kind.rawValue, key: kind.rawValue + "|" + key)
        }
    }

    /// Selection changed: render its clips after 0.5 s of quiet. Never
    /// while a run is starting or playing (it would cancel the run's render).
    private func schedulePrerender() {
        debounceTask?.cancel()
        guard !running else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.prerenderDebounceNanos)
            guard let self, !Task.isCancelled, !self.running else { return }
            guard let catalog = self.catalog, let machine = self.selectedMachine,
                  let run = try? ShowcaseRun(machine: machine, profile: self.profile, catalog: catalog,
                                             language: self.language, date: EmoDrinkDay.string())
            else { return }
            await self.ensureClips(ClipJob(run: run, machine: machine, strings: ShowcaseStrings(language: self.language)))
        }
    }

    /// Renders the job's missing clips, joining a render of the same key
    /// already in flight and cancelling one for an older selection.
    private func ensureClips(_ job: ClipJob) async {
        let task: Task<Void, Never>
        if let renderTask, renderKey == job.key {
            task = renderTask
        } else {
            renderTask?.cancel()
            renderKey = job.key
            task = Task { [weak self] in await self?.render(job) }
            renderTask = task
        }
        preparing = true
        await task.value
        if renderKey == job.key {
            renderTask = nil
            renderKey = nil
            preparing = false
        }
    }

    private func render(_ job: ClipJob) async {
        for kind in job.kinds {
            guard !Task.isCancelled else { return }
            let url = job.url(kind)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            let strings = job.strings, run = job.run, machine = job.machine
            let started = Date()
            do {
                switch kind {
                case .navigate:
                    try await ClipRenderer.render(duration: run.duration(of: .navigate), to: url) { t in
                        NavigateClipArt(machine: machine, strings: strings, t: t)
                    }
                case .morning:
                    try await ClipRenderer.render(duration: run.duration(of: .morning), to: url) { t in
                        MorningClipArt(snapshot: run.snapshot, strings: strings, t: t)
                    }
                case .scan:
                    try await ClipRenderer.render(duration: run.duration(of: .scan), to: url) { t in
                        ScanClipArt(machineDrinks: run.machineDrinks, strings: strings, t: t)
                    }
                }
                Self.logger.info("Rendered \(kind.rawValue, privacy: .public) clip in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s")
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Rendering the \(kind.rawValue, privacy: .public) clip failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - ShowcaseEffects

extension ShowcaseViewModel: ShowcaseEffects {
    /// Sends the pre-rendered clip; the runner holds the step for the clip's
    /// length on its own clock, so a missing file or lens keeps the timing.
    func play(clip: ShowcaseClipKind) async {
        guard let job = runJob else { return }
        let url = job.url(clip)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.logger.warning("No \(clip.rawValue, privacy: .public) clip on disk; the step runs without it")
            return
        }
        await hermesVM.playShowcaseClip(url)
    }

    func show(deck: ShowcaseDeck, mode: DeckMode, buttons: [ShowcaseButton]) {
        let image: UIImage?
        if mode == .chosen {
            image = deck.cards.first.flatMap { LensRenderer.uiImage(ConfirmArt(card: $0, line: runStrings.confirmLine)) }
        } else {
            image = LensRenderer.uiImage(DeckArt(deck: deck, mode: mode))
        }
        guard let image else { return }
        hermesVM.showShowcaseCard(image, buttons: buttons, strings: runStrings) { [weak self] button in
            self?.tapped(button)
        }
    }

    func say(_ text: String) async {
        await hermesVM.speakCueAndWait(text)
    }

    /// One AI call raced against 6 s; nil on timeout or error.
    func ask(system: String, user: String) async -> String? {
        let client = oneShot
        let timeout = Self.askTimeout, maxTokens = Self.askMaxTokens
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                try? await client.askOneShotText(systemPrompt: system, userText: user,
                                                 maxTokens: maxTokens, timeout: timeout)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func clearLens() {
        hermesVM.clearLens()
    }
}
