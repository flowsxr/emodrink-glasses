//
// ShowcaseViewModel.swift
//
// Taka's Start button. Owns the showcase settings (machines, the selected
// machine, the guest's morning, the language), pre-renders the clips a run
// needs, prepares the session (language, iPhone mic or the
// glasses' own speech behind `showcase_glasses_speech`) and wires a
// ShowcaseRunner to the real lens (HermesDisplayManager through the session
// view model), the voice (speakCueAndWait) and the AI (a 6 s one-shot call).
//
// It claims every utterance through `HermesSessionViewModel.showcaseClaimer`
// while the showcase owns the voice loop: during a run (Ruling T8) the
// runner answers, and between runs, while its session stays up for the next
// guest, everything is swallowed. During a run, problems go to the run
// notice, never alerts. The persona override, the run notice sink and the
// app-wide language and mic it borrowed are given back when the run ends or
// is reset.
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
    /// Developer setting: swipes on the glasses or Neural Band drive the
    /// deck. Off by default until a device shows that a nav event does not
    /// also move the lens buttons' focus (it would then act twice).
    static let glassesSwipeKey = "showcase_glasses_swipe"
    static let glassesSwipeDefault = false
    private static let navKey = "showcase"
    static let askTimeout: TimeInterval = 6
    static let askMaxTokens = 200
    /// Bump when clip art changes so cached files are re-rendered.
    nonisolated static let clipArtVersion = "v3-264px-200k"
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
    /// Something Taka should know about the current run (no voice session),
    /// in the run's language; nil when all is well.
    private(set) var runNotice: String?

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
    /// The app-wide settings a run saves over (the language setting and the
    /// saved mic), as stored before the first Start; put back at teardown
    /// so "auto" and a headset choice survive the showcase.
    private struct BorrowedSettings {
        let language: String?
        let mic: String?
    }
    @ObservationIgnored private var borrowed: BorrowedSettings?

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
        // Consulted only while the showcase owns the voice loop.
        hermesVM.showcaseClaimer = { [weak self] text in self?.claim(text) ?? false }
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
        runNotice = nil
        let lang = language
        let strings = ShowcaseStrings(language: lang)
        // Claimed from the first moment: the guest may talk while clips
        // render. Problems from here on are Taka's run notice.
        hermesVM.showcaseRunActive = true
        hermesVM.showcaseIssueSink = { [weak self] message in self?.noteRunIssue(message) }
        borrowSettings()

        // Only with the swipe setting on: no inputs capability otherwise.
        if defaults.object(forKey: Self.glassesSwipeKey) as? Bool ?? Self.glassesSwipeDefault {
            hermesVM.glassesLink.observeNavigation(Self.navKey) { [weak self] nav in self?.navigated(nav) }
        }

        // Two autopilots on one lens would fight (Ruling 3). Also ends a
        // drink moment from "what should I drink", drink mode on or not.
        stopLiveDrinkMode()

        // Language is resolved once per session: a running session in the
        // other language is restarted (Ruling T8). So is live drink mode's
        // session, which has a camera open: a run never uses one.
        EmoDrinkLanguage.setSetting(lang == .ja ? .ja : .en)
        if hermesVM.connectionState != .disconnected,
           hermesVM.activeLanguage != lang || hermesVM.sessionUsesVision {
            hermesVM.endSession()
            for _ in 0..<50 where hermesVM.connectionState != .disconnected {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard gen == startGeneration else { return }
        }

        // The iPhone mic, unless the Developer setting lets the glasses'
        // own speech hear the run (its locale is checked again once the
        // capability reports one; a mismatch or error falls back).
        let glassesSpeech = GlassesSpeechRouting.showcaseUsesGlassesSpeech(
            enabled: hermesVM.glassesSpeechEnabled,
            glassesAvailable: hermesVM.glassesAvailable || hermesVM.isGlassesConnected,
            locale: hermesVM.glassesLink.glassesSpeechLocale, language: lang)
        // Voice and lens only: no camera, so no camera prompt mid-run, and
        // start-up problems (a mic switch included) become Taka's run
        // notice instead of an alert.
        // A reused showcase session already has its mic: no switch.
        var issues: [String] = []
        let mic: MicSource = glassesSpeech ? .glassesSpeech : .phone
        if !(hermesVM.micSource == mic && hermesVM.connectionState != .disconnected) {
            _ = await hermesVM.setMicSourceQuietly(mic) { issues.append($0) }
        }
        guard gen == startGeneration else { return }
        if hermesVM.connectionState == .disconnected {
            await hermesVM.startSessionWithoutVision { issues.append($0) }
        }
        guard gen == startGeneration else { return }
        // A reused session whose glasses were out of reach at its start.
        hermesVM.ensureShowcaseLens()
        hermesVM.logVisionDiagnostics("showcase start")
        // No session (no key, audio failure): the run still plays on the
        // lens and the phone mirror, but nobody is listening.
        if hermesVM.connectionState == .disconnected { issues.insert(strings.noVoiceSession, at: 0) }
        issues.forEach(noteRunIssue)

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

    /// The showcase's session, left up after a run so the next guest
    /// starts fast, holds the mic with no run on.
    var idleSessionHoldsMic: Bool {
        !running && hermesVM.connectionState != .disconnected && !hermesVM.sessionUsesVision
    }

    /// Ends that idle session (add-by-voice needs the mic); the next Start
    /// opens a new one. Nothing while a run is on or another session runs.
    func endIdleSession() async {
        guard idleSessionHoldsMic else { return }
        hermesVM.endSession()
        for _ in 0..<50 where hermesVM.connectionState != .disconnected {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func reset() {
        startGeneration += 1
        runNotice = nil
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

    /// The run is over. Its session, if any, stays up for the next guest
    /// and keeps the voice loop (`showcaseOwnsVoice`) until live drink mode
    /// or a Stop ends it; alerts and the borrowed settings come back now.
    private func teardown() {
        hermesVM.glassesLink.stopObservingNavigation(Self.navKey)
        hermesVM.setPersonaOverride(nil)
        hermesVM.showcaseRunActive = false
        hermesVM.showcaseIssueSink = nil
        restoreSettings()
        runner = nil
        currentRun = nil
        runJob = nil
        running = false
        step = .idle
    }

    /// Offered every utterance while the showcase owns the voice loop: a
    /// run's go to the runner, and between runs (or before the runner
    /// exists) they are swallowed, so nothing reaches the assistant or
    /// starts a drink moment that could fire into the next run.
    private func claim(_ text: String) -> Bool {
        if running, let runner {
            Task { _ = await runner.handleUtterance(text) }
        }
        return true
    }

    /// A problem during the run: Taka's run notice, once per message.
    private func noteRunIssue(_ message: String) {
        guard running, !message.isEmpty else { return }
        if let current = runNotice {
            if !current.contains(message) { runNotice = current + " " + message }
        } else {
            runNotice = message
        }
    }

    /// Notes the app-wide settings a run saves over, once until restored.
    private func borrowSettings() {
        guard borrowed == nil else { return }
        borrowed = BorrowedSettings(language: UserDefaults.standard.string(forKey: EmoDrinkLanguage.settingKey),
                                    mic: hermesVM.savedMicSourceSetting)
    }

    /// Puts back the language setting and the saved mic. The showcase
    /// session keeps the language it resolved and the mic it has; the
    /// next session (live drink mode, or a run's restart) reads these.
    private func restoreSettings() {
        guard let saved = borrowed else { return }
        borrowed = nil
        if let language = saved.language {
            UserDefaults.standard.set(language, forKey: EmoDrinkLanguage.settingKey)
        } else {
            UserDefaults.standard.removeObject(forKey: EmoDrinkLanguage.settingKey)
        }
        hermesVM.restoreSavedMicSource(saved.mic)
    }

    /// Swipe forward/back rotate the deck; deck step only. Select is left
    /// to the native lens buttons, which already handle it.
    private func navigated(_ nav: GlassesLink.GlassesNav) {
        guard running, step == .deck,
              defaults.object(forKey: Self.glassesSwipeKey) as? Bool ?? Self.glassesSwipeDefault else { return }
        switch nav {
        case .forward: runner?.handle(.next)
        case .backward: runner?.handle(.previous)
        }
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
    /// A lens that did not take the clip (nothing newer replaced it) gets
    /// the clip's art at t = 1 as a still card with no buttons instead, so
    /// it never stays blank for the step.
    func play(clip: ShowcaseClipKind) async {
        guard let job = runJob else { return }
        let url = job.url(clip)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.logger.warning("No \(clip.rawValue, privacy: .public) clip on disk; the step runs without it")
            return
        }
        guard await hermesVM.playShowcaseClip(url) == .failed,
              !Task.isCancelled, running, runJob?.key == job.key else { return }
        Self.logger.warning("The lens did not take the \(clip.rawValue, privacy: .public) clip; sending a still")
        guard let still = stillFrame(clip, job) else { return }
        hermesVM.showShowcaseCard(still, buttons: [], strings: job.strings) { _ in }
    }

    private func stillFrame(_ clip: ShowcaseClipKind, _ job: ClipJob) -> UIImage? {
        let strings = job.strings, run = job.run
        switch clip {
        case .navigate: return LensRenderer.uiImage(NavigateClipArt(machine: job.machine, strings: strings, t: 1))
        case .morning: return LensRenderer.uiImage(MorningClipArt(snapshot: run.snapshot, strings: strings, t: 1))
        case .scan: return LensRenderer.uiImage(ScanClipArt(machineDrinks: run.machineDrinks, strings: strings, t: 1))
        }
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

    func stopSpeaking() {
        hermesVM.stopSpeaking()
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
