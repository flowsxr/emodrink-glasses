//
// HermesDisplayManager.swift
//
// Renders the HUD screens (listening, thinking, replies, the EmoDrink
// cards) and sends them to the lens through GlassesLink, the proven
// display path: GlassesLink attaches the display on demand and holds a
// view until the display is `.started`. Strictly best-effort: every
// failure is logged and swallowed - the voice loop must never notice the
// display. `content` (the simulated lens) updates whether or not glasses
// are attached.
//

import AVFoundation
import Foundation
import MWDATDisplay
import os
import UIKit

enum DisplayHUDStatus: Equatable {
    case off                    // toggle disabled or no session
    case connecting
    case connected
    case unavailable(String)    // attach failed / update needed / dropped
}

@MainActor
final class HermesDisplayManager {
    private let logger = Logger(
        subsystem: "com.flowsxr.emodrink", category: "display"
    )

    private(set) var status: DisplayHUDStatus = .off {
        didSet {
            if status != oldValue { onStatusChanged?(status) }
        }
    }

    /// What the lens is showing, independent of whether any glasses are
    /// attached. Phone mode renders this in SwiftUI (SimulatedLensView),
    /// so it is assigned on EVERY screen call - including when `status` is
    /// `.off` and nothing goes out over BLE.
    private(set) var content: LensContent = .blank {
        didSet {
            if content != oldValue { onContentChanged?(content) }
        }
    }

    var onStatusChanged: ((DisplayHUDStatus) -> Void)?
    var onContentChanged: ((LensContent) -> Void)?
    var onDebug: ((String) -> Void)?
    /// On-lens button callbacks (invoked on the main actor)
    var onStop: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onNewChat: (() -> Void)?
    /// The wearer tapped one of the reply's options.
    var onChooseReplyOption: ((ReplyChoice) -> Void)?
    /// What to do when a reply dwell ends. Default (nil) blanks the lens;
    /// the session sets this so EmoDrink can restore its card.
    var idleHandler: (() -> Void)?
    /// Draws the current card when the display attaches (a card sent while
    /// the display was off was dropped). Returns true when it drew.
    var attachRedraw: (() -> Bool)?
    /// Set by the Developer display test around its own attach, so the
    /// redraw cannot land after (and over) the test card.
    var suppressAttachRedraw = false
    /// Every DisplayState the SDK reports, as text ("starting", "started",
    /// ...). Set by the Developer display test to trace the attach.
    var onStateTrace: ((String) -> Void)?
    /// The SDK's own `display.state` right now; nil when not attached.
    var sdkStateDescription: String? { link.displayState.map(GlassesLink.describe) }

    /// The one path to the lens.
    private let link: GlassesLink
    /// The HUD is wanted on the real lens (glasses session running, HUD
    /// on, lens not covered by the call screen). Off: nothing goes out.
    private(set) var isActive = false
    /// GlassesLink's display state at the last change, to spot `.started`.
    private var lastLinkState: DisplayState?

    /// One item for the serialized send pipeline: a view, or a showcase
    /// clip whose caller awaits the result.
    private enum QueuedSend {
        case view(FlexBox)
        case video(uri: String, completion: CheckedContinuation<Bool, Never>)
    }

    /// Newest item waiting for the send pipeline (see `enqueue`).
    private var queued: QueuedSend?
    /// A showcase clip went out and nothing has replaced it yet: the next
    /// view stops the video first.
    private var clipOnLens = false
    /// The last showcase card, redrawn when the display re-attaches.
    private var lastShowcaseCard: (image: UIImage, buttons: [ShowcaseButton], strings: ShowcaseStrings)?
    private var sendTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var throttle = DisplaySendThrottle()
    private var lastReplyText: String = ""
    /// The showcase card's button handler (see showShowcaseCard).
    private var onShowcaseTap: ((ShowcaseButton) -> Void)?
    /// Serves the playing clip in "http" transport; stopped when the clip
    /// ends or anything replaces it.
    private var clipServer: LocalClipServer?
    /// Bumped by every clip and every other screen, so a clip whose server
    /// start or send finishes late knows it was replaced.
    private var clipGeneration = 0

    /// Developer setting (Ruling 1): "file" (default) sends a clip as its
    /// file:// URI; "http" serves it from LocalClipServer on 127.0.0.1.
    nonisolated static let clipTransportKey = "showcase_clip_transport"

    init(link: GlassesLink) {
        self.link = link
        lastLinkState = link.displayState
        link.observeDisplay("hud") { [weak self] state in
            self?.linkDisplayChanged(state)
        }
    }

    // MARK: - Lifecycle

    /// Put the HUD on the real lens: attach the display through GlassesLink
    /// (session created if needed), or redraw at once when it is already up.
    func activate() {
        guard !isActive else { return }
        isActive = true
        NSLog("[EmoDrink] display activate (link display \(link.displayStateText))")
        recomputeStatus()
        if link.isDisplayReady {
            redrawAfterAttach()
        } else {
            link.ensureDisplay()
        }
    }

    /// Stop sending to the real lens and blank it. The display stays
    /// attached to GlassesLink's session for the next activate.
    func deactivate() {
        cancelDwell()
        stopClipServer()
        clipGeneration += 1
        dropQueued()
        lastReplyText = ""
        let wasActive = isActive
        isActive = false
        status = .off
        if wasActive, link.isDisplayReady {
            // After any send in flight, so the clear cannot land under it.
            // clipOnLens is read after it, since an in-flight clip sets it
            // only when its send returns.
            let inFlight = sendTask
            Task { [weak self, link] in
                await inFlight?.value
                if self?.clipOnLens == true { await link.stopVideo() }
                await link.clear()
                self?.clipOnLens = false
            }
        }
    }

    /// `.connected` mirrors GlassesLink's display state while active.
    private func recomputeStatus() {
        guard isActive else {
            status = .off
            return
        }
        switch link.displayState {
        case .started?:
            status = .connected
        case .starting?:
            status = .connecting
        case .stopping?, .stopped?:
            status = .unavailable(link.displayIssue ?? "Display stopped")
        case nil:
            status = link.displayIssue.map { .unavailable($0) } ?? .connecting
        }
    }

    private func linkDisplayChanged(_ state: DisplayState?) {
        let was = lastLinkState
        lastLinkState = state
        if state != was {
            NSLog("[EmoDrink] display state \(state.map(GlassesLink.describe) ?? "not attached")")
            onStateTrace?(state.map(GlassesLink.describe) ?? "not attached")
        } else if state == nil, let issue = link.displayIssue {
            onStateTrace?("not attached: \(issue)")
        }
        guard isActive else { return }
        recomputeStatus()
        if state == .started, was != .started {
            debug("Display attached")
            redrawAfterAttach()
        }
    }

    /// A card sent while the display was off was dropped: draw the current
    /// one now, unless a view is already on its way (it waited for this).
    private func redrawAfterAttach() {
        guard sendTask == nil, queued == nil, !suppressAttachRedraw else { return }
        // A showcase card is redrawn here; a clip is not replayed (the
        // runner moves on by its own clock).
        if case .showcase(let image?, nil) = content, let card = lastShowcaseCard, card.image === image {
            send(ShowcaseLens.card(card.image, buttons: card.buttons, strings: card.strings,
                                   onTap: { [weak self] button in
                                       Task { @MainActor in self?.onShowcaseTap?(button) }
                                   }))
            return
        }
        // A clip on the lens is never painted over by the idle screen.
        if case .showcase(nil, _?) = content { return }
        _ = attachRedraw?()
    }

    // MARK: - Screens

    func showListening(partial: String) {
        // Before the throttle: the simulated lens is local, so it can show
        // every partial even when BLE sends are being rate-limited.
        content = .listening(partial: partial)
        guard throttle.shouldSend() else { return }
        cancelDwell()
        send(HermesDisplayScreens.listening(partial: partial))
    }

    func showThinking(query: String) {
        content = .thinking(query: query)
        cancelDwell()
        send(HermesDisplayScreens.thinking(query: query))
    }

    func showPhotoCaptured() {
        content = .photoCaptured
        cancelDwell()
        send(HermesDisplayScreens.photoCaptured())
    }

    /// speaking=true keeps the card up (Stop button shown, no dwell);
    /// dwellSeconds non-nil blanks the lens after that many seconds.
    func showReply(text: String, speaking: Bool, dwellSeconds: Double?) {
        let choices = ChoiceDetector.choices(in: text)
        content = .reply(text: text, speaking: speaking, choices: choices)
        cancelDwell()
        lastReplyText = text
        send(HermesDisplayScreens.reply(
            text: text,
            speaking: speaking,
            choices: choices,
            onStop: { [weak self] in
                Task { @MainActor in self?.onStop?() }
            },
            onRepeat: { [weak self] in
                Task { @MainActor in self?.onRepeat?() }
            },
            onNewChat: { [weak self] in
                Task { @MainActor in self?.onNewChat?() }
            },
            onChoose: { [weak self] choice in
                Task { @MainActor in self?.onChooseReplyOption?(choice) }
            }
        ))
        // A reply with options must not blank itself out from under the
        // wearer while they are deciding.
        if let dwellSeconds, choices.isEmpty {
            scheduleDwell(seconds: dwellSeconds)
        }
    }

    /// TTS ended or was interrupted: re-render without Stop, start the
    /// spoken dwell, then blank (or let the idle handler restore a card).
    func replySpeakingFinished() {
        guard !lastReplyText.isEmpty else { return }
        showReply(text: lastReplyText, speaking: false, dwellSeconds: HermesDisplayLogic.spokenDwellSeconds)
    }

    /// EmoDrink pick. Buttons route through onChooseReplyOption like reply
    /// options do, so a tap submits the choice's words to the session.
    func showEmoDrink(title: String, subtitle: String, reason: String, source: String, choices: [ReplyChoice]) {
        content = .emoDrink(title: title, subtitle: subtitle, reason: reason, source: source, choices: choices)
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.emoDrink(
            title: title, subtitle: subtitle, reason: reason, source: source, choices: choices,
            onChoose: { [weak self] choice in
                Task { @MainActor in self?.onChooseReplyOption?(choice) }
            }))
    }

    func showEmoDrinkWatching(heading: String, text: String, hint: String) {
        content = .emoDrinkWatching(heading: heading, text: text, hint: hint)
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.emoDrinkWatching(heading: heading, text: text, hint: hint))
    }

    /// Step A. Buttons route through onChooseReplyOption like reply options,
    /// so a tap submits "2 Calpis Water" to the session, where the EmoDrink
    /// claimer hands it to DrinkChoiceParser. No dwell: the wearer is deciding.
    func showEmoDrinkChoices(heading: String, options: [LensDrinkOption], source: String) {
        let next = LensContent.emoDrinkChoices(heading: heading, options: options, source: source)
        content = next
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.emoDrinkChoices(
            heading: heading, status: next.statusLine ?? source, choices: next.choices,
            onChoose: { [weak self] choice in
                Task { @MainActor in self?.onChooseReplyOption?(choice) }
            }))
    }

    // MARK: - Showcase

    /// A rendered showcase card with native buttons, through the serialized
    /// send queue. A tap calls `onTap` on the main actor.
    func showShowcaseCard(_ image: UIImage, buttons: [ShowcaseButton], strings: ShowcaseStrings,
                          onTap: @escaping (ShowcaseButton) -> Void) {
        content = .showcase(image: image, clip: nil)
        cancelDwell()
        lastReplyText = ""
        onShowcaseTap = onTap
        lastShowcaseCard = (image, buttons, strings)
        send(ShowcaseLens.card(image, buttons: buttons, strings: strings, onTap: { [weak self] button in
            Task { @MainActor in self?.onShowcaseTap?(button) }
        }))
    }

    /// What became of a showcase clip on the real lens.
    enum ClipOutcome: Equatable {
        /// The lens took it.
        case played
        /// Something newer replaced it (a card, a clear, another clip).
        case superseded
        /// No real lens to play on (HUD off, glasses absent or not
        /// attached): the phone mirror plays it alone.
        case noLens
        /// The lens (glasses in reach) did not take it: nothing newer is
        /// on its way, so the caller should put something else up.
        case failed
    }

    /// Plays a rendered clip full screen through GlassesLink.sendVideo, as a
    /// file:// URI or over local HTTP (`clipTransportKey`). The phone mirror
    /// gets the clip first, glasses or not.
    @discardableResult
    func playShowcaseClip(_ fileURL: URL) async -> ClipOutcome {
        let next = LensContent.showcase(image: nil, clip: fileURL)
        if content == next { onContentChanged?(next) } else { content = next }
        cancelDwell()
        lastReplyText = ""
        onShowcaseTap = nil
        stopClipServer()
        clipGeneration += 1
        let generation = clipGeneration
        guard isActive else { return .noLens }

        var uri = fileURL.absoluteString
        if UserDefaults.standard.string(forKey: Self.clipTransportKey) == "http" {
            let server = LocalClipServer(fileURL: fileURL)
            do {
                let url = try await server.start()
                guard generation == clipGeneration else {
                    server.stop()
                    return .superseded
                }
                clipServer = server
                uri = url.absoluteString
            } catch {
                debug("Clip server failed (\(error)); sending the file URI")
            }
        }
        guard generation == clipGeneration else { return .superseded }
        guard isActive else { return .noLens }
        // Through the same serialized pipeline as the cards: one send in
        // flight, newest wins (a superseded clip hears false).
        let sent = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            enqueue(.video(uri: uri, completion: continuation))
        }
        if !sent { debug("Clip send failed or superseded (display \(link.displayStateText))") }
        if clipServer != nil, generation == clipGeneration {
            scheduleClipServerStop(for: fileURL, generation: generation)
        }
        guard generation == clipGeneration else { return .superseded }
        if sent { return .played }
        // Glasses in reach (or a lens up) that did not take it, versus no
        // glasses at all, where the mirror keeps playing the clip.
        return isActive && (link.isDisplayReady || link.deviceReady) ? .failed : .noLens
    }

    /// The clip has ended a little after its own length: stop serving it.
    private func scheduleClipServerStop(for fileURL: URL, generation: Int) {
        Task { [weak self] in
            let seconds = (try? await AVURLAsset(url: fileURL).load(.duration).seconds) ?? 15
            try? await Task.sleep(nanoseconds: UInt64((max(seconds, 1) + 3) * 1_000_000_000))
            guard let self, generation == self.clipGeneration else { return }
            self.stopClipServer()
        }
    }

    private func stopClipServer() {
        clipServer?.stop()
        clipServer = nil
    }

    func showNewConversationFlash() {
        content = .newConversation
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.newConversation())
        scheduleDwell(seconds: 2)
    }

    func clear() {
        // A clip still starting (HTTP server, queued send) is dropped, even
        // when the lens is off and send() below returns early.
        clipGeneration += 1
        stopClipServer()
        dropQueued()
        content = .blank
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.blank())
    }

    /// Test panel: the test card through GlassesLink's send (attaching the
    /// display first when needed). Throws so the button can show WHY.
    func sendTest() async throws {
        NSLog("[EmoDrink] display test card send (display.state \(link.displayStateText))")
        guard await link.send(HermesDisplayScreens.testScreen(), label: "test card") else {
            throw NSError(
                domain: "HermesDisplay", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    link.displayIssue ?? "The lens did not take the card (display \(link.displayStateText))"]
            )
        }
        NSLog("[EmoDrink] display test card send returned (display.state \(link.displayStateText))")
    }

    /// The SDK's clearDisplay(). Throws when the lens is not attached, so
    /// the Developer page can say why nothing happened.
    func clearDisplay() async throws {
        guard link.isDisplayReady else {
            throw NSError(
                domain: "HermesDisplay", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Display not attached (display \(link.displayStateText))"]
            )
        }
        guard await link.clear() else {
            throw NSError(
                domain: "HermesDisplay", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "clearDisplay failed (see the Glasses basics log)"]
            )
        }
    }

    // MARK: - Plumbing

    /// Serialized send pipeline through GlassesLink: newest queued view
    /// wins, one send in flight at a time (BLE sends can complete out of
    /// order otherwise). While the display is not started GlassesLink holds
    /// the view until it is (or 10 s pass).
    private func send(_ view: FlexBox) {
        // Anything sent replaces a playing showcase clip.
        clipGeneration += 1
        stopClipServer()
        guard isActive else { return }
        enqueue(.view(view))
    }

    /// Serialized send pipeline through GlassesLink, shared by views and
    /// showcase clips: newest queued item wins, one send in flight. A view
    /// replacing a clip stops the video first, inside the same loop.
    private func enqueue(_ item: QueuedSend) {
        dropQueued()
        queued = item
        guard sendTask == nil else { return }  // drain loop already running
        sendTask = Task { [weak self] in
            while let self, self.isActive, let next = self.queued {
                self.queued = nil
                switch next {
                case .view(let view):
                    if self.clipOnLens {
                        self.clipOnLens = false
                        await self.link.stopVideo()
                    }
                    let sent = await self.link.send(view, label: "HUD")
                    if !sent {
                        self.debug("Display send failed (display \(self.link.displayStateText))")
                    }
                case .video(let uri, let completion):
                    let sent = await self.link.sendVideo(uri: uri, label: "showcase clip")
                    self.clipOnLens = sent
                    completion.resume(returning: sent)
                }
            }
            self?.sendTask = nil
        }
    }

    /// Discards the waiting item; a waiting clip's caller hears false.
    private func dropQueued() {
        if case .video(_, let completion)? = queued { completion.resume(returning: false) }
        queued = nil
    }

    private func scheduleDwell(seconds: Double) {
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let idle = self.idleHandler {
                idle()
            } else {
                self.clear()
            }
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func debug(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onDebug?(message)
    }
}
