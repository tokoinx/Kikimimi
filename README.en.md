# Kikimimi for Mac

[![build](https://github.com/tokoinx/Kikimimi/actions/workflows/build.yml/badge.svg)](https://github.com/tokoinx/Kikimimi/actions/workflows/build.yml)

**Speech-to-text that never leaves your Mac.** Kikimimi turns meetings, interviews and video soundtracks into timestamped text.

[日本語 README](README.md)

A native Mac app written in Swift / SwiftUI. Recognition runs on **whisper.cpp** (a C/C++ implementation of OpenAI Whisper) on the Apple Silicon GPU via Metal.
Your audio stays on your Mac. The only network access is the one-time model download.

- Drop audio or video files (mp3 / m4a / wav / aiff / caf / mp4 / mov …) to get a timestamped transcript
- Finder's "Open With" and drops on the Dock icon work too
- Text appears sentence by sentence while it is being recognized, and any job can be cancelled
- Microphone recording, with a live preview of the last few seconds while you record; the full recording is transcribed carefully when you stop
- Click a line to play from that point; search highlights matches
- Export to txt / srt / vtt / Markdown / csv / json
- Japanese, English, Chinese, Korean and more, with automatic language detection

## Requirements

- macOS 14 Sonoma or later. Apple Silicon recommended (Intel Macs work on the CPU, more slowly)
- Xcode 16 or later, or the Command Line Tools (`xcode-select --install`)
- About 1 GB of free disk space (the recommended model is about 574 MB)

## Build and run

```bash
git clone https://github.com/tokoinx/Kikimimi.git
cd Kikimimi
make run
```

`make run` does the following:

1. `swift build -c release` (the first build downloads the prebuilt whisper.cpp framework, about 54 MB, from GitHub)
2. Assembles `build/Kikimimi.app` and embeds whisper.framework
3. Ad-hoc signs the app
4. Launches it (if Kikimimi is already running, it quits that copy first)

To install into `/Applications`:

```bash
make install
```

### First run

1. Click "モデルをダウンロード" (Download model). The recommended **Large v3 Turbo (quantized)** is about 574 MB; after that, everything works offline.
2. Drop an audio file on the window, or open one with ⌘O.
3. Recognized text appears on the right as it is produced. Export it with "書き出す" (Export) when it is done.

Recording (⌘R) asks for microphone permission the first time.

## Choosing a model

| Model | Best for | Size |
|---|---|---|
| Large v3 Turbo (quantized) | Japanese meetings and interviews. The default choice | about 574 MB |
| Large v3 Turbo | Slightly more accurate than the quantized one | about 1.6 GB |
| Large v3 (quantized) | Top accuracy, several times slower than Turbo | about 1.1 GB |
| Medium / Small / Base / Tiny | Speed, or a quick smoke test | 60–540 MB |

Models are stored in `~/Library/Application Support/Kikimimi/Models`. Download, delete or reveal them from Settings (⌘,).

## Settings (⌘,)

- **Prefer accuracy**: uses beam search. Turn it off for faster results.
- **Skip silence (VAD)**: skips silent parts, which is faster and avoids hallucinations on silence (downloads a 0.9 MB VAD model automatically).
- **Remove common hallucinations and runaway repetition**: drops stock phrases Whisper tends to produce on silence or music, such as "ご視聴ありがとうございました" (Thanks for watching), but only when the segment is likely not speech. When the same line repeats 4 or more times in a row (or a group of 2–3 lines cycles 3 or more times), only the first occurrence is kept, and a phrase repeated 4 or more times within one line is collapsed to one.
- **Vocabulary hint**: list proper nouns or jargon (for example: Roblox Studio) so they come out spelled that way.

## Troubleshooting

- **The model download fails**: the app needs to reach Hugging Face (huggingface.co). If it is blocked on your network, get these files elsewhere and add them with "手元のファイルを追加…" (Add a local file) in Settings:
  - Speech model: `ggml-large-v3-turbo-q5_0.bin` (huggingface.co/ggerganov/whisper.cpp)
  - VAD model: `ggml-silero-v6.2.0.bin` (huggingface.co/ggml-org/whisper-vad). Optional; if it cannot be downloaded, the app retries every 10 minutes.
- **`make run` says whisper.framework is missing**: run the following, then `make run` again.

  ```bash
  swift package reset
  ```

- **No microphone prompt, or you denied it**: turn Kikimimi on in System Settings › Privacy & Security › Microphone. After a rebuild changes the signature, reset the permission and relaunch:

  ```bash
  tccutil reset Microphone local.kikimimi.app
  ```

- **You connected AirPods or switched the input while recording**: recording continues on the new input. If it cannot, the audio captured so far is transcribed.
- **The same sentence repeats over and over (a bug in 1.0.0)**: 1.0.0 passed the text recognized in each 30-second window to the next window as context, so a single misrecognition on music or noise propagated through every later window. Fixed in 1.0.1. Re-transcribe files processed with 1.0.0 to recover the lost parts.
- **webm / mkv / ogg will not open**: AVFoundation does not support them. Convert to m4a / mp4 with QuickTime Player or ffmpeg first.
- **"Cannot verify the developer" on launch**: apps you build yourself normally do not show this. If it appears, right-click the app in Finder and choose Open.

## Verification

| Item | Status |
|---|---|
| Built on real hardware (Apple Silicon, macOS 14.8.3) and used for transcription | Verified |
| Build and tests on macOS 15 with Xcode 16.2 (Swift 6.0) and Xcode 26.3 | Checked by GitHub Actions on every push |
| Switching the input device while recording (connecting AirPods, etc.) | Not verified (implemented only) |
| Finder "Open With" / dropping on the Dock icon | Not verified (implemented only) |
| Intel Macs | Not verified |
| Fix for the same sentence repeating through long recordings (1.0.1) | Verified in a reproduction (tiny model, 5 minutes of audio with music in between). Awaiting a re-check on the real lecture recording |

## Tests

The parts that do not depend on the UI (export, model catalog, WAV, hallucination filter) live in `KikimimiCore` and are unit tested:

```bash
swift test
```

## Layout

```
Package.swift            Dependency: the official whisper.cpp v1.9.2 XCFramework (checksum pinned)
Sources/
  KikimimiCore/          Platform-independent core
    Transcript.swift     Segments, results, time formatting
    Exporter.swift       txt / srt / vtt / md / csv / json
    ModelCatalog.swift   Model list, download URLs, model file validation
    HallucinationFilter.swift  Removes common hallucinations
    WAV.swift            Saves recordings (16-bit PCM)
  KikimimiWhisper/       Thin layer over the whisper.cpp C API
    WhisperContext.swift Inference, progress, per-segment callbacks, cancellation
    ModelStore.swift     Model location, import, delete
    ModelDownloader.swift Download with progress (validated before it is moved into place)
  Kikimimi/              The macOS app (SwiftUI + AVFoundation)
    AppModel.swift       State, job queue, settings
    TranscriptionService.swift  Dedicated inference thread, model reuse
    AudioDecoder.swift   Audio/video to 16 kHz mono
    LiveRecorder.swift   Microphone recording
    PlayerController.swift  Playback and seeking
    Views/               UI
Resources/               Info.plist, icon
Scripts/build-app.sh     Assembles the .app
```

## Design notes

- **Why whisper.cpp**: it runs on macOS 14, is fast on Metal, and ships an official prebuilt XCFramework, so there is no C/C++ build step. Accuracy matches OpenAI Whisper because it uses the same models.
- **SpeechAnalyzer on macOS 26** is a future option; the engine is isolated so it can be swapped in.
- **Long audio and runaway repetition**: Whisper works in 30-second windows. By default whisper.cpp feeds the text recognized in the previous window to the next one as context; `no_context` does not stop that (it only discards context from a previous call). Kikimimi sets `n_max_text_ctx = 0`, which matches OpenAI's `condition_on_previous_text=False`. A vocabulary hint is attached to every window with `carry_initial_prompt`, with `n_max_text_ctx` limited to the hint's token count + 1 so no previous text gets in. Repetition inside a window is caught by raising the repetition threshold (`entropy_thold`) from 2.4 to 2.8, and anything left over is cleaned up afterwards.
- **Signing**: ad-hoc. To distribute the app, sign it with a Developer ID and notarize it.

## Known limitations

- No speaker diarization.
- The recording preview covers only the last 12 seconds (the whole recording is transcribed again when you stop).

## License

MIT License ([LICENSE](LICENSE)).

Downloaded at build time or at run time (not included in this repository):

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.2 XCFramework (MIT): downloaded from GitHub at build time
- Whisper models (MIT, OpenAI) converted for whisper.cpp: downloaded from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) on first use
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) converted for whisper.cpp: likewise ([ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad))
