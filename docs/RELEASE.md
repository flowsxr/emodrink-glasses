# Releasing EmoDrink

EmoDrink ships as its own app, separate from Hermes Glasses:

| | |
|---|---|
| Bundle id | `com.flowsxr.emodrink` |
| Name on the home screen | EmoDrink |
| App Store / TestFlight name | EmoDrinkGlasses ("EmoDrink" was taken), Apple id `6825477765` |
| Apple team | FLOWXR PTE. LTD. (`3U4384584Z`) |
| URL scheme (Meta AI callback) | `emodrink://` |
| Version | `MARKETING_VERSION` in the project, build number per upload |
| Privacy policy | https://github.com/mayaokonkwo/emodrink-glasses/blob/main/docs/privacy.md |

The repo is a fork. Changes to Hermes Glasses never reach it, and the two
apps can be installed side by side.

## One-time setup

1. **Meta Wearables Developer Center** (https://wearables.developer.meta.com):
   create a project "EmoDrink" with the iOS bundle id `com.flowsxr.emodrink`
   and team id `3U4384584Z`. Copy its Application ID and Client Token into
   `Config/Secrets.xcconfig` as `META_APP_ID` / `CLIENT_TOKEN`. The glasses
   link only to the bundle id registered here.
2. **App Store Connect** (https://appstoreconnect.apple.com › Apps › +
   New App): done. Platform iOS, name "EmoDrinkGlasses", primary language English, bundle id
   `com.flowsxr.emodrink`, SKU `emodrink`. Apple's API cannot create the
   app record, so this step has to be done by hand.
3. **TestFlight › Test Information:** beta description, feedback email,
   privacy policy URL (above), and Beta App Review notes, e.g.:

   > EmoDrink suggests a drink from three options using sample sleep and
   > heart-rate data. It works without glasses: on first launch choose
   > phone mode and point the iPhone camera at any vending machine (or a
   > photo of one). The assistant key is built in, so no sign-in is needed.
   > Meta Ray-Ban Display glasses are optional.

4. **App Privacy** (the app's page in App Store Connect): declare Coarse
   Location, Photos, and Other User Content, used for App Functionality,
   not linked to the user and not used for tracking. This matches
   `HermesGlasses/PrivacyInfo.xcprivacy`.

## Each TestFlight build

```bash
tools/release.sh 2          # next build number; --dry to skip the upload
```

The build shows up in TestFlight after processing (about 5 to 15 minutes).
Add it to the external group "Gift". The first build of each version goes
through Beta App Review (usually under a day), then the invite email goes
out. The tester installs TestFlight, accepts the invite and installs
EmoDrink.

## Handover to Taka

1. In `HermesGlasses/Services/Showcase/ShowcaseDirector.swift` set
   `ShowcaseDefaults.defaultLanguage = .ja`.
2. Bump the build number.
3. `tools/release.sh <n>`, then add the build to the Gift group.

## Before a demo

- Grant microphone, speech and the Meta permissions once, in onboarding.
- Open the showcase home with the demo machine, guest and language selected a minute before, so the clips pre-render (they are cached per
  machine, guest and language; a change re-renders them).
- Check the glasses display with Test lens on Live drink mode, or Settings › Glasses › Developer › Display test.

## Owner device checks

Not yet done on a device; the build was written without glasses.

**The results change CODE DEFAULTS, before the handover build.** The
Developer toggles (`showcase_clip_transport`, `showcase_glasses_swipe`,
`showcase_glasses_speech`) are per-device settings: flipping them on the
owner's phone does not reach Taka's install. Whatever the spikes prove goes
into the defaults in code, then the build number is bumped:

- clip transport: the `== "http"` check in
  `HermesDisplayManager.playShowcaseClip` (file is the fallthrough) and the
  `"file"` `@AppStorage` default in `SettingsView`;
- swipe: `ShowcaseViewModel.glassesSwipeDefault` (now `false`);
- glasses speech: `GlassesSpeechRouting.isEnabled` (`defaults.bool`, so off).

- **Showcase spikes panel** (Settings › Glasses › Developer › Showcase
  spikes): video by file and by http, card latency, and glasses speech.
  Record which clip transport plays and set `showcase_clip_transport` to it.
- **Swipe:** `showcase_glasses_swipe` is off by default. Turn it on in the
  spikes and check that a swipe turns the deck once and does NOT also move the
  focus between the lens buttons; the directions are guessed from SDK names,
  flip them in `GlassesNav.from` if reversed. Select is never mapped (the lens
  buttons handle it).
- **Glasses speech and the call screen:** confirm there is no call screen,
  finals arrive once per utterance, and note the locale the glasses report.
  Only then turn `showcase_glasses_speech` on (it is off by default).
- **Card layout with the buttons:** the card image against the buttons on the
  lens (possibly needs `.flexGrow`); clip render time on the phone.
- **New drinks:** the Japanese spellings, caffeine and sugar of the added
  drinks are best-effort (the Asahi site blocked fetches); check them against
  the labels.
- **Rehearsals:** English with the sample machine; Japanese with a machine
  added by voice; and glasses off mid-run (the run continues on the phone).
  Note any text under 24 px or any stutter.

## Glasses for the tester

Until the Meta project is published, the tester's glasses need
**Developer Mode**: in the Meta AI app, Settings › App Info, tap App Version
five times, then press Install for the Device Access Toolkit. After that,
pair from EmoDrink › Settings › Glasses and allow the glasses camera.

To get past Developer Mode, publish the integration from the Meta Developer
Center:

1. Versions › create a version for the TestFlight build and wait for its
   DAT build to finish (10 to 30 minutes).
2. Release channels › create a channel (invite-only, up to 100 people),
   attach the version, and invite the tester by the email on their Meta
   account (a personal Meta account, not a Meta Managed Account).
3. A public App Store release with glasses support is limited to Meta's
   approved partners for now. Meta says it plans to open publishing to
   everyone in 2026. Until then, TestFlight plus a release channel is how
   EmoDrink reaches other people's glasses.

## Before an App Store release

- The bundled OpenRouter and Gemini keys are stored as plain text in the
  app's Info.plist, and anyone with the IPA can read them. Set spending
  limits on both keys now. Before going public, move them behind a small
  proxy, or ask the user for a key.
- Screenshots (6.9" iPhone), description, keywords, support URL, age rating.
- Review notes as above, plus a short video of the glasses flow.
