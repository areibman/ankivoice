# AnkiVoice — Hands-Free Flashcards for iOS

A local-first, voice-native spaced-repetition app. Put your iPhone in your pocket, start a study session, and review flashcards entirely through spoken interaction — the app reads each card, detects when you've finished answering, reads the answer, and schedules the next review when you say **Again, Hard, Good, or Easy**.

The core loop needs no network, no account, no cloud AI:

```
FSRS + TTS + voice-activity detection + four-command speech recognition
```

## Requirements

- Xcode 26+ with the iOS 26.5 SDK
- iPhone running iOS 26+ (speech assets and locked-screen audio must be validated on real hardware; the simulator supports building and unit testing only)

## Building

```bash
xcodegen generate          # regenerates AnkiVoice.xcodeproj (run after adding files)
open AnkiVoice.xcodeproj   # scheme: AnkiVoice
```

Or from the CLI:

```bash
xcodebuild build -project AnkiVoice.xcodeproj -scheme AnkiVoice \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

## Testing

Unit tests (FSRS, import/export, session state machine, voice selection, recognition recovery) run on the simulator without network or device access, plus two UI smoke tests:

```bash
xcodebuild test -project AnkiVoice.xcodeproj -scheme AnkiVoice \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5'
```

The FSRS scheduler is a faithful port of the reference implementation
(open-spaced-repetition py-fsrs 6.3.2) and its test suite reproduces the
reference's published expectations exactly (interval histories, memory
states, fuzz bounds, learning-step behavior).

## Architecture

```
SwiftUI UI
    ↓
StudySessionController        deterministic review state machine (PRD §10)
    ↓
CardRepository + StudyQueue + FSRSScheduler
    ↓
VoiceSessionEngine (protocol)
    ├── SpeechVoiceEngine     SFSpeechRecognizer (on-device only) + AVAudioEngine tap + AVSpeechSynthesizer
    └── MockVoiceEngine       deterministic engine used by unit tests
    ↓
SQLite persistence (decks, notes, cards, review logs)
```

Key components:

| Component | Role |
|---|---|
| `FSRSScheduler` | FSRS-6 scheduling: 21 parameters, learning/relearning steps, short-term stability, interval fuzzing |
| `StudySessionController` | The review state machine; voice commands and touch controls drive identical transitions |
| `StudyQueue` | Next-card selection with daily new/review limits (4 AM study-day boundary) |
| `SpeechRenderer` | HTML/cloze card content → speakable text with pauses and per-side locales |
| `CommandRecognizer` | Deterministic Again/Hard/Good/Easy + control commands with a small alias table — no LLM |
| `SpeechVoiceEngine` | Half-duplex audio: mic feeding pauses while TTS speaks, so the app never hears itself; silence-based end-of-answer detection |
| `TextToSpeech` | Voice selection per language: honours the user's chosen voice, otherwise picks the best installed iOS tier (Premium → Enhanced → Compact) and never auto-selects novelty or Supertonic voices. An explicit Supertonic 3 pick synthesizes on device via FluidAudio's CoreML port |
| `ApkgImporter` | Anki `.apkg` / legacy `.colpkg` import: hierarchy, note types (incl. cloze), media, review history, FSRS state, guid dedup |
| `ApkgExporter` | Anki `.apkg` (one deck) and `.colpkg` (whole collection) export in the legacy `collection.anki2` format, with optional scheduling/`revlog` and media |
| `AnkiWebClient` | Shared-deck search, deck info and download via AnkiWeb's `/svc/shared` protobuf service; optional AnkiWeb sign-in to lift the visitor download cap |
| `AnkiConnectClient` / `AnkiConnectImporter` | Pull decks (cards, notes, note types, media, review history) straight from Anki desktop over the local network via the AnkiConnect add-on |
| `ExportService` | CSV export (with or without progress) + AnkiVoice-specific full backup |

## Getting decks in

The `+` button on the deck list opens one **Add Deck** page with two primary actions and a name field for an empty deck:

- **Browse shared decks** — AnkiWeb search in-app (or paste an `ankiweb.net/shared/info/…` link). Each deck page shows stats, tags, the description and swipeable **preview cards**: tap to flip, tap the speaker to hear the card read with your installed voices in its detected language. The preview picks the real prompt field of each sample note (index numbers, IDs and media filenames are skipped). AnkiWeb caps anonymous searches *and* downloads; the app names the limit it hit and offers sign-in (credentials kept in the Keychain).
- **Import a file** — any `.apkg` or legacy `.colpkg` from Files, AirDrop or the share sheet, or a CSV/TSV. Large packages import in batches with live progress; the archive is memory-mapped and inflated in a stream so a 500 MB media deck doesn't need 500 MB of RAM.
- **More ways** (collapsed) — pull decks from Anki desktop over Wi‑Fi via [AnkiConnect](https://ankiweb.net/shared/info/2055492159) (set its `webBindAddress` to `0.0.0.0`), or paste text. Review history is replayed through FSRS so scheduling carries over.

## Getting decks out

- **Deck → ⋯ → Export Anki package** writes an `.apkg` with cards, media and review history (the same “include scheduling information” option as Anki). **Cards only** strips due dates and `revlog` so you can share a clean deck. CSV is still available for spreadsheets.
- **Settings → Export collection for Anki** writes a `.colpkg` of everything. Anki treats that as a full collection (import *replaces* the destination); this app still *merges* on import, matching `.apkg`.
- Packages use the legacy `collection.anki2` format so Anki desktop, AnkiMobile, AnkiDroid and this app can all read them. Modern zstd `.colpkg` files from recent Anki still cannot be imported here — re-export from Anki with “support older Anki versions”.

## Voices

Settings → Voices lists every installed iOS voice for a language, grouped Premium / Enhanced / Built-in, plus **Supertonic 3** — ten on-device neural speakers (Female 1–5, Male 1–5) that work in 31 languages. **Tap a voice to select it** (the play button only previews); the choice is saved per language and used by every deck that doesn't override it. *Automatic* always uses the most natural **installed iOS** voice — Premium, then Enhanced, then the built-in compact voice; novelty voices and Supertonic are never auto-selected. The first time you preview or use a Supertonic voice, the app downloads the CoreML model (~400 MB) from Hugging Face; after that, synthesis stays on this iPhone.

**Siri voices cannot be used by third-party apps** — Apple only exposes them to Siri, so they never appear in the list. The natural iOS voices apps *can* use are downloaded in iOS Settings → Accessibility → Read & Speak (Spoken Content on iOS 17/18) → Voices → pick a language → download a Premium or Enhanced voice (Ava, Zoe, Evan… — not the "Siri" entries). The in-app guide walks through this; the app notices new voices as soon as you return.

Implementation note: `SettingsStore` is `@Observable` but every property is computed over `UserDefaults`, which the macro can't track. Each accessor goes through `access(keyPath:)` / `withMutation(keyPath:)` by hand — without that, SwiftUI never re-rendered after a setting changed, which is what made voice selection look broken (the pick was saved, the UI kept showing the old voice). `VoiceSelectionUITests` guards this.

## Voice loop

1. App speaks the card front (`speakingPrompt`)
2. Listens for your answer using voice-activity detection — your answer is **never transcribed or stored** (`awaitingAnswer` → `answerInProgress`)
3. ~0.5–0.9 s of silence ends your turn (`answerComplete`)
4. App speaks the answer (`speakingAnswer`)
5. Listens for a rating command (`awaitingRating`). If you say something that isn't a rating, the app tells you what it's waiting for ("Say again, hard, good, or easy") and listens again — the same goes for anything other than *resume*/*stop* while paused. Silence is never the answer to a command.
6. FSRS schedules the card; a brief tone (or "Good. Four days.") plays, then the next card starts automatically

Commands: *Repeat (question/answer), Reveal, Pause, Resume, Undo, Skip, Stop* — all state-gated (a "Hard" while answering is treated as answer content, not a rating). A spoken *stop* is acknowledged ("Session ended"); tapping **End** just closes the screen.

## Privacy

Raw microphone audio is never retained. Spoken answers are detected by voice activity only. Command transcripts are ephemeral. All content, review history, and inference stay on device.

Speech recognition runs with `requiresOnDeviceRecognition = true`, so audio is never sent to Apple's servers. iOS installs the on-device model for a language when Dictation is enabled for it (Settings → General → Keyboard → Dictation); if it isn't installed, the session runs touch-only and the app says how to fix it.

## Diagnostics

Settings holds the full backup, **Voice setup** (speech-model and voice status for the command language) and **Copy diagnostic report**: build, device, recognizer status, installed voices, audio route and any MetricKit crash/hang payloads collected from previous runs.

## Status / limitations

- Locked-screen sessions rely on `playAndRecord` + background audio; validated in code and simulator, but real-device/AirPods behavior must be tested on hardware before beta.
- Swift 6 language mode: closures handed to Objective-C callbacks that fire off the main thread (`SFSpeechRecognizer.requestAuthorization`, `recognitionTask(with:resultHandler:)`, `installTap`) must be `@Sendable`, otherwise they inherit `@MainActor` isolation and trap at runtime.
- Zstd-compressed `.colpkg` full backups from recent Anki are not importable. Re-export with “support older Anki versions”, or use the `.apkg` / `.colpkg` this app writes (legacy `collection.anki2`).
- Semantic answer grading is intentionally absent; the scheduler and command paths are fully deterministic by design.
