# Working on MYVU Copilot

- This repository contains the Swift SDK, iPhone demo, and Copilot prototype. Read `README.md`, `COPILOT-PLAN.md`, and `COPILOT-STATUS.md` before changing the capture pipeline.
- Keep the Copilot capture path independent from the short-turn `AiSession` assistant. Never introduce TTS or automatic microphone activation into normal launch.
- Preserve the distinction between validated decoding/transcription and unverified glasses microphone, continuous capture, display coexistence, and background behavior.
- Use synthetic fixtures for automated tests. Do not commit real recordings, transcripts, device reports, credentials, signing profiles, or personal build settings.
- Run targeted audio/protocol tests and an iOS build for capture changes. Do not describe the full upstream test suite as passing while its known screenshot test remains broken.
- Preserve upstream MIT and libopus notices. Rebuild libopus only from the checksum-verified source using `scripts/build-opus.sh`.
- Do not flash firmware as part of building or testing this app.
