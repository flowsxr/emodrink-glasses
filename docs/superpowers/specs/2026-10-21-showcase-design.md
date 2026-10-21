# EmoDrink Showcase: design

_2026-10-21. Status: for approval._

## Why

Taka (who ran the EmoDrink study and lent the glasses) will show EmoDrink to
his superiors in November. A guest puts on the Meta Ray-Ban Display glasses
and, in about 60 seconds, sees the idea land: the glasses know how you are
this morning, read the vending machine in front of you, and offer the right
drink. It is a curated experience, not a factual tool. Success is a guest who
takes the glasses off impressed, and a Taka who never had to apologise for
the demo.

## Roles

- **Guest:** wears the glasses. Watches, may swipe or talk. Probably speaks
  Japanese. Has never seen the app.
- **Taka (host):** holds the iPhone running the app. Sets up machines ahead
  of time, picks the machine and (optionally) a profile, presses Start,
  narrates. Resets for the next guest.

## Goals

1. A polished, roughly 60-second showcase that runs on autopilot after Start.
2. Rich use of the display: colour, large type, pictures, smooth motion.
3. Works the moment it is installed from TestFlight: sample morning, built-in
   catalogue, a built-in sample machine.
4. Taka can save many vending machines and say what each one holds, so the
   "scan" shows that machine's real drinks.
5. Taka can tailor the guest's "morning": pick a profile, or answer a few
   quick questions about the guest.
6. Guest interaction after the reveal: swipe the deck, talk, and the card
   the conversation is about comes to the front.

## Non-goals

- Real vending-machine recognition or real reading of slots. The scan is
  staged from Taka's machine list.
- Real physiology. Vitals are an assumption or a chosen profile.
- Medical accuracy. The persona stays suggestive, never diagnostic (the
  study's rule).
- Real turn-by-turn navigation.
- Public App Store release (TestFlight for Taka only).

## Anti-goals (a failure even if it "works")

- Anything stutters, lags, flashes blank or shows an error on the lens in
  front of an executive.
- Text too small or too dense to read on the 600 x 600 lens.
- The call screen covering the lens because the glasses mic is in use.
- A setup step Taka has to remember on the day.
- Content that looks like a debug build: raw numbers with units only, IDs,
  English when the guest speaks Japanese.

## The experience

Timings are targets; total about 60 to 70 seconds with navigation, about 50
without.

1. **Navigate (optional, ~10 s).** A large warm arrow and a distance counting
   down ("40 m" to "here"), with the machine's name. Staged on a timer. On
   or off per machine.
2. **Your morning (~12 s).** Smooth animation: sleep ring fills, HRV and
   resting heart rate count up against "your usual", a heartbeat line draws
   itself, one short summary line ("Short sleep, a little tense"). Numbers
   come from the guest profile.
3. **Reading the machine (~10 s).** A scan line sweeps a stylised machine
   front; slots light up one by one; the machine's drink names tick in. The
   names are exactly the drinks Taka saved for this machine.
4. **The deck (open).** Three recommended drinks, chosen only from this
   machine's drinks, as a **stacked deck**: the focused card in front, the
   other two fanned behind it with their emoji/name and colour visible on
   the edge (chosen in review over side-peeks). The voice names the
   recommendation and why, in one warm line.
5. **Why this one.** The front card shows the name, at most two two-word
   reasons each with a coloured dot tied to a vital ("HRV low", "Short
   sleep"), and one tag ("GENTLE · NO CAFFEINE"). Buttons: Choose, Next.
6. **Talk, and the card follows.** The guest can ask anything ("big meeting
   at 10, anything stronger?"). The reply is spoken; the drink the reply is
   about comes to the front of the deck, even if it was not one of the three
   (it joins the deck), as long as this machine holds it (see "Decided in
   review"). The guest's words are not shown on the lens.
7. **Choose.** A short confirmation flourish, then the lens clears. Ready for
   the next guest.

**Autopilot:** steps 1 to 4 advance on their own. At the deck, the guest
leads. If the guest does nothing for about 8 s the deck rotates through the
other two and settles back on the first; after about 45 s idle at the deck
it ends with the confirmation as if the first drink were chosen.

## Lens visual rules (agreed)

- Designed at the display's real 600 x 600 pixels. Smallest text 24 px;
  drink names about 52 px.
- On a card: emoji or picture, name, one tag, at most two two-word reasons.
  No sentences on cards. The voice carries the detail.
- At most three buttons, large.
- Black is see-through on this display: design light on dark, with glow,
  never large white areas except the cards themselves.
- One colour per drink function, consistent across scan, deck and reasons
  (e.g. calm = blue, energise = amber, hydrate/recover = teal, refresh =
  green). Exact palette is the builder's call.

Mockups agreed in review: `.superpowers/brainstorm/*/content/deck-v3.html`
(deck sized for the real display) and `storyboard.html` (order and feel).

## What the display can do (verified in MWDATDisplay 1.0)

- `display.send` takes ONE root view and replaces the previous one.
- Views: `FlexBox`, `Text` (styles heading/body/meta; colours primary and
  secondary only), `Button` (primary/secondary/outline, optional icon),
  `Icon` (built-in names), `Image` (a `UIImage` or a URI; sizes icon/fill),
  `VideoPlayer` (MP4 from a URI).
- So **colour comes from images and video**, not from text. Plan:
  - The deck and cards are full-colour `UIImage`s rendered on the phone
    (SwiftUI `ImageRenderer`), sent as `Image(.fill)` with native `Button`s.
  - Navigation, morning and scan animations are short MP4s rendered on the
    phone at runtime from the profile and the machine (AVAssetWriter), then
    played by `VideoPlayer`.
- All lens traffic goes through `GlassesLink` (project rule).

## Phone app (Taka's side)

- **Showcase home** (becomes the app's main screen):
  - the machine picker;
  - the guest profile (default "assumed", a preset, or the quick
    questions);
  - the navigation on/off switch;
  - a big **Start**, and **Reset** for the next guest;
  - a live mirror of what the lens shows, so Taka can narrate.
- **Machines:** a list of saved machines, each with a name, an optional
  distance for the navigation step, and its drinks.
  - **Add by voice:** Taka reads the drinks aloud; each phrase is matched to
    the catalogue (Japanese and English names, common short forms) and
    shown in a table he can correct.
  - **Add by hand:** pick from the catalogue, searchable.
  - A drink that is not in the catalogue can be added by name with a
    generic card. Online lookup is out of scope (see open question 3).
  - One sample machine ships built in, so a fresh install works.
- **Guest profile:**
  - presets: assumed default (slightly short sleep, slightly tense), well
    rested, short sleep, stressed, post-workout;
  - or three or four quick questions (how did you sleep, busy day ahead,
    exercised this morning, coffee already?) that produce believable
    numbers.
- The existing real drink mode and Settings stay, reachable from the
  showcase home; the showcase is the default.

## Catalogue

Expand `asahi-drinks.json` from 12 to Asahi Group's current Japanese soft
drink range (Wilkinson, Mitsuya, Calpis, Wonda, Juroku-cha, Mugicha,
Oishii Mizu, Super H2O, Dodekamin, and the rest of the line-up). Each entry
keeps the current fields (names in Japanese and English, functions, sugar,
caffeine, served) and adds:

- a display colour;
- an emoji or simple illustration;
- voice aliases for matching (e.g. 「十六茶」, "sixteen tea", "juroku").

Facts come from Asahi's public product pages. No Asahi bottle photos or
logos are bundled; card art is drawn.

## Voice and language

- **Taka picks the guest's language** on the showcase home: a 日本語 /
  English switch, remembered between guests. It drives the showcase's lens
  strings, spoken lines, persona and recognizer for that run, overriding
  the app-wide setting. If the switch changes, the next Start uses it, and
  the recognizer restarts in that locale.
- **Default: English until handover, Japanese after.** One constant in the
  code decides the default; the handover build flips it to Japanese. Once
  Taka has touched the switch, his choice stands.
- The showcase must be complete in both languages, with no English leaking
  into a Japanese run.
- **The network is reliable at the venue (owner's answer).** The reveal
  line, the conversation and the Gemini voice may use the cloud. A short
  timeout still falls back to the on-device voice, so a slow reply never
  freezes the lens.

## Guest input: the open risk

- **Swipe and tap:** lens buttons and the glasses' navigation inputs
  (`MWDATInputs`: navigation, button, drag) rotate the deck.
- **Talk:** the glasses mic over Bluetooth brings up the firmware call
  screen, which hides the lens (known, documented). The candidate fix is
  `MWDATSpeech` (on-device transcription on the glasses, needs the Meta
  microphone permission, which the EmoDrink Meta project now has).
  Untested; Japanese support unknown, and the locale is read-only.
  - **Fallback (owner's choice): the guest speaks towards Taka's iPhone.**
    The iPhone mic keeps the lens visible and the full conversation
    feature. Build this path first; it is already how the app listens. The
    glasses-speech path is added on top if spike 1 passes.
- **This must be proven on the glasses before the deck/conversation work is
  built on it.**

## Spikes before building (on the owner's Ray-Ban Display)

The owner has the glasses until handover (assumed from "until I hand over"),
so the spikes run first, on device. Speech and Inputs are SDK modules the
project does not link yet (today: Core, Camera, Display, MockDevice).

1. `MWDATSpeech`: does it start, does the call screen stay away, does
   Japanese come through, what latency?
2. `VideoPlayer`: does a local `file://` MP4 play, or does it need an http
   URI (a tiny local server on the phone)? Smoothness, start latency,
   resolution, any size limit.
3. `Image(UIImage)` send latency for a full 600 x 600 card, to judge how
   smooth deck rotation can be and whether transitions should be short
   videos too.
4. `MWDATInputs`: which swipe/drag events arrive from the glasses and band.

The outcome of spikes 2 and 3 may change how transitions are made, not the
experience.

## Constraints

- Swift/SwiftUI, the existing project and its rules (CLAUDE.md): one
  `GlassesLink`, `HermesDesign` primitives on the phone, pure logic tested
  under `tests/`.
- Must run without Taka touching Settings after install.
- Ships through the existing TestFlight pipeline (`tools/release.sh`).
- Timeline: a couple of days of build; the demo is in November. The bar is
  "perfect", so device testing time is budgeted, not optional.

## Left to the builder

- Exact palette, typography and motion curves within the visual rules.
- How animations are rendered (Core Animation to AVAssetWriter, SpriteKit,
  pre-rendered templates with dynamic text).
- Matching algorithm for spoken drink names.
- Profile-to-numbers mapping and the question set's wording.
- The persona's handling of "bring a drink into focus" (structured reply vs
  parsing the reply for a catalogue name).

## Decided in review (Claude's calls, to check)

- **Only this machine's drinks.** Recommendations and anything the
  conversation brings forward come only from the selected machine's
  drinks. If the guest asks for something the machine doesn't hold, the
  voice says so and brings forward the closest drink it does hold. This
  replaces "it joins the deck" in step 6: an off-machine drink would break
  the staged scan. The persona prompt and the focus parser get the
  machine's list, not the whole catalogue.
- **Always "your morning".** The showcase pins the recommender's hour to
  morning (09:00) so picks and copy don't change when the demo runs in
  the afternoon. Real drink mode keeps using the real time.
- **The phone drives everything.** No start or reset from the glasses.
- **No online lookup.** A drink outside the catalogue is added by name
  with a generic card.
