# Kikimimi for Mac

[![build](https://github.com/tokoinx/Kikimimi/actions/workflows/build.yml/badge.svg)](https://github.com/tokoinx/Kikimimi/actions/workflows/build.yml)

**Speech-to-text that never leaves your Mac.** Kikimimi turns meetings, interviews and video soundtracks into timestamped text.

[日本語 README](README.md)

A native Mac app written in Swift / SwiftUI. Recognition runs on **whisper.cpp** (a C/C++ implementation of OpenAI Whisper); the auditor and the translator run on **llama.cpp** with a small free LLM (**Qwen3.5**). Both use the Apple Silicon GPU via Metal.
Neither your audio nor the transcript leaves your Mac. The only network access is the one-time model downloads.

- Drop audio or video files (mp3 / m4a / wav / aiff / caf / mp4 / mov …) to get a timestamped transcript
- Finder's "Open With" and drops on the Dock icon work too
- Text appears sentence by sentence while it is being recognized, and any job can be cancelled
- Microphone recording, with a live preview of the last few seconds while you record; the full recording is transcribed carefully when you stop
- Click a line to play from that point; search highlights matches
- **Auditor**: after transcription, a reviewer looks for repeated sentences and misheard words. Only confident corrections are applied; the rest are kept as suggestions. Every change can be reviewed and undone
- **English → Japanese translation**: the original on the left, the Japanese translation on the right (Chinese, Korean and others can be translated to Japanese too)
- Export to txt / srt / vtt / Markdown / csv / json (original, Japanese, or both side by side)
- Japanese, English, Chinese, Korean and more, with automatic language detection
- **日本語＋英語 (Japanese + English)**: for recordings that switch between Japanese and English, such as an English lecturer with a Japanese interpreter. Each stretch of speech gets its own language and is transcribed in it; lines are tagged 英 or 日 and only the English lines are translated (about twice the time of the Japanese setting)

## Requirements

- macOS 14 Sonoma or later. Apple Silicon recommended (Intel Macs work on the CPU, more slowly)
- Xcode 16 or later, or the Command Line Tools (`xcode-select --install`)
- About 1 GB of free disk space (the recommended speech model is about 574 MB), plus about 3 GB for the auditor and translator (the recommended LLM is about 2.7 GB)
- 8 GB of memory or more (16 GB or more for the 9B LLM)

## Build and run

```bash
git clone https://github.com/tokoinx/Kikimimi.git
cd Kikimimi
make run
```

`make run` does the following:

1. `swift build -c release` (the first build downloads the prebuilt whisper.cpp and llama.cpp frameworks, about 54 MB + 65 MB, from GitHub)
2. Assembles `build/Kikimimi.app` and embeds whisper.framework and llama.framework
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

To use the auditor and the translator, download the LLM once: click "ダウンロード" (Download) on the start screen or the result screen, or use the "監査・翻訳" (Audit & translation) tab in Settings (⌘,). After that, every finished transcript is audited automatically, and English (or other non-Japanese) segments are translated into Japanese.

## Audit and translation (local LLM)

A small LLM running on your Mac reads the transcript once more.

- **Auditor (repetition and mishearing)**
  - Rules: finds a line that repeats the previous one exactly, almost exactly, or in part. Only a longish line repeated word for word, punctuation included, with no gap (the same audio read twice) is deleted automatically. Repeats after a pause (greetings from several people, language drills), self-corrections ("on Monday" → "on Tuesday") and echo questions ("…Thursday." / "…Thursday?") are only suggested, and lines whose numbers differ count as different lines.
  - LLM: finds clear mishearings in context (a similar-sounding wrong word, a mangled proper noun) and lines that were never spoken (such as "Thank you for watching." over silence or music).
  - How fixes are made: the LLM never rewrites a line. It answers only "misheard words => correct words", and just those words are replaced in the original line (a suggestion whose words are not in the line is ignored). The answer is constrained by a grammar to "only the problem lines, each once, in line order, then END", so it cannot run away repeating itself.
  - **Evaluator**: every fix the LLM proposes is checked again by asking which version, before or after, is what was actually said, twice with the order swapped. It is applied automatically only if the corrected version wins both times; a split vote leaves it as a suggestion, and losing both times discards it (this cancels small models' habit of favouring the first option, for example).
  - Guardrails: on top of that, a fix is applied automatically only when it changes little, keeps the language (it is not a translation) and is not merely adding or dropping words (particles, endings). Fixes that change a number ("3 o'clock" → "5 o'clock"), flip a negation (can't → can) or add kanji are always left as suggestions: the LLM never hears the audio, so these are guesses. English words are matched on word boundaries (fixing "can" never touches "scan"). A deletion is automatic only when a similar line nearby stays. If an answer wants to change nearly half of the lines it reviewed, it is treated as a rewrite and every change becomes a suggestion. Stock phrases such as "Thanks for watching" are only suggested for deletion, since people do say them.
  - Re-running the audit keeps the changes you applied or undid. If you cancel, or the LLM cannot be used, the rule-based review and the chunks finished so far are still applied.
  - Open the list from "監査: 修正 3 · 削除 2 · 提案 1" (Audit: fixed / deleted / suggestions) on the result screen to apply or undo each change. The badge next to a line shows the same details.
- **Translator (into Japanese)**
  - Non-Japanese segments are translated sentence by sentence. Whisper often cuts a sentence across several segments, and translating segment by segment lets Japanese word order push meaning onto the neighbouring segment (we saw this with the real Qwen3.5 4B). So consecutive segments up to the end of a sentence are joined into one line, and that translation spans those rows in the right column. Lines are translated a few at a time, with line numbers and count constrained by a llama.cpp grammar (GBNF); lines that could not be read are retried one at a time.
  - Qwen sometimes drifts into Chinese, so a short Japanese example exchange is shown first, and kanji that never appear in Japanese (simplified forms and the like) are removed from the output candidates.
  - The original is on the left and the Japanese translation on the right; segments that were already Japanese appear dimmed on the right. Toggle this with the "対訳" (Bilingual) checkbox.
  - Names in the "Vocabulary hint" setting are also used by the auditor and the translator.
- You can run them by hand too: audit ⇧⌘K, translate ⇧⌘T (or the buttons on the result screen).

| LLM | Best for | Size | Memory |
|---|---|---|---|
| Qwen3.5 4B | The balanced default | about 2.7 GB | 8 GB or more |
| Qwen3.5 2B (light) | Speed first; less accurate | about 1.3 GB | 8 GB or more |
| Qwen3.5 9B (accurate) | The smartest, and the slowest | about 5.7 GB | 16 GB or more |

- All are free Apache-2.0 models. The Q4_K_M GGUF is fetched from Hugging Face and saved to `~/Library/Application Support/Kikimimi/Models/LLM` as `qwen3.5-4b.gguf` (`qwen3.5-2b.gguf` for 2B, `qwen3.5-9b.gguf` for 9B). It is downloaded to a temporary file first and moved into that folder only after the download finishes and passes a check, so the file does not appear there until then. The check confirms that the file is a GGUF and that its size and SHA-256 match Hugging Face's file list (if that list cannot be fetched, only that it is a GGUF). "LLM のフォルダを開く" (Open the LLM folder) in Settings shows the folder in Finder.
- Quitting the app during a download cancels it, and the next download starts over from the beginning (closing the Settings window does not stop it).
- Any GGUF that llama.cpp can run can be added with "手元の GGUF を追加…" (Add a local GGUF) in Settings.
- Rough timing: for a one-hour English talk on an M1, the audit takes a few minutes and the translation 10–20 minutes with the 4B model (translations appear on the right as they are produced). Pick the 2B model when you are in a hurry.
- On Macs with less than 12 GB of memory, the speech model and the LLM are loaded in turn so they never use memory at the same time.
- A small LLM is not as smart as a large cloud model. That is why the auditor applies only confident changes automatically and leaves the rest as suggestions; check the suggestions before you rely on an important transcript.

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
- **Remove common hallucinations and runaway repetition**: drops stock phrases Whisper tends to produce on silence or music, such as "ご視聴ありがとうございました" (Thanks for watching), but only when the segment is likely not speech. When the same line repeats back to back 4 or more times (or a group of 2–3 lines cycles 3 or more times), only the first occurrence is kept, and a phrase repeated 6 or more times within one line is collapsed to one. The same words spoken minutes apart, emphasis such as "No, no, no, no, no.", and amounts or numbers are kept.
- **Vocabulary hint**: list proper nouns or jargon (for example: Roblox Studio) so they come out spelled that way. The auditor and the translator use it too.
- **Audit & translation (local LLM)**: on the "監査・翻訳" tab, choose whether to audit automatically after each transcription, whether to translate non-Japanese segments automatically, and which LLM to use. Download, delete and import LLMs here as well.

## Troubleshooting

- **The model download fails**: the app needs to reach Hugging Face (huggingface.co). If it is blocked on your network, get these files elsewhere and add them with "手元のファイルを追加…" (Add a local file) in Settings:
  - Speech model: `ggml-large-v3-turbo-q5_0.bin` (huggingface.co/ggerganov/whisper.cpp)
  - VAD model: `ggml-silero-v6.2.0.bin` (huggingface.co/ggml-org/whisper-vad). Optional; if it cannot be downloaded, the app retries every 10 minutes.
- **The LLM download fails**: like the speech models, it needs Hugging Face. If it is blocked, get a Qwen3.5 GGUF elsewhere (for example `Qwen3.5-4B-Q4_K_M.gguf` from huggingface.co/unsloth/Qwen3.5-4B-GGUF) and add it with "手元の GGUF を追加…" in Settings.
- **Translation is slow or the Mac gets sluggish**: switch the LLM to "Qwen3.5 2B" in Settings. You can stop a translation at any time; what was translated is kept, and "残りを翻訳" (Translate the rest) continues from there.
- **You disagree with a correction**: uncheck it in the "監査: …" list to undo it, or use "すべて元に戻す" (Undo all).
- **`make run` says whisper.framework or llama.framework is missing**: run the following, then `make run` again.

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
| Audit and translation logic (rules, guardrails, line alignment, apply/undo, exports) | Unit tests (with a fake LLM) |
| llama.cpp b12211 usage (grammar-constrained generation, cut-offs, cancellation, neutralized control tokens, Japanese UTF-8) | Checked against the real llama.cpp (Linux build) with a tiny random-weight GGUF |
| whisper.framework and llama.framework in one app | GitHub Actions runs the built app's `--selftest-llm` on every push |
| Audit and translation with the real Qwen3.5 2B / 4B (English and Japanese samples, sentences cut across segments, mishearings, repeats) | Verified on a Linux CPU (4B: 7 lines translated in 26 s, audit in 18 s). Found and fixed drift into Chinese and wrong auto-fixes along the way |
| Qwen3.5 speed on a Mac (Metal), and auditing/translating a long (1-hour) recording | Not verified yet (awaiting a run on real hardware) |

## Tests

The parts that do not depend on the UI (export, model catalog, WAV, hallucination filter, auditor, translator) live in `KikimimiCore` and are unit tested:

```bash
swift test
```

There is also a transcription diagnostic in the built app (no window opens). It prints the language found for each chunk, the stretches transcribed in one go, what the checks flagged and what was re-transcribed, each line's language, the time taken and the memory used. Without `--model` / `--vad` it uses the models downloaded in the app. `--from` / `--to` (seconds) cut out a part, `--languages ja` uses the Japanese setting, and `--report` writes the result as JSON.

```bash
build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-whisper ~/Downloads/lecture.mp3 --languages ja,en --from 120 --to 240 --report ~/Desktop/kikimimi-report.json
```

There is also a diagnostic that exercises the LLM inside the built app (no window opens). It translates and audits sample lines with the downloaded LLM and prints the timings. With `--strict` it also checks that every translation is Japanese and that the mishearing (Roblocks → Roblox) gets fixed; add `--cpu` to stay off the GPU.

```bash
build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-llm ~/Library/Application\ Support/Kikimimi/Models/LLM/qwen3.5-4b.gguf --strict
```

## Layout

```
Package.swift            Dependencies: the official whisper.cpp v1.9.2 and llama.cpp b12211 XCFrameworks (checksums pinned)
Sources/
  KikimimiCore/          Platform-independent core
    Transcript.swift     Segments, results, time formatting
    Exporter.swift       txt / srt / vtt / md / csv / json
    ModelCatalog.swift   Model list, download URLs, model file validation
    HallucinationFilter.swift  Removes common hallucinations
    WAV.swift            Saves recordings (16-bit PCM)
    LLM/                 Auditor and translator (the LLM-independent parts)
      Auditor.swift      Repetition rules, reading the LLM's findings, guardrails
      AuditReport.swift  Audit results, apply and undo
      Translator.swift   Translation a few lines at a time, retries
      Grammar.swift      GBNF grammars that constrain the output
      LLMCatalog.swift   LLM list and how to pick the file to download
      TextAnalysis.swift Similarity, "is this Japanese?"
    MixedLanguage/       日本語＋英語 (the whisper-independent parts)
      SpeechMap.swift    Speech spans and the chunks whose language is detected
      LanguagePlanner.swift  Deciding each chunk's language and the stretches transcribed in one go
      SwitchSearch.swift Splitting mixed chunks and finding switches with no pause
      DecodeCheck.swift  Checks on the transcribed text, vocabulary hint per language
      MixedPipeline.swift  The whole flow (detect, transcribe, check and repair)
  KikimimiWhisper/       Thin layer over the whisper.cpp C API
    WhisperContext.swift Inference, progress, per-segment callbacks, cancellation, VAD and language detection
    MixedTranscription.swift  Connects whisper to the 日本語＋英語 flow
    ModelStore.swift     Model location, import, delete
    ModelDownloader.swift Download with progress (validated before it is moved into place)
    LLMModelStore.swift  LLM location and import, reading the Hugging Face file list, SHA-256 check
  KikimimiLLM/           Thin layer over the llama.cpp C API
    LlamaEngine.swift    Loading, chat templates, grammar-constrained greedy generation, cancellation
  Kikimimi/              The macOS app (SwiftUI + AVFoundation)
    AppModel.swift       State, job queue, settings
    TranscriptionService.swift  Dedicated inference thread, model reuse
    LLMService.swift     Dedicated LLM thread, model reuse
    LLMSelfTest.swift    --selftest-llm (diagnostics and CI)
    WhisperSelfTest.swift  --selftest-whisper (diagnostics and CI)
    AudioDecoder.swift   Audio/video to 16 kHz mono
    LiveRecorder.swift   Microphone recording
    PlayerController.swift  Playback and seeking
    Views/               UI
Resources/               Info.plist, icon
Scripts/build-app.sh     Assembles the .app
Scripts/make-tiny-gguf.py  Makes a tiny GGUF for smoke tests (CI)
Tests/Fixtures/          A short English/Japanese recording (for --selftest-whisper in CI)
```

## Design notes

- **Why whisper.cpp**: it runs on macOS 14, is fast on Metal, and ships an official prebuilt XCFramework, so there is no C/C++ build step. Accuracy matches OpenAI Whisper because it uses the same models.
- **SpeechAnalyzer on macOS 26** is a future option; the engine is isolated so it can be swapped in.
- **Long audio and runaway repetition**: Whisper works in 30-second windows. By default whisper.cpp feeds the text recognized in the previous window to the next one as context; `no_context` does not stop that (it only discards context from a previous call). Kikimimi sets `n_max_text_ctx = 0`, which matches OpenAI's `condition_on_previous_text=False`. A vocabulary hint is attached to every window with `carry_initial_prompt`, with `n_max_text_ctx` limited to the hint's token count + 1 so no previous text gets in. When a window does fall into repetition, the retry picks the best of 5 candidates even in beam search (`greedy.best_of = 5`, as whisper-cli does; the default would sample just one). The repetition threshold (`entropy_thold`) stays at the default 2.4: raising it made normal speech retry more often, slowed things down, and in our reproduction turned easy-to-collapse repeated lines over music into varied hallucinations. Anything left over is cleaned up afterwards.
- **Why a local LLM for auditing and translation**: it is free, keeps the transcript on your Mac and works offline. llama.cpp is fast on Metal and ships an official prebuilt XCFramework. To keep a small model's output well-formed, it is constrained with a GBNF grammar down to the line numbers and the line count, and a line that grows too long is cut off (a guard against runaway repetition). Tokens are chosen greedily, so the same input always gives the same answer.
- **whisper.cpp and llama.cpp side by side**: the two frameworks each embed a different version of ggml.h. Putting both C modules into one Swift compilation makes their type definitions clash, so each C module is used only inside its wrapper (`internal import`), and the wrappers and KikimimiCore are built with library evolution so the app target never imports them. The overlapping symbols were checked as well; the two libraries never call into each other.
- **日本語＋英語 (Japanese + English)**: whisper transcribes 30 seconds at a time under one language token (`<|ja|>` and so on). VAD squeezes pauses to 0.1 s, so in a recording that switches between English and Japanese one 30-second window holds both. Hearing English under the Japanese token loops into 「彼は、彼は、…」, and the clean-up pass shortens that to the single broken Japanese line left inside the English (reproduced on English and Japanese read in turns, with a 25% error rate). Automatic detection does not help either: it decides once, on the first 30 seconds. With 日本語＋英語 the speech found by VAD is packed into chunks of 28 s or less, and whisper's language detection compares Japanese and English only for each chunk (without that restriction, short clips come out as Chinese or Korean). A chunk with an unsure result is split at its long pauses and detected again, and a switch with no pause is found by bisecting with 4 s and 2 s windows. Neighbouring chunks of the same language are joined (up to 10 minutes) and transcribed in that language with the same settings as the Japanese setting. The result gets cheap checks: repetition, low confidence, an amount of text that does not fit the speaking time, and speech with no text. A flagged region is detected again; if it is the other language, it is transcribed in that language and replaced only when the result is better (if it is the same language, the text stays: the checks never delete text). The thresholds were measured on English and Japanese read speech (FLEURS) and on a Japanese talk.
- **Signing**: ad-hoc. To distribute the app, sign it with a Developer ID and notarize it.

## Known limitations

- No speaker diarization. 日本語＋英語 splits by the language being spoken, not by voice.
- Even with 日本語＋英語, about 1.5 s around a switch with no pause can be lost, and insertions shorter than about 3 s (backchannels) may come out in the surrounding language or be dropped.
- Automatic detection decides the language once, from the first 30 seconds, so use 日本語＋英語 for recordings that switch languages.
- Translation goes one way only: into Japanese.
- The recording preview covers only the last 12 seconds (the whole recording is transcribed again when you stop).

## License

MIT License ([LICENSE](LICENSE)).

Downloaded at build time or at run time (not included in this repository):

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.2 XCFramework (MIT): downloaded from GitHub at build time
- Whisper models (MIT, OpenAI) converted for whisper.cpp: downloaded from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) on first use
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) converted for whisper.cpp: likewise ([ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad))

Included in this repository for the tests:

- `Tests/Fixtures/mixed-en-ja.wav`: English and Japanese read speech from [FLEURS](https://huggingface.co/datasets/google/fleurs) (Google, CC BY 4.0), joined. See [Tests/Fixtures/README.md](Tests/Fixtures/README.md)
- [llama.cpp](https://github.com/ggml-org/llama.cpp) b12211 XCFramework (MIT): downloaded from GitHub at build time
- [Qwen3.5](https://huggingface.co/Qwen) (Apache-2.0) GGUF: downloaded from Hugging Face when you use the auditor or translator (quantized by [unsloth](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) / [bartowski](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF))
