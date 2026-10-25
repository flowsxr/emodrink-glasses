# EmoDrink privacy policy

_Last updated 21 October 2026_

EmoDrink is a research gift app from AHLab. It has no accounts, no
advertising and no analytics, and it never sells or shares your data for
tracking.

## What stays on your iPhone

- **Your voice.** Speech is turned into text on the iPhone by Apple's
  on-device recognizer. Audio is never uploaded.
- **Settings and the downloaded sample data.** These are kept in the app's
  own storage on the iPhone and are deleted when you delete the app.

## What leaves your iPhone, and why

To pick and describe a drink, EmoDrink sends the following to the AI
service built into the app (OpenRouter, which forwards to Google Gemini):

- the words you said, after they have been turned into text;
- a still photo from the glasses or iPhone camera when it checks for a
  vending machine, or when you ask about what you see;
- a short context line: time of day, approximate location, whether you are
  walking or still, battery level and the local weather.

The text of each spoken reply is sent to Google's Gemini text-to-speech
service to produce the voice. When that service can't be reached, the app
uses the iPhone's built-in voice.

None of this is linked to your name or to an account. The services process
it to answer the request; their own policies apply:
[OpenRouter](https://openrouter.ai/privacy) and
[Google Gemini API](https://ai.google.dev/gemini-api/terms).

The sleep and heart numbers come from a sample file the app downloads from
this project's GitHub repository. EmoDrink does not read Apple Health.

## Meta glasses

When you use Meta Ray-Ban Display glasses, the connection runs through
Meta's Wearables Device Access Toolkit and the Meta AI app, and
[Meta's privacy policy](https://www.facebook.com/privacy/policy/) covers that
link. Usage analytics in the toolkit are switched off in this app.

## Contact

Questions: open an issue at
https://github.com/flowsxr/emodrink-glasses/issues
