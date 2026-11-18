# MYVU Conversation Copilot

An experimental iPhone companion for MYVU XGA010C glasses. The goal is to listen to an English conversation, remember its context, and periodically show a short, useful follow-up question privately on the lens, without speaking aloud.

**Current stage: microphone diagnostics and on-device English transcription.** Automatic meeting analysis and periodic contextual advice are not implemented yet. Real glasses capture, simultaneous recording/display, and long-running background operation still require validation.

## Available in the prototype

- A Conversation Copilot screen under Connect and Settings.
- Glasses microphone packet parsing and libopus decoding, with live audio statistics.
- Optional local WAV recording and a diagnostic report; recording is off by default.
- Apple SpeechAnalyzer / SpeechTranscriber for on-device English transcription.
- A fixed 10-second test card for checking display during recording.
- A 10-minute diagnostic session limit and explicit detection of a stalled audio stream.

The Copilot path does not access the iPhone microphone, call cloud transcription services, or generate voice replies. Its speech model may need an initial download. Normal app launch does not automatically start recording.

## Build

Requires a Mac with full Xcode and the iOS SDK. The demo targets iOS 17 or later; Apple on-device transcription requires iOS 26 or later and a supported device/language model. Audio diagnostics can run with transcription switched off.

```sh
git clone https://github.com/paxaq/myvu-copilot.git
cd myvu-copilot
bash build-myvu-ios.sh
```

The script builds an **unsigned** device app. To install on an iPhone, open `Examples/MyvuDemo/MyvuDemo.xcodeproj`, select the MyvuDemo scheme and your device, configure your own signing team and unique bundle identifier, then build and run. The upstream demo includes a HealthKit entitlement, so the signing configuration must support it.

`DEVELOPER_DIR` and `MYVU_BUILD_ROOT` can override the toolchain and build directory. On the original development machine the scripts prefer Xcode and build storage on `/Volumes/m500` when available; other machines use the installed Xcode and a local `.build` directory.

## Test

With full Xcode selected:

```sh
swift test --filter 'AudioCaptureTests|GlassesMicStreamTests|VoiceActivityTests|AiSessionTests|WavTests'
```

The 4 new audio tests and 43 related upstream tests passed on the development Mac. A Debug-only device self-test (`--copilot-self-test`) successfully decoded a bundled synthetic English sample and transcribed it with Apple SpeechAnalyzer on an iPhone 16 Pro Max. This validates the decoder/transcriber pipeline, not the glasses microphone.

The full upstream test suite has a known failure in `ShareAbilityTests.testPngFromOneBlankHudRow`; it is not modified by this project.

## Try the glasses microphone

1. Exit the official MYVU app and disconnect other phones from the glasses.
2. Connect in MyvuDemos, then open Conversation Copilot.
3. For the first test, switch off local transcription, optionally enable local WAV recording, and start the microphone test.
4. Trigger the glasses' normal voice-assistant gesture and speak. Check whether the frame count and audio level change, then stop.
5. Once capture works, repeat with local transcription and test the fixed display card.

The first user test reported an error or difficulty locating the entry point; diagnosis is pending. Continuous listening is not yet proven. No firmware change is required for the initial tests.

See [the development plan](COPILOT-PLAN.md) and [prototype status](COPILOT-STATUS.md).

## Source and licenses

This is a focused source snapshot derived from [BimaPDev/SmartGlasses](https://github.com/BimaPDev/SmartGlasses), commit [`01a374068fba8730b4b497a82bacfda730412428`](https://github.com/BimaPDev/SmartGlasses/tree/01a374068fba8730b4b497a82bacfda730412428), including its Swift SDK and MyvuDemo. It retains the upstream [MIT license](LICENSE), including attribution to the SDK contributors and [Panny777's original Android SDK](https://github.com/Panny777/Meizu-Myvu-SDK).

The optional MyvuAudio product uses a locally built libopus 1.6.1 XCFramework. Its source checksum, build instructions, and license are in [Vendor](Vendor/README.md). The bundled English test audio was synthesized locally; no user recording is included.

The upstream reverse-engineering archive and bundled firmware ZIPs are not included. Some inherited demo tools refer to those optional firmware packs and cannot use them in this snapshot. This is an unofficial experimental project and is not affiliated with Meizu or MYVU.
