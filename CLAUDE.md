# EmoDrink Glasses - notes for Claude

A standalone, MIT-licensed project. See README.md for architecture and setup.

## Current state (2026-10-22)

The app opens on the SHOWCASE home: pick the machine, the guest and the
language, press Start, Reset for the next guest. Live drink mode (the original
one-screen app: starts watching for a vending machine, three drinks on the
lens) is one row away on that home. Japanese or English speech both ways.
Voice loop: on-device STT, `DirectClient` to the provider, Gemini cloud TTS
with the on-device voice as fallback. Vision: the Ray-Ban camera through DAT,
or the iPhone camera in phone mode.

## Key facts that are easy to get wrong

- **EmoDrink only: one screen, Meta only, no bridge, bundled key.** Every
  Hermes feature (people, Lens, Map, Build Check, AiSee, the bridge, the app
  drawer) is DELETED, not hidden: no file, project entry, model, test or
  tool remains. `BundledAIKey.seedIfNeeded()` runs FIRST in
  `HermesGlassesApp.init()` (before the session view model reads provider
  state), takes provider, model and key from Info.plist `EmoDrinkBundledAI`
  (fed by the gitignored `Config/Secrets.xcconfig`), and never overwrites a
  user key: the Keychain is written only when that provider has none.
- **EmoDrink is its own app: `com.flowsxr.emodrink`, scheme `emodrink://`**
  (team FLOWXR `3U4384584Z`). It no longer shares Hermes's bundle id, so its
  `META_APP_ID` must come from the EmoDrink project in the Meta Wearables
  Developer Center, not from Hermes's. `tools/release.sh <build>` archives
  and uploads to TestFlight; the steps that can only be done by hand are in
  `docs/RELEASE.md`. The Wi-Fi entitlements are NOT leftovers: MWDATCore
  calls NEHotspotConfiguration.
- **TTS is Gemini first, on-device fallback.** `HermesSpeechSynthesizer`
  fetches each spoken line from Gemini text-to-speech (`CloudSpeech`,
  length-aware timeout 3 to 10 s, voices Kore for ja and Aoede for en) and plays it with
  `AVAudioPlayer` on the app's existing audio session; offline, on any error
  or after the timeout it speaks the same line with `AVSpeechSynthesizer`.
  Key and model come from Info.plist `EmoDrinkBundledAI` (`TTSKey`,
  `TTSModel`, fed by the gitignored Secrets.xcconfig); setting
  `emodrink_cloud_voice` (default true). The key rides in the
  `x-goog-api-key` header, never in the URL.
- **STT is on-device.** `SFSpeechRecognizer`, on-device when supported. There
  is no server path.
- **Audio session uses mode `.default`, not `.voiceChat`** - voiceChat's DSP
  gates speech to the noise floor (~20 dB down). There is therefore NO echo
  cancellation: the recognizer is suspended while Hermes speaks and resumes
  0.7 s after playback ends.
- **Never detach the TTS player node** - `AVAudioEngine.detachNode` on a live
  node raises NSException (SIGABRT). The player is attached once and reused.
- **SFSpeechRecognizer:** `task.cancel()` fires the old task's handler with an
  error. Restart cycles are guarded by a generation counter or the recognizer
  goes deaf after the first suspend/resume.
- **Glasses camera needs a separate permission** granted through the Meta AI
  app: `wearables.requestPermission(.camera)` (the Photo test button runs it).
  Streams fail with `permissionDenied` otherwise.
- **Every DAT call goes through `GlassesLink`** (`Services/GlassesLink.swift`),
  the code proven on the owner's Ray-Ban Display by the Glasses basics
  tests (Settings › Glasses › Developer › Glasses basics) and a near-copy of
  Meta's DisplayAccess and CameraAccess samples. One instance, created in
  `HermesGlassesApp`, owns the ONE DeviceSession, the Display (send waits
  for `.started`, 10 s timeout) and the Camera (`.raw`, `.low`, 24 fps,
  `frame.makeUIImage()`, keyed consumers). Nothing else creates a session,
  adds a display or adds a camera: the older paths did not work on device.
- **Display HUD (Ray-Ban Display):** `HermesDisplayManager` builds the
  screens and sends them through `GlassesLink.send`; `activate()` /
  `deactivate()` follow the glasses session and the HUD setting, and its
  status mirrors GlassesLink's display state. Every display call is
  best-effort - errors are logged, never surfaced. Settings keys:
  `display_hud_enabled` (default true), `display_silent_mode`.
- **Glasses mic and the HUD are mutually exclusive.** The glasses mic is
  Bluetooth HFP (the DAT SDK has no audio capability); an active HFP/SCO
  link makes the glasses firmware show its CALL SCREEN on the lens, which
  covers all DAT display content. iPhone mic = HUD visible; glasses mic =
  call screen. Firmware behavior - cannot be overridden from the app.
- **Headset mode is the pocket setup:** `MicSource.headset` routes HFP to
  earbuds (never to the glasses - port chosen by name heuristic in
  `HermesAudioManager.looksLikeGlasses`), so the lens keeps the HUD while
  mic + TTS live in the ears. Falls back to the iPhone mic (with a notice)
  when no non-glasses HFP device is present.
- **Device context:** every query carries a context line (time, location,
  motion, connectivity, battery, weather) as a SECOND, uncached system block
  (persona block stays first + cached). History stores raw user text only.
  Keys: `context_enabled` / `context_precise_location` (both default true).
- **On-device intents (`IntentDetector`, `Services/EmoDrink/`):** the
  finalized transcript is classified BEFORE the assistant, as a WHOLE
  utterance: "what should I drink", "start/stop drink mode". Anything longer
  is a question for the assistant.
- **Settings is four pages** (`Views/SettingsView.swift`): Glasses (with the
  Developer test panel under it), Assistant, Language and voice, Drinks. A
  typed API key is owned by the ROOT SettingsView and committed on Done *and*
  swipe-dismiss.
- **Replies with options become buttons** (`ChoiceDetector`, pure, tested in
  `tests/choices/`). "A) Sydney, B) Melbourne, …" turns into lens buttons,
  chat chips, and a line on the simulated lens; tapping one submits the
  option's WORDS, not its letter. Deliberately conservative - two or more
  markers, ascending from A/1, each with text - because a false positive
  replaces Stop/Repeat on a display the wearer can't easily escape. A reply
  carrying options never auto-dwells away.
- **Mic tap-to-switch cannot pre-filter by device.** HFP ports only appear
  in `availableInputs` once the audio category allows Bluetooth, and the
  iPhone-mic path deliberately doesn't (it stops iOS hijacking the input).
  Enumerating anyway made connected glasses report "not available", so
  `toggleMicSource` walks to the next route that actually takes and
  `setMicSource` returns whether it did.
- **The Meta AI camera grant is requested AT PAIRING**
  (`ensureGlassesCameraAfterPairing`, fired from `ContentView.onChange` of
  `registrationState`), offered again in onboarding, and shown on the
  Settings Glasses page under the "Glasses camera" header. It used to be
  requested in exactly one place - the Photo test button - so anyone who
  never pressed it hit "camera unavailable" in drink mode, with nothing
  explaining why. Never gate a feature on this grant without offering the
  interactive request; `ensureCameraPermission(interactive: false)` alone is
  a dead end.
- **The test panel must work from a cold start.** It exists to diagnose a
  broken setup, so requiring a running session is backwards. `testPhoto`
  and `testVisualQuery` get their photo from `GlassesLinkVision`, which opens
  GlassesLink's camera for a moment; `testDisplay` sends through GlassesLink,
  which opens the session and attaches the lens when needed.
- **The glasses stream is `.low`, as in Meta's CameraAccess sample.**
  `addCamera` returns a bare `nil` when the firmware won't serve a config.
  Drink mode's stream is a GlassesLink camera consumer (started in
  `EmoDrinkViewModel.startStream`, stopped in `stopStream`); a visual
  query's photo is the latest frame.
- **Display callbacks are wired in `init`, not `startSession`.** `wireDisplay()`
  must stay in the initialiser: the lens is reachable (display test, a pick by
  voice) before any session-scoped wiring exists.
- **Camera permission is TWO different grants.** The glasses camera is
  authorised through the Meta AI companion app
  (`wearables.checkPermissionStatus(.camera)`); the iPhone camera through
  iOS (`AVCaptureDevice`). Capture paths must gate on
  `ensureVisionPermission(interactive:)` and `hasVisionSource`, never on
  `ensureCameraPermission` / `isGlassesConnected` directly - those are the
  glasses answers, and in phone mode they are always no. Gating on
  those once silently disabled every phone-mode capture.
- **One AVCaptureSession per camera.** In phone mode the session already
  streams for drink mode, so a second consumer must observe rather than
  start its own: `addVisionFrameObserver(_:_:)` (the only observer today is
  `EmoDrinkViewModel.frameObserverKey`, "emodrink") and
  `visionStreamIsShared`. Never call `vision.stopLiveStream()` for a stream
  you didn't start - it blanks the screen the user is looking at.
- **Never offer "Connect Glasses" to registered glasses.** `startRegistration`
  on an already-registered user throws "User is already registered", which
  is a dead end. The Glasses page in Settings handles pairing and re-pair.
- **"Are glasses paired" is NOT "can a glasses session start".**
  `registrationState == .registered` and a non-empty `wearables.devices`
  both stay true for glasses that are paired but out of range, while
  `createSession` throws `DeviceSessionError.noEligibleDevice`. The only
  honest predicate is the SDK's own selector:
  `deviceSelector.activeDevice != nil` (`HermesSessionViewModel.glassesAvailable`).
  Getting this wrong made Auto phone-mode never fall back, so Start
  insisted on absent glasses.
  Route selection itself is pure and tested in `tests/vision-routing/`.
- **Never predict hardware without a fallback.** Eligibility can lapse
  between the check and the start, so the glasses path falling through to
  the phone is handled at two points: `startSession()`
  and `captureVisionPhoto()`. `PhoneCameraManager.capturePhoto()` will spin
  the camera up for a single frame if nothing is streaming, so either eye
  can serve a still. `logVisionDiagnostics(_:)` prints registration, device
  link states, `activeDevice`, and the chosen route - use it before
  theorising about which eye was picked.
- **The vision route is pinned for the life of a session.** `visionRoute`
  is recomputed only while nothing is pinned; the running session calls `pinVisionRoute`
  (`startSession`) and `unpinVisionRoute` on teardown. Without this, a momentary SDK flap redirected a
  capture to a camera that wasn't running.
- **The visual language lives in `Views/HermesDesign.swift`**. ONE accent -
  deep blue `#1446A0` (`accentDeep` `#0D2F75`, `accentLight` `#7FA6E8`);
  cool neutrals (ink `#0F1B33`, `inkSoft` `#5C6B85`, canvas `#F4F7FB`,
  card white, dark canvas `#0B1529`), never stock iOS greys or per-row
  rainbow icons. (It was terracotta once; that is gone.) Build screens out of
  the primitives there (`HermesSection`,
  `HermesCard`, `HermesRow`, `HermesIconTile`, `HermesChip`,
  `HermesStatusPill`, `HermesDeviceCard`, `HermesScrollPage`) rather than
  re-styling a `List`; pages that keep a stock `Form` (Language and
  voice, Glasses status) call the local `hermesFormStyle()` so the canvas matches.
  `HermesMark` is the winged logo as a `Shape` (SVG polygons on a 140x72
  canvas); the wordmark is system `.heavy` + wide tracking, since no
  Montserrat file ships with the app.
- **The test panel lives in Settings › Glasses › Developer**, with the
  diagnostics rows. Nothing floats over the home screen.
- **`VoiceCommandCatalog` reads phrases from the detectors** (`IntentDetector`,
  `EmoDrinkCommands`, `VisualQueryDetector`), never hand-copied.
- **ChangeGate thresholds are provisional** (0.35 change / 0.12 settle);
  `VendingMachineGate` wraps them for drink mode.
- **Project files: `tools/pbx-register.py`** adds a new file's four pbxproj
  entries; **`tools/pbx-unregister.py <basename> ...`** removes every entry for a
  deleted one (never hand-edit the pbxproj for a deletion).
- **Showcase: runner and view model.** `ShowcaseRunner`
  (`Services/Showcase/`) is PURE: time and side effects come in as injected
  `ShowcaseEffects` and `ShowcaseClock`, which is how `tests/showcase-runner`
  drives a whole run without a device. `ShowcaseViewModel` is owned by the
  App struct (like `EmoDrinkViewModel`) and borrows the session through hooks.
- **Showcase picks are machine-only and the hour is pinned to 9.** Drinks come
  from the chosen machine's list, never the whole catalogue, and the
  recommender runs with the hour fixed at 9 so a demo at 15:00 still reads as
  a morning. `ShowcaseDefaults.defaultLanguage` (in `ShowcaseDirector.swift`)
  is the handover switch: `.ja` for Taka's build (see docs/RELEASE.md).
- **Lens art is 600x600 with a 24 px text minimum, and colour comes from
  images and video.** The lens text path has only two colours, so anything
  coloured (drink art, the morning ring) is a rendered image or clip.
  `minimumScaleFactor` that lets text fall under 24 px is a bug.
- **Clips are pre-rendered and cached.** `ClipRenderer` runs whenever the
  machine, profile or language changes (the cache key covers every input) and
  is awaited on Start ("Preparing" on the phone). `showcase_clip_transport`
  is `file` (default, `file://` URIs) or `http` (the local server from the
  spikes); flip it if the glasses can't read the file.
- **One display queue carries cards AND clips.** `HermesDisplayManager`'s
  serialized queue sends both, and `stopVideo` runs before a card replaces a
  clip. Bypassing the queue is how a card ended up under a playing clip.
  `playShowcaseClip` returns a `ClipOutcome`; on `.failed` (glasses in reach,
  nothing newer queued) the view model sends the clip's art at t = 1 as a
  still card with no buttons, so the lens is never blank for the step. With
  no glasses at all it is `.noLens` and the mirror keeps the clip.
- **The showcase session has no vision and no context.** It starts through
  `startSessionWithoutVision` (no camera prompt mid-run, no device-context
  fetch). It stays up after a run for the next guest; live drink mode
  REPLACES it (it does not inherit it), and add-by-voice ends it
  (`endIdleSession`). Settings is locked during a run. It activates the lens
  whatever the vision route (HUD on, no call screen), because it is reused:
  glasses out of reach at the first Start still get later runs, and Start
  also calls `ensureShowcaseLens` for a reused session.
- **During a run, problems are the run notice, never alerts.**
  `showcaseRunActive` plus `showcaseIssueSink`, set by ShowcaseViewModel for
  the WHOLE run: `reportError` / `reportNotice` (session errors, the glasses
  speech fallback, mic and start problems) go there instead of
  `show(...)`. With no run active they alert as before.
- **`showcaseClaimer` claims EVERY utterance while `showcaseOwnsVoice`**: a
  run, or the showcase's own (no-vision) session between runs. Consulted
  before `emoDrinkClaimer`; during a run the runner answers through the
  one-shot AI so the normal assistant card never replaces the deck; between
  runs everything is swallowed, so nothing starts a drink moment whose timer
  would clear the next run's lens. Listening partials stay off the lens
  meanwhile. The guest cannot reach the general assistant (intended). Start
  calls `EmoDrinkViewModel.stopForShowcase`, which also ends a "what should I
  drink" moment with drink mode off.
- **A run borrows, never keeps, app-wide settings.** Start notes
  `emodrink_language` and the saved `mic_source`; teardown (end or Reset)
  writes them back, so "auto" and a headset choice survive. The showcase
  session keeps the language it resolved and the iPhone mic it has;
  `endSession` of a no-vision session reloads `micSource` from the saved
  choice.
- **A Japanese run speaks only Japanese.** `ShowcaseReply.speakable` drops an
  AI reply with no hiragana, katakana or kanji (the scripted line is spoken),
  and a strong drink's tag reads カフェイン入り, never "mg".
- **`SpeechFinishGate` guards stale finishes** of the speech synthesizer, so a
  cancelled line's finish callback cannot advance the next step.
- **Glasses input is two settings.** Swipe (`showcase_glasses_swipe`, default
  OFF until the owner's inputs spike shows a nav event does not also move the
  lens buttons' focus) maps via `GlassesNav.from`; the directions are guessed
  from SDK names, flip them there if reversed. Select and the action button
  are NOT mapped: the native lens buttons already handle select, and mapping
  it as well chose twice. Glasses speech
  (`MicSource.glassesSpeech`, `showcase_glasses_speech`, default OFF) stays
  off until proven on device: the glasses mic is HFP and the firmware may
  show the call screen over the lens.
- **Catalogue aliases: bare brand words belong to the flagship only**
  ("Calpis" is Calpis Water; siblings get brand + variant aliases; no generic
  category aliases). `tests/emodrink-catalog` enforces it.
- **`DrinkNameMatcher.matchAll` protects と.** Guests join drinks with と,
  but a catalogue key can contain it (ほっと十六茶), so a と inside a known key
  is kept and only the others split.
- **EmoDrink:** the pick is on-device (`DrinkRecommender`, pure, tested) and
  the AI only phrases and converses. `EmoDrinkViewModel` is owned by the App
  struct and borrows the session through hooks (`emoDrinkClaimer`,
  `onEmoDrinkIntent`, `onEmoDrinkSessionEnding`, `emoDrinkLensIdle`). The
  moment has two steps: `.choices` (three drinks as `LensContent
  .emoDrinkChoices`, buttons `1 <name>`) and `.chosen` (the card with Why /
  Thanks). The claimer takes EmoDrinkCommands replies first, then
  `DrinkChoiceParser` (numbers, ordinals, an exact full name, then a
  DISTINCTIVE name token; a token two options share never decides), then the
  drink-mode intents; everything else goes to the assistant with
  `DirectClient.systemPromptOverride` set to the persona. "Why" is a
  one-shot call (`DirectClient.askOneShotText`), so it never re-enters the
  claimer. Drink mode reuses `ChangeGate`
  through `VendingMachineGate` (8 s spacing, 150/h, 120 s cooldown after a
  pick; "Check now" skips the change gate and the cooldown, never the
  budget) and `FrameTools.canRunVisionChecks` as its preflight. The default
  physiology feed is this repo's `mock/physiology.json` on
  raw.githubusercontent.com: pushing a change to that file changes what
  every install reads.
- **Language is resolved once per session.** `HermesSessionViewModel
  .applyLanguage()` turns `emodrink_language` (auto/en/ja; auto = the
  iPhone's FIRST preferred language) into a recognizer locale and a voice
  (`VoicePicker`: premium, enhanced, default; preferred names; never a
  novelty voice, never another language's voice). No ja-JP recognizer:
  notice and English. No ja-JP voice: English. `activeLanguage` is what the
  lens strings (`EmoDrinkStrings`), reasons and persona use. It only runs
  while the recognizer is stopped, so a mid-session change applies next
  session.
- **The Developer Display test (and Test lens) sends through GlassesLink.**
  The send opens the session and attaches the lens when needed, 10 s to
  `.started` (the DisplayAccess sample's deadline); an attached lens is
  cleared first; the card ("EmoDrink" / "Lens OK") stays 15 s, then the HUD
  card comes back (or the lens is cleared).
  Every DisplayState and step is traced with a timestamp into
  `displayTestTrace` (shown under the report, with a Clear lens button), and
  the report carries the SDK's `display.state` read right after the send. Outcomes are `DisplayTestReport` (pure, tested in
  `tests/display-logic`): sent, no glasses, display session failed (SDK
  error), glasses mic in use (call screen hides the HUD).

## Build & run

```bash
# iOS (from repo root; use your own device ID from `xcrun devicectl list devices`)
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build

```

### Two traps in the standalone test suites

- **Two suites have no command in their header** (`tests/device-context`,
  `tests/display-logic`): compile `Services/DeviceContextFormatter.swift` and
  `Services/HermesDisplayLogic.swift` with their `main.swift` respectively.
- **`tests/*/main.swift` end in `print(...)` then `exit(...)`.** New assertions
  must be INSERTED ABOVE those two lines. Appended to the bottom they sit
  after `exit()`, never run, and the suite still reports all-green - so the
  tests look like they pass when they were never executed.
- **`AIProvider.swift` does not compile alone.** `AIProviderRegistry`
  references `AnthropicProvider`, `OpenAICompatibleProvider` and
  `GeminiProvider`, so any suite needing `AIProviderError` (or anything else
  from that file) must list all four provider sources on the `swiftc` line.
  `tests/providers/main.swift`'s header carries the canonical command.

## Next milestones

- Translate the Settings labels (lens and speech are already bilingual).
- Apple Health as a physiology source.
- Detect which drinks the machine actually sells.
