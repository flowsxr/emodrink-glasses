//
// HermesSessionViewModel.swift
//
// Core view model managing the Hermes voice conversation session.
// Connects to Meta glasses, captures audio, streams to Hermes Agent,
// and plays back responses through the glasses.
//

import MWDATCore
import MWDATSpeech
import Observation
import os
import SwiftUI

@Observable
@MainActor
final class HermesSessionViewModel {
    // MARK: - Published state

    /// The language the session hears and speaks right now. Japanese only
    /// when both a ja-JP recognizer and a ja-JP voice exist.
    private(set) var activeLanguage: Language = .en
    /// Only a default-quality voice is installed for the language.
    private(set) var voiceNeedsInstallHint = false
    private(set) var voiceName: String?
    /// The Gemini voice speaking the lines (Kore / Aoede), nil when the
    /// cloud voice is off or not bundled: then only the on-device voice.
    private(set) var cloudVoiceName: String?
    /// The last cloud attempt failed, so that line used the on-device voice.
    private(set) var cloudVoiceFellBack = false
    /// A Gemini text-to-speech key and model were bundled into this build.
    var cloudVoiceAvailable: Bool { BundledAIKey.ttsKey != nil && BundledAIKey.ttsModel != nil }
    /// Settings toggle for the natural cloud voice (default on).
    var cloudVoiceEnabled: Bool =
        (UserDefaults.standard.object(forKey: HermesSessionViewModel.cloudVoiceKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(cloudVoiceEnabled, forKey: Self.cloudVoiceKey)
            applyCloudVoice()
        }
    }
    static let cloudVoiceKey = "emodrink_cloud_voice"

    var connectionState: HermesConnectionState = .disconnected
    /// Bumped by every `endSession()`. A `startSession()` that awaited
    /// across a Stop sees a newer generation and returns without bringing
    /// the session back.
    private(set) var sessionGeneration = 0
    /// The generation a start's own failure (no key, audio setup) ended
    /// the session at, so a caller can tell that from a Stop.
    private(set) var startFailedGeneration: Int?

    /// True when the session was ended after `generation` by something other
    /// than the start's own failure: a Stop, or the glasses going away.
    func stoppedSince(_ generation: Int) -> Bool {
        sessionGeneration != generation && startFailedGeneration != sessionGeneration
    }
    /// GlassesLink has a started DeviceSession with the glasses.
    var isGlassesConnected: Bool { glassesLink.isSessionStarted }
    /// Words recognized so far in the current utterance (live)
    var liveTranscript: String = ""
    /// Mic input level 0..~1 for the UI meter
    var micLevel: Float = 0
    /// Test-panel results keyed by test name: nil=never run, ""=pass, else error
    var testResults: [String: String?] = [:]
    var testRunning: Set<String> = []
    /// The failure message from the most recently completed test, cleared on
    /// a pass. `testResults` is a dictionary, so scanning its `.values` for
    /// "the" failure returns whichever one the dictionary enumerates first -
    /// this is set explicitly by `runTest` so the Developer panel always
    /// shows the outcome of the test that was just run.
    var lastTestFailure: String? = nil
    /// Outputs of the last Developer-panel Photo / Sound tests, so the panel
    /// can show what actually happened instead of burying it in the chat.
    var lastTestPhoto: UIImage? = nil
    var lastTestPhotoSource: String? = nil
    var lastTestAudioRoute: String? = nil
    /// The Developer Display test's last outcome, in the spec's words.
    var displayTestReport: String?
    /// The Display test's timeline: every DisplayState the SDK reported and
    /// each test step, "HH:mm:ss event". Also logs Clear lens.
    var displayTestTrace: [String] = []

    // MARK: EmoDrink hooks (set by EmoDrinkViewModel)

    /// While a drink is on the lens, every finalized utterance is offered
    /// here first; true = it was a reply (why / something else / thanks) and
    /// nothing reaches the brain. False = a question for the drink persona.
    @ObservationIgnored var emoDrinkClaimer: (@MainActor (String) -> Bool)?
    /// While a showcase run is active it claims EVERY finalized utterance
    /// (consulted before `emoDrinkClaimer`), so the assistant's reply card
    /// never replaces the deck. Also keeps listening partials off the lens.
    @ObservationIgnored var showcaseClaimer: (@MainActor (String) -> Bool)?
    /// "what should I drink" / "start drink mode" / "stop drink mode".
    @ObservationIgnored var onEmoDrinkIntent: (@MainActor (HermesIntent) -> Void)?
    /// The session is being torn down; drink mode must stop its stream.
    @ObservationIgnored var onEmoDrinkSessionEnding: (@MainActor () -> Void)?
    /// When the lens would otherwise blank after a reply's dwell, EmoDrink may restore its card. Returns true when it drew something.
    @ObservationIgnored var emoDrinkLensIdle: (@MainActor () -> Bool)?
    /// Queued cues (`speakCue(_:queued: true)`) waiting for the current one
    /// to finish; drained one at a time by `speechSynthesizer.onFinished`.
    @ObservationIgnored private var cueQueue: [String] = []
    /// `speakCueAndWait`'s caller, resumed when its line ends, on
    /// `stopSpeaking()`, on cancellation or after a length-based cap.
    @ObservationIgnored private var speechWaiter: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var speechWaiterToken = 0
    /// Replacing an on-device line fires one onFinished for the cancelled
    /// line while the new one plays: that finish is ignored ENTIRELY (no
    /// waiter release, no state change, no unsuspend).
    @ObservationIgnored private var speechFinishGate = SpeechFinishGate()

    /// Glasses camera permission (granted in the Meta AI app); nil = unknown.
    /// GlassesLink holds it, so the basics screen and Settings agree.
    var cameraPermissionGranted: Bool? { glassesLink.cameraPermissionGranted }
    /// Preferred microphone source; the banner chip shows the ACTUAL route
    var micSource: MicSource = HermesSessionViewModel.storedMicSource()
    /// Developer setting `showcase_glasses_speech` (default off): the
    /// glasses' own speech recognition may be the mic. Turning it off while
    /// it is the mic hops back to the iPhone mic.
    var glassesSpeechEnabled: Bool = GlassesSpeechRouting.isEnabled() {
        didSet {
            UserDefaults.standard.set(glassesSpeechEnabled, forKey: GlassesSpeechRouting.settingKey)
            if !glassesSpeechEnabled, micSource == .glassesSpeech {
                Task { @MainActor [weak self] in _ = await self?.setMicSource(.phone, announceFallback: false) }
            }
        }
    }
    /// Glasses display HUD (Ray-Ban Display): live transcript, replies,
    /// status on the lens. Default on; harmless on non-display glasses.
    var displayHUDEnabled: Bool =
        (UserDefaults.standard.object(forKey: "display_hud_enabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(displayHUDEnabled, forKey: "display_hud_enabled")
            if !displayHUDEnabled {
                displayManager.deactivate()
            } else if glassesSessionRunning {
                if lensBlockedByCallScreen {
                    // HUD and the glasses' HFP mic are mutually exclusive
                    // (their call screen covers the lens). HUD wins: hop
                    // back to the iPhone mic, which re-attaches the
                    // display when the route settles.
                    Task { @MainActor [weak self] in
                        guard let self, self.micSource == .glasses else { return }
                        await self.setMicSource(.phone)
                        // News, not a fault: `show(_:)` is the error channel
                        // and also fails any pending Developer-panel test.
                        self.show(notice: "Switched to the iPhone mic - the lens HUD can't show while the glasses' hands-free mic is active.")
                    }
                } else {
                    displayManager.activate()
                }
            }
        }
    }
    /// Silent mode: when the display is attached, show the reply as text
    /// instead of speaking it. No effect while the display is unavailable.
    var displaySilentMode: Bool =
        UserDefaults.standard.bool(forKey: "display_silent_mode") {
        didSet {
            UserDefaults.standard.set(displaySilentMode, forKey: "display_silent_mode")
        }
    }
    /// Attach time/location/status context to every query
    var contextEnabled: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.enabledKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(contextEnabled, forKey: DeviceContextProvider.enabledKey)
            if contextEnabled, connectionState != .disconnected {
                contextProvider.start()
            } else if !contextEnabled {
                contextProvider.stop()
            }
        }
    }
    /// Include exact coordinates (vs area name only)
    var contextPreciseLocation: Bool =
        (UserDefaults.standard.object(forKey: DeviceContextProvider.preciseKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(
                contextPreciseLocation, forKey: DeviceContextProvider.preciseKey
            )
        }
    }
    /// Live context line for the Settings preview
    var contextPreview: String? {
        contextProvider.contextLine()
    }
    /// Mirror of the display manager's status for SwiftUI
    var displayStatus: DisplayHUDStatus = .off
    /// Selected direct-mode provider id (drives Settings + status chip)
    var directProviderID: String = UserDefaults.standard.string(forKey: "direct_provider_id") ?? "anthropic" {
        didSet {
            UserDefaults.standard.set(directProviderID, forKey: "direct_provider_id")
            reloadDirectProviderState()
        }
    }
    /// Model id for the current provider; applies from the next question
    var directModel: String = "" {
        didSet { UserDefaults.standard.set(directModel, forKey: "direct_model_\(directProviderID)") }
    }
    /// Custom base URL for providers that allow one (OpenAI-compatible / Ollama)
    var directBaseURL: String = "" {
        didSet { UserDefaults.standard.set(directBaseURL, forKey: "direct_base_url_\(directProviderID)") }
    }
    /// Whether the current provider has a key stored (drives Settings UI state)
    var hasDirectKey: Bool = false

    /// Reload model / base URL / key status when the provider changes.
    func reloadDirectProviderState() {
        let provider = DirectClient.provider
        directModel = DirectClient.model(for: provider)
        directBaseURL = provider.allowsCustomBaseURL ? DirectClient.baseURL(for: provider) : ""
        hasDirectKey = DirectClient.hasKey(for: provider.id)
    }

    /// The current direct-mode provider (for labels + capability checks)
    var directProvider: AIProvider { DirectClient.provider }
    var lastTranscript: String = ""
    var lastResponse: String = ""
    var conversationHistory: [ConversationTurn] = []
    var showError: Bool = false
    var errorMessage: String = ""
    /// Advisories that are NOT failures: a fallback that worked, a HUD that
    /// had to step aside. They went through `showError`, whose alert is
    /// titled "Hermes Error" - which told the user that using the iPhone mic
    /// instead of an absent headset was something that had gone wrong.
    var showNotice: Bool = false
    var noticeMessage: String = ""
    /// Optional second button on the notice ("Update glasses"). Cleared by
    /// every notice that does not set one.
    var noticeAction: NoticeAction?
    /// Why the last glasses connect failed, when the SDK said why (update
    /// required). startSession puts it in the fallback notice.
    @ObservationIgnored var glassesConnectIssue: GlassesConnectIssue?


    // MARK: - Constants

    /// How long the speaker's tail is given to fade before the recognizer
    /// listens again. There is no echo cancellation on the phone route (the
    /// audio session runs in `.default`, not `.voiceChat`), so a shorter
    /// wait means transcribing the end of Hermes's own reply.
    private static let speechResumeGraceNanos: UInt64 = 700_000_000

    /// Both mic fallbacks are announced from two places - session start and
    /// a mid-session switch - and must say the same thing in both.
    private static let glassesMicFallbackNotice =
        "Glasses mic not available - using iPhone mic"
    private static let headsetMicFallbackNotice =
        "No headset mic found - using iPhone mic. Connect AirPods or another Bluetooth headset first."

    private static let glassesSpeechFallbackNotice =
        "Glasses speech not available - using iPhone mic"

    private static let micSourceKey = "mic_source"

    /// The saved mic; glasses speech only while its Developer setting is on.
    private static func storedMicSource() -> MicSource {
        let stored = MicSource(rawValue: UserDefaults.standard.string(forKey: micSourceKey) ?? "") ?? .phone
        return stored == .glassesSpeech && !GlassesSpeechRouting.isEnabled() ? .phone : stored
    }

    // MARK: Glasses speech state (MicSource.glassesSpeech)

    /// This session hears through the glasses' speech recognition; the
    /// on-device recognizer is not running.
    @ObservationIgnored private var glassesSpeechInUse = false
    /// The capability is attached and listening (not suspended).
    @ObservationIgnored private var glassesSpeechRunning = false
    /// Bumped by every start and stop: callbacks from an older capability
    /// carry an older generation and are ignored.
    @ObservationIgnored private var glassesSpeechGeneration = 0
    /// SFSpeechRecognizer authorization, from session start: a fall back to
    /// the iPhone mic starts the recognizer only when it may run.
    @ObservationIgnored private var speechAuthorized = false

    // MARK: - Private

    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let wearables: WearablesInterface
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let audioManager = HermesAudioManager()
    @ObservationIgnored private let phoneCameraManager = PhoneCameraManager()
    @ObservationIgnored private let speechRecognizer = HermesSpeechRecognizer()
    @ObservationIgnored private let speechSynthesizer = HermesSpeechSynthesizer()
    @ObservationIgnored private let directClient = DirectClient()
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored let displayManager: HermesDisplayManager
    /// The one path to the glasses (session, display, camera), shared with
    /// the Glasses basics screen. Internal for the extensions.
    @ObservationIgnored let glassesLink: GlassesLink
    /// The Ray-Ban camera as a VisionSource, through GlassesLink.
    @ObservationIgnored let glassesVision: GlassesLinkVision
    @ObservationIgnored private let contextProvider = DeviceContextProvider()
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var pendingPhoto: Data?
    /// Last photo sent in Direct mode, reused only when a fresh capture fails.
    @ObservationIgnored private var lastDirectPhoto: Data?
    @ObservationIgnored private var lastDirectPhotoAt: Date?

    /// Resumed by the first reply (or error) that follows a test's query.
    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored
    var pendingTestOutcome: CheckedContinuation<Void, Error>?

    // Internal, not private: the +Glasses / +Developer extensions use it.
    @ObservationIgnored var askedForCameraGrant = false

    /// Exposed for UI to show audio route
    var audio: HermesAudioManager { audioManager }

    /// The iPhone camera, for the phone-mode screen's status tiles.
    var phoneCamera: PhoneCameraManager { phoneCameraManager }

    /// The camera EmoDrink sees through: the Ray-Ban, or the iPhone in phone mode.
    var vision: VisionSource {
        visionRoute == .phone ? phoneCameraManager : glassesVision
    }

    /// Pinned once a session (or the Lens view) commits to an eye, so a
    /// momentary SDK flap cannot redirect a capture to a camera that isn't
    /// running - the bug behind "remember this person" saving a note with no
    /// photo.
    @ObservationIgnored private var pinnedVisionRoute: VisionRoute?

    /// Which eye is in use, or would be if a session started now.
    var visionRoute: VisionRoute {
        pinnedVisionRoute ?? VisionRouting.route(
            glassesEligible: glassesAvailable, preference: phoneModePreference
        )
    }

    /// False only when the fallback is off and no glasses are reachable.
    var canStartSession: Bool {
        VisionRouting.canStartSession(
            glassesEligible: glassesAvailable, preference: phoneModePreference
        )
    }

    /// Is there an eye at all right now? The iPhone camera is always
    /// present; the glasses need a live session or a ready device (the
    /// camera opens the session through GlassesLink).
    var hasVisionSource: Bool {
        visionRoute == .phone || isGlassesConnected || glassesAvailable
    }

    /// Permission for whichever eye is active. These are two different
    /// grants from two different places - the glasses camera is authorised
    /// through the Meta AI companion app, the iPhone camera through iOS - so
    /// asking the glasses authority about a phone-mode capture always said
    /// no. That is why "remember this person" saved a note with no photo.
    func ensureVisionPermission(interactive: Bool) async -> Bool {
        switch visionRoute {
        case .glasses:
            return await ensureCameraPermission(interactive: interactive)
        case .phone:
            return interactive
                ? await PhoneCameraManager.ensurePermission()
                : PhoneCameraManager.isAuthorized
        }
    }

    /// A still from the active eye, falling back to the other one rather
    /// than returning nothing. "remember this person" saved a note with no
    /// photo because a transient route flip sent the capture to a camera
    /// that wasn't running; a photo from the wrong-but-working camera beats
    /// no photo at all.
    func captureVisionPhoto() async throws -> Data {
        do {
            return try await vision.capturePhoto()
        } catch {
            NSLog("[Hermes] \(visionRoute) capture failed: \(error.localizedDescription)")
            guard VisionRouting.mayFallBackToPhone(preference: phoneModePreference)
            else { throw error }
            switch visionRoute {
            case .glasses:
                NSLog("[Hermes] falling back to the iPhone camera for this photo")
                do {
                    return try await phoneCameraManager.capturePhoto()
                } catch {
                    NSLog("[Hermes] iPhone fallback photo ALSO failed - \(error.localizedDescription)")
                    throw error
                }
            case .phone:
                // The phone was the route and it failed; the glasses can only
                // help if a session is actually up.
                guard glassesLink.isSessionStarted else { throw error }
                return try await glassesVision.capturePhoto()
            }
        }
    }

    /// Commit to an eye and hold it until `unpinVisionRoute()`.
    func pinVisionRoute(_ route: VisionRoute) { pinnedVisionRoute = route }

    func unpinVisionRoute() { pinnedVisionRoute = nil }

    /// A Meta device the SDK can open a session on right now: GlassesLink
    /// reports it registered, link connected and compatible.
    var glassesAvailable: Bool { glassesLink.deviceReady }

    /// Everything the SDK will tell us about eligibility, in one line, so a
    /// device log shows WHY a route was chosen. Diagnostic only.
    var visionDiagnostics: String {
        let links = wearables.devices.map { id -> String in
            guard let device = wearables.deviceForIdentifier(id) else { return "?" }
            return "\(device.nameOrId())=\(device.linkState)"
        }.joined(separator: ",")
        return """
        VISIONDIAG registration=\(wearables.registrationState) \
        devices=\(wearables.devices.count) [\(links)] \
        glassesAvailable=\(glassesAvailable) route=\(visionRoute) \
        pref=\(phoneModePreference.rawValue) phoneModeActive=\(phoneModeActive) \
        sessionVision=\(sessionUsesVision) phoneStream=\(phoneCameraManager.isStreaming) \
        linkSession=\(glassesLink.sessionStateText) linkDisplay=\(glassesLink.displayStateText) \
        connection=\(connectionState) mic=\(micSource.rawValue) \
        display=\(displayStatus) hudEnabled=\(displayHUDEnabled) \
        glassesStream=\(glassesLink.streamStateText)
        """
    }

    func logVisionDiagnostics(_ context: String) {
        NSLog("[Hermes] \(context) \(visionDiagnostics)")
    }

    /// True while a phone-mode session is running - drives the 5b screen.
    var phoneModeActive: Bool = false
    /// False for the showcase's session (`startSessionWithoutVision`): no
    /// camera is opened or resumed while it runs.
    private(set) var sessionUsesVision = true

    /// Set when the phone camera could not start (permission, hardware).
    /// The session still runs; only visual queries are affected.
    var phoneCameraError: String?

    /// Latest phone-camera frame, for the 5b feed.
    var phoneFeedImage: UIImage?

    /// Extra consumers of the running phone-mode stream, keyed so the Lens
    /// screen and conversation capture can both watch without clobbering
    /// each other. iOS gives one AVCaptureSession per camera, so a second
    /// consumer must share rather than start its own.
    @ObservationIgnored private var visionFrameObservers:
        [String: (VisionFrame) -> Void] = [:]

    func addVisionFrameObserver(
        _ key: String, _ handler: @escaping (VisionFrame) -> Void
    ) {
        visionFrameObservers[key] = handler
    }

    func removeVisionFrameObserver(_ key: String) {
        visionFrameObservers.removeValue(forKey: key)
    }

    /// True when a shared stream is already running, so a would-be consumer
    /// should observe it instead of calling `startLiveStream`.
    var visionStreamIsShared: Bool {
        visionRoute == .phone && phoneModeActive
    }

    /// Mirrors `displayManager.content` so SwiftUI can render the simulated
    /// lens. Updated even with no glasses attached.
    var lensContent: LensContent = .blank

    /// Auto / Always / Off (design 5a). Auto is the fallback the session
    /// screen relies on.
    var phoneModePreference: PhoneModePreference = PhoneModePreference(
        rawValue: UserDefaults.standard.string(forKey: PhoneModePreference.storageKey) ?? ""
    ) ?? .auto {
        didSet {
            UserDefaults.standard.set(
                phoneModePreference.rawValue, forKey: PhoneModePreference.storageKey
            )
        }
    }


    init(wearables: WearablesInterface, glassesLink: GlassesLink) {
        self.wearables = wearables
        self.glassesLink = glassesLink
        self.displayManager = HermesDisplayManager(link: glassesLink)
        self.glassesVision = GlassesLinkVision(link: glassesLink)
        reloadDirectProviderState()
        // Wired at init, NOT at session start: lens callbacks must exist
        // before any session does (see CLAUDE.md, display callbacks).
        wireDisplay()
        wireSpeechFinished()
        speechSynthesizer.onCloudOutcome = { [weak self] success in
            Task { @MainActor [weak self] in self?.cloudVoiceFellBack = !success }
        }
        applyLanguage()
        // Update notices and session errors from the shared glasses session.
        glassesLink.observeSessionErrors("session") { [weak self] error in
            self?.handleSessionError(error)
        }
        // Teardown of the glasses session drops the speech capability
        // silently: hear through the iPhone again.
        glassesLink.observeSession("glassesSpeech") { [weak self] state in
            guard let self, self.glassesSpeechRunning, state != .started else { return }
            self.fallBackFromGlassesSpeech("session \(state.map { $0.description } ?? "none")")
        }
    }

    // MARK: - Public API

    /// Resolve the EmoDrink language setting into a recognizer locale and a
    /// voice. Falls back to English, with a notice, when Japanese speech
    /// recognition is unavailable; falls back to an English voice when no
    /// ja-JP voice is installed. Runs only while the recognizer is stopped:
    /// at init, at session start (state `.connecting`, before
    /// `speechRecognizer.start()`), and from Settings with no session. A
    /// change made mid-session applies from the next session. The
    /// recognizer always ends up in the voice's language, so the session
    /// never hears one language and speaks another. Only the session-start
    /// call (`announceFallback`) shows the STT fallback notice.
    @discardableResult
    func applyLanguage(announceFallback: Bool = false) -> Language {
        guard connectionState == .disconnected || connectionState == .connecting else { return activeLanguage }
        var language = EmoDrinkLanguage.resolved
        if !speechRecognizer.setLocale(language.sttLocale) {
            if language == .ja && announceFallback { startNotice(EmoDrinkLanguage.sttFallbackNotice) }
            language = .en
            speechRecognizer.setLocale(Language.en.sttLocale)
        }
        let voice = speechSynthesizer.configure(for: language)
        if voice.language != language {
            // A ja recognizer but no ja voice: hear what we speak.
            speechRecognizer.setLocale(voice.language.sttLocale)
        }
        activeLanguage = voice.language
        voiceNeedsInstallHint = voice.needsHint
        voiceName = voice.voiceName
        applyCloudVoice()
        return activeLanguage
    }

    /// Point the synthesizer at Gemini when a key and model were bundled and
    /// the setting is on; otherwise on-device only. The cloud voice follows
    /// the on-device voice's language. Safe mid-session: it applies from the
    /// next line.
    func applyCloudVoice() {
        if cloudVoiceEnabled, let key = BundledAIKey.ttsKey, let model = BundledAIKey.ttsModel {
            if speechSynthesizer.cloudVoiceName == nil { speechSynthesizer.configureCloud(CloudSpeech(key: key, model: model)) }
        } else {
            speechSynthesizer.configureCloud(nil)
        }
        cloudVoiceName = speechSynthesizer.cloudVoiceName
        cloudVoiceFellBack = cloudVoiceName != nil && !speechSynthesizer.cloudVoiceActive
    }

    func startSession() async {
        await startSession(engagingBrain: true)
    }

    /// The showcase's session: voice and the lens, never a camera. No
    /// iPhone capture session, no glasses camera check, no "using this
    /// iPhone as the eye" notice, and the phone stream is not resumed in
    /// front (`resumePhoneVisionIfNeeded`). No device context either: its
    /// location request would put a prompt over the run, and the
    /// showcase's AI calls never read it. The glasses DISPLAY still
    /// attaches when glasses are reachable; otherwise the run plays on the
    /// simulated lens. Problems that would raise the error or notice alert
    /// go to `reportIssue` instead (Taka's run notice).
    func startSessionWithoutVision(reportIssue: @escaping (String) -> Void) async {
        startIssueSink = reportIssue
        defer { startIssueSink = nil }
        await startSession(engagingBrain: true, vision: false)
    }

    /// The showcase's mic switch: like `setMicSource(_:announceFallback: false)`,
    /// but a failure goes to `reportIssue` (the run notice), not an alert.
    func setMicSourceQuietly(_ target: MicSource, reportIssue: @escaping (String) -> Void) async -> Bool {
        startIssueSink = reportIssue
        defer { startIssueSink = nil }
        return await setMicSource(target, announceFallback: false)
    }

    /// While a showcase start runs, its problems go here instead of an alert.
    private var startIssueSink: ((String) -> Void)?

    /// The error alert, or the showcase's run notice during its start.
    private func startError(_ message: String) {
        if let sink = startIssueSink { sink(message) } else { show(message) }
    }

    /// The notice alert, or the showcase's run notice during its start.
    private func startNotice(_ message: String, action: NoticeAction? = nil) {
        if let sink = startIssueSink { sink(message) } else { show(notice: message, action: action) }
    }

    private func startSession(engagingBrain: Bool, vision: Bool = true) async {
        // A Stop (endSession) while any await below is pending bumps the
        // generation; every resume checks it and leaves the session down.
        let gen = sessionGeneration
        connectionState = .connecting
        sessionUsesVision = vision

        logVisionDiagnostics(vision ? "startSession" : "startSession (no vision)")
        // Resolved now, after any launch wait for the SDK to discover the
        // glasses, and pinned below for the whole session.
        var route = visionRoute

        if route == .glasses {
            glassesConnectIssue = nil
            let connected = await connectGlassesSession(checkCamera: vision)
            guard gen == sessionGeneration else {
                // Stopped while connecting: no phone fallback, no notice.
                // GlassesLink keeps its session for the next start.
                return
            }
            if !connected {
                // Eligibility can lapse between the check and the start, and the
                // SDK is the only one who knows. Rather than leaving the user at
                // "No eligible device available" with no way forward, drop to the
                // phone - unless they explicitly turned that off.
                let issue = glassesConnectIssue
                glassesConnectIssue = nil
                NSLog("[EmoDrink] glasses connect failed: \(issue?.message ?? "no reason from the SDK")")
                if !vision {
                    // No camera to fall back to: the run plays on the
                    // simulated lens, whatever the phone-mode preference.
                    if let issue { startNotice(issue.message, action: issue.action) }
                } else if !VisionRouting.mayFallBackToPhone(preference: phoneModePreference) {
                    if let issue { show(notice: issue.message, action: issue.action) }
                    connectionState = .disconnected
                    return
                } else if let issue {
                    show(notice: "\(issue.message) Using this iPhone as the eye for now.", action: issue.action)
                } else {
                    show(notice: "Glasses unreachable - using this iPhone as the eye.")
                }
                route = .phone
            }
        }

        pinVisionRoute(route)
        phoneModeActive = route == .phone

        if route == .phone && vision {
            // No DeviceSession, no display attach - the phone is the eye and
            // the lens is simulated on screen (design 5b).
            await startPhoneVision()
            guard gen == sessionGeneration else {
                // Stopped while the camera opened: endSession already ran,
                // so close the stream it could not see yet.
                if connectionState == .disconnected { phoneCameraManager.stopLiveStream() }
                return
            }
        }

        // Personal context (time/location/motion/battery/weather) -
        // requests location permission on first use. Not for the showcase.
        if vision { contextProvider.start() }

        // 2. Check the brain: the provider needs a key. A recording-only
        // session skips this: nothing it captures is ever sent anywhere.
        if engagingBrain {
            guard !directProvider.requiresKey || DirectClient.hasKey(for: directProvider.id) else {
                startError("No API key set for \(directProvider.displayName). Add one in Settings.")
                endSession()
                startFailedGeneration = sessionGeneration
                return
            }
        }

        applyLanguage(announceFallback: true)
        let speechOK = await speechRecognizer.requestAuthorization()
        guard gen == sessionGeneration else { return }
        speechAuthorized = speechOK
        if !speechOK {
            startError(HermesSpeechError.notAuthorized.localizedDescription)
        }

        audioManager.onRawBuffer = { [weak self] buffer in
            self?.speechRecognizer.append(buffer)
        }
        audioManager.onLevel = { [weak self] level in
            self?.micLevel = level
        }
        audioManager.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                // Grace period: let the speaker's tail fade before the mic
                // listens again, or the recognizer hears the end of the TTS
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
                self.setListeningSuspended(false)
            }
        }

        speechRecognizer.onPartial = { [weak self] text in
            self?.heardPartial(text)
        }
        speechRecognizer.onFinal = { [weak self] text in
            self?.submitQuery(text)
        }

        audioManager.onRouteChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.speechRecognizer.restartCycle()
            }
        }

        do {
            let bluetoothActive = try await audioManager.startCapture(route: micSource.captureRoute)
            guard gen == sessionGeneration else {
                // Stopped while the mic opened: close what just started.
                if connectionState == .disconnected { audioManager.stopCapture() }
                return
            }
            if micSource == .glasses && !bluetoothActive { startNotice(Self.glassesMicFallbackNotice) }
            if micSource == .headset && !bluetoothActive { startNotice(Self.headsetMicFallbackNotice) }
            if micSource == .glassesSpeech {
                // The glasses transcribe; the recognizer stays stopped.
                // Start the recognizer once, below, on any failure.
                let heard = await beginGlassesSpeech(sessionGen: gen, startRecognizerOnFallback: false)
                guard gen == sessionGeneration else { return }
                if !heard {
                    // A failed capability start has already fallen back.
                    if micSource == .glassesSpeech {
                        fallBackFromGlassesSpeech("could not start", startRecognizer: false)
                    }
                    if speechOK { try speechRecognizer.start() }
                }
            } else if speechOK {
                try speechRecognizer.start()
            }
        } catch {
            guard gen == sessionGeneration else { return }
            startError("Audio setup failed: \(error.localizedDescription)")
            endSession()
            startFailedGeneration = sessionGeneration
            return
        }

        // Put the HUD on the lens (through GlassesLink) only when the mic
        // route leaves the lens free - the GLASSES' hands-free link brings
        // up their call screen (a headset's hands-free link does not). In
        // phone mode nothing goes to the glasses; the simulated lens reads
        // `displayManager.content` instead, which updates either way.
        if route == .glasses, displayHUDEnabled, !lensBlockedByCallScreen {
            displayManager.activate()
        }

        // Mic live, recognizer running
        connectionState = .listening
    }

    /// A partial transcript from whichever source hears (the recognizer or
    /// the glasses' speech): the live transcript on the phone, the
    /// listening screen on the lens, barge-in while Hermes speaks.
    private func heardPartial(_ text: String) {
        if case .speaking = connectionState {
            // Words while Hermes talks = barge-in, unless the glasses
            // are hearing Hermes's own voice
            guard !isEchoOfResponse(text) else { return }
            liveTranscript = text
            // A showcase run owns the lens: no listening screen over the deck.
            if showcaseClaimer == nil { displayManager.showListening(partial: text) }
            if text.split(separator: " ").count >= 2 {
                interruptSpeech()
            }
        } else {
            liveTranscript = text
            // A late partial can trail the finalized utterance - don't
            // let it overwrite the Thinking screen on the lens
            switch connectionState {
            case .listening, .recording:
                // A showcase run owns the lens: no listening screen over the deck.
                if showcaseClaimer == nil { displayManager.showListening(partial: text) }
            default:
                break
            }
        }
    }

    /// Send finalized text to the active brain and move the UI into processing
    func submitQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // A showcase run claims every utterance: the deck follows the
        // conversation through its own one-shot AI calls.
        if let claim = showcaseClaimer, claim(trimmed) {
            liveTranscript = ""
            lastTranscript = trimmed
            completeTestOutcome(.failure(TestFailure(
                "The showcase claimed this utterance - reset the showcase before running this test."
            )))
            return
        }

        // While a drink is on the lens its replies (why, a choice, thanks)
        // are claimed first and never reach the assistant.
        if let claim = emoDrinkClaimer, claim(trimmed) {
            liveTranscript = ""
            lastTranscript = trimmed
            completeTestOutcome(.failure(TestFailure(
                "EmoDrink claimed this utterance as a reply - say thanks to end the drink moment before running this test."
            )))
            return
        }

        let intent = IntentDetector.detect(trimmed)
        if intent != .none {
            liveTranscript = ""
            lastTranscript = trimmed
            onEmoDrinkIntent?(intent)
            return
        }

        let context = contextProvider.contextLine()
        liveTranscript = ""
        lastTranscript = trimmed
        connectionState = .processing
        displayManager.showThinking(query: trimmed)
        setListeningSuspended(true)
        Task { await askDirect(trimmed, context: context) }
    }

    /// Direct mode: photo decision + capture happen locally, then one
    /// API call - no server round trips.
    private func askDirect(_ text: String, context: String? = nil) async {
        var photo: Data?
        // A visual query always gets a FRESH photo: the model's history is
        // text-only, so the memory window that skipped a re-shoot left the
        // model blind ("I can't see a photo") for any deictic question asked
        // within two minutes of the last one. The window now only decides
        // whether a failed capture may fall back to the previous photo.
        if VisualQueryDetector.shouldCapturePhoto(text, lastPhotoAt: nil),
           hasVisionSource,
           await ensureVisionPermission(interactive: false) {
            displayManager.showPhotoCaptured()
            photo = try? await captureVisionPhoto()
            if photo != nil {
                lastDirectPhotoAt = Date()
                lastDirectPhoto = photo
                pendingPhoto = photo
            } else if let recent = lastDirectPhoto, let at = lastDirectPhotoAt,
                      Date().timeIntervalSince(at) <= VisualQueryDetector.photoMemoryWindow {
                photo = recent
            }
        }

        do {
            let reply = try await directClient.ask(text, photoJPEG: photo, contextLine: context)
            lastResponse = reply
            addTurn(userText: text, agentText: reply)
            completeTestOutcome(.success(()))
            presentReply(reply)
        } catch {
            show(error.localizedDescription)
            connectionState = .listening
            setListeningSuspended(false)
            displayManager.clear()
        }
    }

    /// Store/replace the API key for the current provider (Keychain)
    func setProviderKey(_ key: String) {
        let stored = DirectClient.storeKey(key, for: directProviderID)
        // hasKey re-reads the Keychain, so the badge reflects what is
        // actually there - but a silent failure needs saying out loud.
        hasDirectKey = DirectClient.hasKey(for: directProviderID)
        if !stored, !hasDirectKey {
            show("Could not save the API key to the Keychain.")
        }
    }

    /// Answer a multiple-choice reply by picking one of its options. Sent
    /// as the option's words, so the transcript reads like a conversation
    /// rather than a row of letters.
    func chooseReplyOption(_ choice: ReplyChoice) {
        interruptSpeech()
        submitQuery(choice.reply)
    }

    /// The options offered by the most recent reply, if any - drives the
    /// chips under the last bubble.
    var replyChoices: [ReplyChoice] {
        lensContent.choices
    }

    /// Forget the conversation: clears the on-device history immediately.
    func startNewConversation() {
        DirectClient.clearHistory()
        conversationHistory.removeAll()
        lastTranscript = ""
        lastResponse = ""
        liveTranscript = ""
        displayManager.showNewConversationFlash()
    }

    /// Cut Hermes off mid-reply (tap on the speaking indicator, or voice
    /// barge-in in glasses mode). stopPlayback fires onPlaybackComplete,
    /// which returns the state machine to listening.
    func interruptSpeech() {
        guard case .speaking = connectionState else { return }
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stop()
        } else {
            audioManager.stopPlayback()
        }
    }

    /// Silent mode is only honored while the lens can actually show text.
    private var displaySilentActive: Bool {
        displaySilentMode && displayStatus == .connected
    }

    /// Single reply path for both brains: lens card + (unless silent) TTS.
    private func presentReply(_ text: String) {
        let shown = HermesDisplayLogic.truncateReply(text)
        if displaySilentActive {
            displayManager.showReply(text: shown, speaking: false,
                                     dwellSeconds: HermesDisplayLogic.readingDwellSeconds(charCount: shown.count))
            connectionState = .listening
            setListeningSuspended(false)
        } else {
            connectionState = .speaking
            displayManager.showReply(text: shown, speaking: true, dwellSeconds: nil)
            speechSynthesizer.speak(text)
            // Bluetooth mic: the speaker is not the mic, so keep listening.
            if audioManager.isUsingBluetoothInput { setListeningSuspended(false) }
        }
    }

    /// Step 1 for the phone route: start the iPhone camera stream that both
    /// the 5b feed and every visual query read from. A failure here is not
    /// fatal - the voice loop is the valuable half.
    private func startPhoneVision() async {
        phoneCameraError = nil
        // One AVCaptureSession, possibly two consumers: the 5b feed always,
        // plus the Lens screen while it is open (see onVisionFrame). Starting
        // a second capture session for Lens would fail - the camera is taken.
        do {
            try await phoneCameraManager.startLiveStream(
                onFrame: { [weak self] frame in
                    Task { @MainActor [weak self] in
                        guard let self, self.phoneModeActive else { return }
                        if let image = frame.image { self.phoneFeedImage = image }
                        for observe in self.visionFrameObservers.values {
                            observe(frame)
                        }
                    }
                },
                onError: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.phoneCameraError = message
                    }
                }
            )
        } catch {
            phoneCameraError = error.localizedDescription
        }
    }

    /// Into the background in phone mode: iOS interrupts the iPhone camera
    /// anyway, so stop the stream outright (`isStreaming` goes false) and
    /// let `resumePhoneVisionIfNeeded()` start it again in front.
    func pausePhoneVisionForBackground() {
        guard phoneModeActive, phoneCameraManager.isStreaming else { return }
        phoneCameraManager.stopLiveStream()
    }

    /// Back from the background in phone mode: the iPhone camera stream
    /// stopped while the app was hidden, so start it again.
    func resumePhoneVisionIfNeeded() async {
        // A showcase session never opens a camera, so it never resumes one.
        guard sessionUsesVision, phoneModeActive, !phoneCameraManager.isStreaming else { return }
        await startPhoneVision()
    }

    /// Display-HUD callbacks. Wired for BOTH routes: in phone
    /// mode nothing goes out over BLE, but `displayManager.content` still
    /// updates, which is what the simulated lens renders.
    private func wireDisplay() {
        displayManager.onContentChanged = { [weak self] content in self?.lensContent = content }
        lensContent = displayManager.content
        displayManager.onDebug = { message in NSLog("[EmoDrink] display: \(message)") }
        displayManager.onStatusChanged = { [weak self] newStatus in self?.displayStatus = newStatus }
        // A card sent while the lens was off was dropped; the display
        // manager draws the current EmoDrink card the moment it attaches.
        displayManager.attachRedraw = { [weak self] in self?.emoDrinkLensIdle?() ?? false }
        displayManager.onStop = { [weak self] in self?.interruptSpeech() }
        displayManager.onRepeat = { [weak self] in self?.repeatLastReply() }
        displayManager.onNewChat = { [weak self] in
            guard let self else { return }
            self.startNewConversation()
            self.displayManager.showNewConversationFlash()
        }
        displayManager.onChooseReplyOption = { [weak self] choice in self?.chooseReplyOption(choice) }
        // After a reply's dwell, EmoDrink restores its card or the watching
        // screen; otherwise the lens blanks.
        displayManager.idleHandler = { [weak self] in
            guard let self else { return }
            if self.emoDrinkLensIdle?() != true { self.displayManager.clear() }
        }
    }

    /// On-lens Repeat button: re-speak (or re-show, in silent mode).
    func repeatLastReply() {
        guard !lastResponse.isEmpty else { return }
        if case .speaking = connectionState { return }
        presentReply(lastResponse)
    }

    /// True when a partial heard during .speaking is (part of) Hermes's own
    /// spoken words leaking into the mic, rather than the user talking.
    private func isEchoOfResponse(_ partial: String) -> Bool {
        func normalize(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                .trimmingCharacters(in: .whitespaces)
        }
        let heard = normalize(partial)
        guard !heard.isEmpty else { return true }
        // Heuristic: if what we heard appears verbatim in the response,
        // assume it's echo. A user genuinely quoting Hermes back loses -
        // acceptable trade-off.
        return normalize(lastResponse).contains(heard)
    }

    /// The glasses' hands-free mic makes the glasses show their call screen,
    /// which covers the lens.
    var lensBlockedByCallScreen: Bool {
        micSource == .glasses && audioManager.isUsingBluetoothInput
    }

    /// The lens status in one line, the same five states everywhere: on,
    /// attaching, off, unavailable (with the reason), hidden by the
    /// glasses mic. The home badge passes the active language; Settings
    /// passes English.
    func lensStatusText(_ t: EmoDrinkStrings) -> String {
        if lensBlockedByCallScreen { return t.lensBlockedByMic }
        switch displayStatus {
        case .connected: return t.lensOn
        case .connecting: return t.lensAttaching
        case .off: return t.lensOff
        case .unavailable(let reason): return t.lensUnavailable(reason)
        }
    }

    /// Glasses speech is offered (Settings picker, tap-to-switch) only while
    /// its Developer setting is on.
    var availableMicSources: [MicSource] {
        MicSource.allCases.filter { $0 != .glassesSpeech || glassesSpeechEnabled }
    }

    /// Next source that actually takes; HFP ports only appear once the
    /// session is active, so the cycle tries each in turn.
    func toggleMicSource() async {
        let all = availableMicSources
        let start = all.firstIndex(of: micSource) ?? 0
        for step in 1...all.count {
            switch await switchMicSource(all[(start + step) % all.count], announceFallback: false) {
            case .took, .sessionEnded: return
            case .routeUnavailable: continue
            }
        }
    }

    private enum MicSwitchOutcome { case took, routeUnavailable, sessionEnded }

    @discardableResult
    func setMicSource(_ target: MicSource, announceFallback: Bool = true) async -> Bool {
        await switchMicSource(target, announceFallback: announceFallback) == .took
    }

    private func switchMicSource(_ target: MicSource, announceFallback: Bool) async -> MicSwitchOutcome {
        if target == .glassesSpeech, !glassesSpeechEnabled { return .routeUnavailable }
        micSource = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.micSourceKey)
        guard connectionState != .disconnected else { return .took }
        // Leaving glasses speech: the recognizer takes over once the mic opens.
        let leftGlassesSpeech = glassesSpeechInUse && target != .glassesSpeech
        if leftGlassesSpeech {
            glassesSpeechInUse = false
            pauseGlassesSpeech()
        }
        audioManager.stopCapture()
        do {
            let bluetoothActive = try await audioManager.startCapture(route: target.captureRoute)
            if target == .glassesSpeech {
                return await switchToGlassesSpeech(announceFallback: announceFallback)
            }
            if leftGlassesSpeech, speechAuthorized { try? speechRecognizer.start() }
            let outcome: MicSwitchOutcome = (bluetoothActive || target == .phone) ? .took : .routeUnavailable
            speechRecognizer.restartCycle()
            if announceFallback, target == .glasses, !bluetoothActive { show(notice: Self.glassesMicFallbackNotice) }
            if announceFallback, target == .headset, !bluetoothActive { show(notice: Self.headsetMicFallbackNotice) }
            if outcome == .routeUnavailable {
                micSource = .phone
                UserDefaults.standard.set(MicSource.phone.rawValue, forKey: Self.micSourceKey)
            }
            reconcileLensHUD()
            return outcome
        } catch {
            startError("Mic switch failed: \(error.localizedDescription)")
            endSession()
            return .sessionEnded
        }
    }

    /// The mic (iPhone route) is open again: hand transcription to the
    /// glasses, or fall back to the iPhone mic when they cannot take it.
    private func switchToGlassesSpeech(announceFallback: Bool) async -> MicSwitchOutcome {
        let gen = sessionGeneration
        if !glassesSpeechInUse {
            speechRecognizer.stop()
            let heard = await beginGlassesSpeech(sessionGen: gen)
            guard gen == sessionGeneration else { return .sessionEnded }
            if !heard {
                // A failed capability start has already fallen back.
                if micSource == .glassesSpeech {
                    fallBackFromGlassesSpeech("could not start", announce: announceFallback)
                } else if !glassesSpeechInUse, speechAuthorized {
                    // Another mic was picked during the wait: the
                    // recognizer stopped above must hear again.
                    try? speechRecognizer.start()
                }
                reconcileLensHUD()
                return .routeUnavailable
            }
        }
        reconcileLensHUD()
        return .took
    }

    // MARK: Glasses speech (MicSource.glassesSpeech)

    /// Suspend or resume listening, whichever source hears: the recognizer
    /// always follows (it stays stopped while the glasses hear, but keeps
    /// the flag for a fall back); the glasses' capability is stopped while
    /// suspended and started again on resume.
    private func setListeningSuspended(_ suspended: Bool) {
        speechRecognizer.isSuspended = suspended
        guard glassesSpeechInUse else { return }
        if suspended { pauseGlassesSpeech() } else if !glassesSpeechRunning { resumeGlassesSpeech() }
    }

    /// Hear through the glasses for this session. False when they cannot:
    /// setting off, a locale known not to match the session's language, no
    /// glasses session, or the capability refused. Starts listening at once
    /// unless listening is suspended (resume starts it).
    private func beginGlassesSpeech(sessionGen: Int, startRecognizerOnFallback: Bool = true) async -> Bool {
        guard glassesSpeechEnabled else { return false }
        guard GlassesSpeechRouting.locale(glassesLink.glassesSpeechLocale, matches: activeLanguage) != false else {
            NSLog("[EmoDrink] glasses speech locale \(glassesLink.glassesSpeechLocale ?? "-") does not hear \(activeLanguage.rawValue)")
            return false
        }
        guard await glassesLink.ensureSession(timeout: 8), sessionGen == sessionGeneration else { return false }
        // The setting or the mic may have changed during the wait.
        guard glassesSpeechEnabled, micSource == .glassesSpeech else { return false }
        glassesSpeechInUse = true
        if speechRecognizer.isSuspended { return true }
        return resumeGlassesSpeech(startRecognizerOnFallback: startRecognizerOnFallback)
    }

    /// Start (again) the glasses' capability. A failure falls back to the
    /// iPhone mic.
    @discardableResult
    private func resumeGlassesSpeech(startRecognizerOnFallback: Bool = true) -> Bool {
        guard glassesSpeechInUse else { return false }
        glassesSpeechGeneration += 1
        let gen = glassesSpeechGeneration
        let started = glassesLink.startGlassesSpeech(
            onText: { [weak self] text, isFinal in self?.glassesSpeechHeard(text, isFinal: isFinal, gen) },
            onError: { [weak self] error in self?.glassesSpeechFailed(error, gen) },
            onLocale: { [weak self] _ in self?.checkGlassesSpeechLocale(gen) }
        )
        guard started else {
            fallBackFromGlassesSpeech("capability did not start", startRecognizer: startRecognizerOnFallback)
            return false
        }
        glassesSpeechRunning = true
        checkGlassesSpeechLocale(gen, startRecognizerOnFallback: startRecognizerOnFallback)
        return glassesSpeechRunning
    }

    /// Stop the glasses' capability (suspension, a switch, the session's
    /// end). Callbacks still in flight see a newer generation.
    private func pauseGlassesSpeech() {
        glassesSpeechGeneration += 1
        guard glassesSpeechRunning else { return }
        glassesSpeechRunning = false
        glassesLink.stopGlassesSpeech()
    }

    private func glassesSpeechHeard(_ text: String, isFinal: Bool, _ gen: Int) {
        guard gen == glassesSpeechGeneration, glassesSpeechRunning else { return }
        if isFinal { submitQuery(text) } else { heardPartial(text) }
    }

    private func glassesSpeechFailed(_ error: SpeechError, _ gen: Int) {
        guard gen == glassesSpeechGeneration, glassesSpeechInUse else { return }
        // A second start on a capability already listening is harmless.
        if error == .alreadyListening { return }
        fallBackFromGlassesSpeech("error \(error)")
    }

    /// The glasses hear another language than the session speaks: useless,
    /// so the iPhone mic takes over.
    private func checkGlassesSpeechLocale(_ gen: Int, startRecognizerOnFallback: Bool = true) {
        guard gen == glassesSpeechGeneration, glassesSpeechInUse,
              GlassesSpeechRouting.locale(glassesLink.glassesSpeechLocale, matches: activeLanguage) == false
        else { return }
        fallBackFromGlassesSpeech("locale \(glassesLink.glassesSpeechLocale ?? "-") is not \(activeLanguage.rawValue)",
                                  startRecognizer: startRecognizerOnFallback)
    }

    /// Back to the iPhone mic, as the other mic fallbacks do: the saved
    /// source becomes `.phone` and (mid-session) the recognizer starts.
    private func fallBackFromGlassesSpeech(_ reason: String, announce: Bool = true, startRecognizer: Bool = true) {
        NSLog("[EmoDrink] glasses speech -> iPhone mic: \(reason)")
        glassesSpeechInUse = false
        pauseGlassesSpeech()
        micSource = .phone
        UserDefaults.standard.set(MicSource.phone.rawValue, forKey: Self.micSourceKey)
        if announce { startNotice(Self.glassesSpeechFallbackNotice) }
        if startRecognizer, speechAuthorized, connectionState != .disconnected {
            try? speechRecognizer.start()
        }
    }

    /// HUD ⇄ GLASSES hands-free mic are mutually exclusive: the glasses show
    /// their call screen while their hands-free link is active. Headset mode
    /// leaves the lens free.
    ///
    /// Runs on EVERY exit from a mic switch, and reads `micSource` AFTER any
    /// fallback - a failed switch away from the glasses mic leaves the iPhone
    /// mic live, and the HUD must come back with it. Skipping it once stranded
    /// the lens off with no recovery but toggling the HUD setting.
    private func reconcileLensHUD() {
        guard displayHUDEnabled, glassesSessionRunning else { return }
        if lensBlockedByCallScreen {
            displayManager.deactivate()
            startNotice("Lens HUD paused - the glasses show their call screen while their hands-free mic is on. The iPhone or a headset mic keeps the HUD visible.")
        } else if !displayManager.isActive {
            displayManager.activate()
        }
    }

    /// A session is running (or connecting) with the glasses as the eye.
    var glassesSessionRunning: Bool {
        connectionState != .disconnected && pinnedVisionRoute == .glasses
    }

    /// A short spoken confirmation. With the voice loop listening, the
    /// recognizer is suspended first (onFinished resumes it) so Hermes
    /// doesn't transcribe its own cue; mid-answer, the cue is skipped.
    func speakCue(_ text: String) {
        switch connectionState {
        case .listening:
            connectionState = .speaking
            setListeningSuspended(true)
            speechSynthesizer.speak(text)
        case .disconnected:
            speechSynthesizer.speak(text)
        default:
            break
        }
    }

    /// Build Check's form: while another cue is speaking the line waits its
    /// turn (FIFO, drained by onFinished) instead of being dropped - a run's
    /// warnings and step prompts must all be heard.
    func speakCue(_ text: String, queued: Bool) {
        if queued, case .speaking = connectionState {
            cueQueue.append(text)
            return
        }
        speakCue(text)
    }

    /// A spoken line the caller waits on (the showcase runner): returns
    /// when the line has been spoken, on `stopSpeaking()`, when the calling
    /// task is cancelled, or after a cap well past the line's length. A
    /// line already playing is replaced. Mid-answer (processing) the line
    /// is skipped, as `speakCue` does. Other callers' cueQueue is untouched.
    func speakCueAndWait(_ text: String) async {
        releaseSpeechWaiter()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !Task.isCancelled else { return }
        switch connectionState {
        case .listening:
            connectionState = .speaking
            setListeningSuspended(true)
        case .speaking, .disconnected:
            break
        default:
            return
        }
        if speechSynthesizer.isSpeakingOnDevice { speechFinishGate.expectStale() } else { speechFinishGate.reset() }
        speechSynthesizer.speak(trimmed)
        speechWaiterToken += 1
        let token = speechWaiterToken
        let cap = Self.speechWaitCapNanos(for: trimmed)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                speechWaiter = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: cap)
                    guard let self, self.speechWaiterToken == token else { return }
                    self.releaseSpeechWaiter()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.speechWaiterToken == token else { return }
                self.releaseSpeechWaiter()
            }
        }
    }

    /// Stops whatever is speaking (a reply, a cue, queued cues, a waited
    /// line); onFinished returns the voice loop to listening.
    func stopSpeaking() {
        cueQueue.removeAll()
        releaseSpeechWaiter()
        speechFinishGate.reset()
        if speechSynthesizer.isSpeaking { speechSynthesizer.stop() }
    }

    /// The cloud fetch (up to 10 s) plus a slow reading of the line.
    private static func speechWaitCapNanos(for text: String) -> UInt64 {
        UInt64(min(45, 12 + Double(text.count) * 0.15) * 1_000_000_000)
    }

    /// False when this finish belongs to a replaced line (ignore it whole);
    /// otherwise releases a waiting line and returns true.
    private func speechLineFinished() -> Bool {
        if speechFinishGate.isStale(stillSpeaking: speechSynthesizer.isSpeaking) { return false }
        releaseSpeechWaiter()
        return true
    }

    private func releaseSpeechWaiter() {
        speechWaiterToken += 1
        let waiter = speechWaiter
        speechWaiter = nil
        waiter?.resume()
    }

    /// On-device or cloud TTS finished (or was interrupted) - same
    /// completion flow as audio playback. Wired once at init, not at
    /// session start: a line spoken with no session (the showcase on the
    /// phone mirror, a cue while disconnected) must still release its
    /// waiter instead of running to its cap.
    private func wireSpeechFinished() {
        speechSynthesizer.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A replaced line's finish: the new line owns the state.
                guard self.speechLineFinished() else { return }
                // A queued cue speaks next with the recognizer still
                // suspended: state stays .speaking, no grace gap in between.
                if case .speaking = self.connectionState, !self.cueQueue.isEmpty {
                    self.speechSynthesizer.speak(self.cueQueue.removeFirst())
                    return
                }
                self.displayManager.replySpeakingFinished()
                if case .speaking = self.connectionState {
                    self.connectionState = .listening
                }
                try? await Task.sleep(nanoseconds: Self.speechResumeGraceNanos)
                // A cue that started during the grace owns the suspension.
                if case .speaking = self.connectionState { return }
                self.setListeningSuspended(false)
            }
        }
    }

    // MARK: Showcase surface

    func showShowcaseCard(_ image: UIImage, buttons: [ShowcaseButton], strings: ShowcaseStrings,
                          onTap: @escaping (ShowcaseButton) -> Void) {
        displayManager.showShowcaseCard(image, buttons: buttons, strings: strings, onTap: onTap)
    }

    @discardableResult
    func playShowcaseClip(_ fileURL: URL) async -> Bool {
        await displayManager.playShowcaseClip(fileURL)
    }

    // MARK: EmoDrink surface

    func setPersonaOverride(_ prompt: String?) {
        directClient.systemPromptOverride = prompt
    }

    func showEmoDrinkOnLens(title: String, subtitle: String, reason: String, source: String, choices: [ReplyChoice]) {
        displayManager.showEmoDrink(title: title, subtitle: subtitle, reason: reason, source: source, choices: choices)
    }

    func showEmoDrinkWatchingOnLens() {
        let t = EmoDrinkStrings(language: activeLanguage)
        displayManager.showEmoDrinkWatching(heading: t.watchingHeading, text: t.watchingText, hint: t.watchingHint)
    }

    func showEmoDrinkChoicesOnLens(heading: String, options: [LensDrinkOption], source: String) {
        displayManager.showEmoDrinkChoices(heading: heading, options: options, source: source)
    }

    func clearLens() {
        displayManager.clear()
    }

    func endSession() {
        sessionGeneration += 1
        let emoEnding = onEmoDrinkSessionEnding
        onEmoDrinkSessionEnding = nil
        emoEnding?()
        cueQueue.removeAll()
        releaseSpeechWaiter()
        speechFinishGate.reset()
        speechSynthesizer.stop()
        speechRecognizer.stop()
        glassesSpeechInUse = false
        pauseGlassesSpeech()
        displayManager.deactivate()
        displayStatus = .off
        contextProvider.stop()
        liveTranscript = ""
        micLevel = 0
        audioManager.stopCapture()
        glassesVision.stopLiveStream()
        phoneCameraManager.stopLiveStream()
        unpinVisionRoute()
        phoneModeActive = false
        phoneFeedImage = nil
        phoneCameraError = nil
        lensContent = .blank
        pendingPhoto = nil
        // GlassesLink keeps its session (and attached display) for the next
        // start and for the Glasses basics screen; Reset there ends it.
        connectionState = .disconnected
    }

    func dismissError() {
        showError = false
    }

    func dismissNotice() {
        showNotice = false
        noticeAction = nil
    }

    func performNoticeAction() {
        let action = noticeAction
        dismissNotice()
        action?.perform()
    }

    // MARK: - Private

    // Internal, not private: the +Glasses / +Developer extensions use it.
    func addTurn(userText: String, agentText: String) {
        let turn = ConversationTurn(
            userText: userText,
            agentText: agentText,
            timestamp: Date(),
            photo: pendingPhoto,
            photoSource: pendingPhoto == nil ? nil : vision.sourceLabel
        )
        pendingPhoto = nil
        conversationHistory.append(turn)
        if conversationHistory.count > 50 {
            conversationHistory.removeFirst()
        }
        lastTranscript = ""
    }

    // Internal, not private: the +Glasses / +Developer extensions use it.
    func show(_ message: String) {
        errorMessage = message
        showError = true
        // A test waiting on a round trip has just learnt its outcome: this
        // is the only path every brain's failures share.
        completeTestOutcome(.failure(TestFailure(message)))
    }

    /// The same surface for something that merely happened, phrased as news
    /// rather than as a fault.
    // Internal, not private: the +Glasses extension uses it.
    func show(notice message: String, action: NoticeAction? = nil) {
        noticeMessage = message
        noticeAction = action
        showNotice = true
    }
}
