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
- **日本語＋英語 (Japanese + English)**: for recordings that switch between Japanese and English, such as an English lecturer with a Japanese interpreter. Each stretch of speech gets its own language and is transcribed in it; lines are tagged 英 or 日 and only the English lines are translated (it takes about 2–4× the time of the Japanese setting: longer the more often the language changes or short remarks cut in)

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
4. Launches it (if Kikimimi is already running, it quits that copy first, then checks a few seconds later that the new one is running; if it is not, it collects the cause into `build/doctor.txt`)

Start the app with `make run`. A bare `open build/Kikimimi.app` does not start the new build while an older copy is still running.

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

## Learned corrections, the evaluation harness, and fine-tuning

A small LLM is not dependable on its own. Kikimimi surrounds it with a harness that remembers, checks and measures. Fine-tuning is an optional layer on top of that.

### Learned corrections (memory)

- When you **apply** or **undo** a fix in the audit list, Kikimimi remembers that decision as "misheard term → right term". The "学習した直し" (Learned corrections) section of the "監査・翻訳" tab in Settings lists them, and lets you delete them or add your own.
- Fixes you applied are made before the LLM is asked, from the next audit on (they are listed as "学習した直し", so you can still undo them). Fixes you undid are not used again, even when the LLM proposes them. The right terms are also added to the vocabulary hint for transcription and translation.
- A fix you applied only once comes back as a **suggestion**. After you apply it twice it is made **automatically** (so that a fix that was right for one line only, such as "break → brake" or "機関 → 期間", does not become a rule for every recording after a single click). Fixes that change a number or a negation, or turn kana into kanji, always stay suggestions and are confirmed line by line. Corrections you add yourself in Settings are always applied automatically (including case- or punctuation-only ones such as "T-pie → TPIE").
- A decision to undo a learned fix on one line is kept when that transcript is audited again.
- They are saved in `~/Library/Application Support/Kikimimi/learned-corrections.json` and never leave the Mac. This works without an LLM.

### Gates (machine checks)

The LLM's answers are checked by code before they are applied (the judge's second opinion and the guardrails are described above). Two more gates were added after measuring with the evaluation harness:

- A fix that writes a comment instead of words ("no error", "note: …", bracketed text, or text more than three times as long as the original term) is dropped.
- A suggested deletion is dropped unless the same sentence is nearby or the line is a stock hallucination (small models often call ordinary sentences "not spoken").

### Evaluation harness

This measures whether a change made things better. The LLM audits scenes with planted mishearings (which line is wrong, and what the right text is), and the harness counts the lines fixed, the lines missed, the **correct lines harmed** and the needless suggestions. The scenes are in `Tests/Fixtures/llm-eval/seed.json` (6 English and 6 Japanese scenes: 14 lines with an error, 36 correct lines), and you can add your own.

```bash
build/Kikimimi.app/Contents/MacOS/Kikimimi --eval-llm ~/Library/Application\ Support/Kikimimi/Models/LLM/qwen3.5-2b.gguf --set Tests/Fixtures/llm-eval/seed.json --report build/eval-2b.json
```

With `--baseline <earlier report.json>` the result is compared with an earlier one, and the command exits with code 3 if it is worse (more correct lines harmed, or fewer lines fixed). `--adapter <file.lora.gguf>` adds a fine-tuned adapter, `--ledger <ledger.json>` uses learned corrections, and `--rules-only` measures the rules without an LLM.

Measured with the real Qwen3.5 (Q4_K_M) on a Linux CPU (14 lines with an error):

| LLM | Fixed automatically | Found as a suggestion | Missed | Correct lines harmed | Needless suggestions |
|---|---|---|---|---|---|
| 2B (before the gates) | 3 | 4 | 7 | 0 | 13 |
| 2B (with the gates) | 4 | 3 | 7 | 0 | 1 |
| 4B | 5 | 2 | 7 | 0 | 3 |

- The gates cut the 2B model's needless suggestions from 13 to 1. No model harmed a correct line.
- The 7 missed lines are confusions between two real words, where only the context tells them apart (機会 / 機械, 公園 / 講演, 以上 / 異常, 保障 / 保証, break / brake, Their / They're). That is the limit of a small LLM; learned corrections and fine-tuning are there to cover it.

### Fine-tuning (LoRA)

Once you have collected enough learned corrections, you can teach them to the LLM itself. The LLM file is not changed: training makes a small adapter (a LoRA, tens of MB) that is applied on top of it. Training also runs entirely on the Mac.

1. "学習用のデータを書き出す…" (Export training data) on the "監査・翻訳" tab in Settings writes `kikimimi-training.jsonl`. It holds prompts in the same form the auditor and the judge really receive, with answers that follow your decisions (a fix you applied is "fix", a fix you undid is "leave it", a line nothing was said about is "unchanged").
2. Install the training tools (Apple silicon Mac; this uses Apple's MLX).

   ```bash
   python3 -m venv .venv-finetune
   ```

   ```bash
   .venv-finetune/bin/pip install "mlx-lm[train]" gguf numpy
   ```

3. Train. This trains, converts the result to GGUF, compares "without / with the adapter" with the evaluation harness, and installs the adapter only if it is not worse.

   ```bash
   .venv-finetune/bin/python tools/finetune/finetune.py --data ~/Desktop/kikimimi-training.jsonl --model qwen3.5-2b --install
   ```

4. The "追加学習 (LoRA)" (Fine-tuning) section of the "監査・翻訳" tab turns the adapter on or off; "外す" (Remove) goes back to the plain LLM. An adapter made elsewhere can be added with "差分を追加…" (Add adapter) (one that does not match the selected LLM's family or size is refused; if an adapter cannot be loaded, the app runs without it and says so).

Things to know:

- **Memory needed**: about 8 GB to train 2B, 16 GB for 4B, 32 GB for 9B. On an 8 GB Mac, use 2B (the script stops and says so when memory is short). The first run downloads the training copy of the model (MLX format, e.g. `mlx-community/Qwen3.5-2B-4bit`) from Hugging Face.
- **At least 12 training examples** are required. For a handful of corrections, learned corrections already do the job without training. Fine-tuning pays off once you have dozens of corrections and want them to carry over to similar cases.
- **An adapter belongs to the LLM it was trained on** (a 2B adapter does not work with 4B). Train again after switching LLMs.
- Only the MLP of each layer is trained (Qwen3.5 mixes attention with state-space blocks, and only the MLP weights map one to one between MLX and GGUF). `tools/finetune/mlx_lora_to_gguf.py` does the conversion.

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
- **Learned corrections / fine-tuning (LoRA)**: on the same tab, list, delete and add learned corrections, export training data, and add, remove or switch a fine-tuned adapter.

## Troubleshooting

- **The model download fails**: the app needs to reach Hugging Face (huggingface.co). If it is blocked on your network, get these files elsewhere and add them with "手元のファイルを追加…" (Add a local file) in Settings:
  - Speech model: `ggml-large-v3-turbo-q5_0.bin` (huggingface.co/ggerganov/whisper.cpp)
  - VAD model: `ggml-silero-v6.2.0.bin` (huggingface.co/ggml-org/whisper-vad). Optional; if it cannot be downloaded, the app retries every 10 minutes.
- **The LLM download fails**: like the speech models, it needs Hugging Face. If it is blocked, get a Qwen3.5 GGUF elsewhere (for example `Qwen3.5-4B-Q4_K_M.gguf` from huggingface.co/unsloth/Qwen3.5-4B-GGUF) and add it with "手元の GGUF を追加…" in Settings.
- **Translation is slow or the Mac gets sluggish**: switch the LLM to "Qwen3.5 2B" in Settings. You can stop a translation at any time; what was translated is kept, and "残りを翻訳" (Translate the rest) continues from there.
- **You disagree with a correction**: uncheck it in the "監査: …" list to undo it, or use "すべて元に戻す" (Undo all).
- **The app does not start, or no window appears**: run the following. It collects the environment, the assembled app, a launch check and recent crash reports into `build/doctor.txt` (a window appears and closes by itself after a few seconds). Report that file as is.

  ```bash
  make doctor
  ```

  While the app keeps running with its window closed (during a transcription or translation, or while a transcript has not been exported yet), click the Dock icon or choose File > メインウインドウを表示 (⌘0) to bring the window back. When nothing is in progress and every result has been exported (or copied), closing the window quits the app. Kikimimi does not save transcripts to disk, so quitting (⌘Q) with results that were never exported asks for confirmation first.
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
| 日本語＋英語: chunking, detection, switch search, checks and repairs | Unit tests (with a scripted fake whisper). 150 randomly generated recordings are also checked on every run for invariants: no crash, the decode ranges cover the whole audio without gaps, repairs stay within their limits |
| 日本語＋英語 with the real whisper (208 s of English and Japanese read in turns, Large v3 Turbo q5_0) | Verified on a Linux CPU: error rate 25.2% (Japanese setting) → 5.4%, all 8 language stretches in the right language, and both sides of the one switch with no pause (and of the two in a separate 54 s clip) came out in the right language. A Japanese-only talk (3.5 min) never switched to English and gave the same text as the Japanese setting |
| 日本語＋英語 on an English lecture with short Japanese remarks (1–3 s) cutting in, and similar (three 2.6–2.7 min recordings made from read speech, real whisper) | Verified on a Linux CPU. Six remarks: 3 with the Japanese setting, all 6 with 日本語＋英語 (error rate 12.9% → 5.1%). English and Japanese speakers taking turns: all 8 turns in the right language (error rate 6.8%). With crowd noise mixed in: 5 of the 6 remarks (error rate 10.0%) |
| 日本語＋英語 in the built app | GitHub Actions transcribes a 47 s English/Japanese recording with tiny and checks each line's language on every push |
| 日本語＋英語 speed on a Mac (Metal), and a 2-hour lecture | Not verified yet (awaiting a run on real hardware; measured without any cached results on a Linux CPU, it takes 2.4× the Japanese setting for a 3.5-minute Japanese-only talk and 3.9× for a 2.7-minute recording with a Japanese remark about every 30 s) |
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
      CorrectionLedger.swift  Learned corrections (remember, apply, block)
      LLMEval.swift      Evaluation harness (scenes and scoring)
      FineTuneData.swift Builds fine-tuning data from the ledger
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
    LLMModelStore.swift  LLM and adapter location and import, reading the Hugging Face file list, SHA-256 check
  KikimimiLLM/           Thin layer over the llama.cpp C API
    LlamaEngine.swift    Loading, LoRA adapters, chat templates, grammar-constrained greedy generation, cancellation
  Kikimimi/              The macOS app (SwiftUI + AVFoundation)
    AppModel.swift       State, job queue, settings
    TranscriptionService.swift  Dedicated inference thread, model reuse
    LLMService.swift     Dedicated LLM thread, model reuse
    LLMSelfTest.swift    --selftest-llm (diagnostics and CI)
    LLMEvalRunner.swift  --eval-llm (evaluation harness)
    TrainingExport.swift --export-training (fine-tuning data export)
    WhisperSelfTest.swift  --selftest-whisper (diagnostics and CI)
    LaunchSelfTest.swift --selftest-launch (launch and window check, for make doctor and CI)
    AudioDecoder.swift   Audio/video to 16 kHz mono
    LiveRecorder.swift   Microphone recording
    PlayerController.swift  Playback and seeking
    Views/               UI
Resources/               Info.plist, icon
Scripts/build-app.sh     Assembles the .app
Scripts/run-app.sh       Launch (make run): quits a running copy, opens the new one, checks it is alive
Scripts/doctor.sh        Diagnostics when the app does not launch (make doctor)
Scripts/make-tiny-gguf.py  Makes a tiny GGUF for smoke tests (CI)
tools/finetune/          Fine-tuning (LoRA)
  finetune.py            Train, convert, evaluate and install in one go (Mac, MLX)
  mlx_lora_to_gguf.py    Converts an MLX adapter to a GGUF that llama.cpp reads
  selftest/              Practice data for the end-to-end check (CI)
Tests/Fixtures/          A short English/Japanese recording (for --selftest-whisper in CI), evaluation scenes (llm-eval/)
```

## Design notes

- **Why whisper.cpp**: it runs on macOS 14, is fast on Metal, and ships an official prebuilt XCFramework, so there is no C/C++ build step. Accuracy matches OpenAI Whisper because it uses the same models.
- **SpeechAnalyzer on macOS 26** is a future option; the engine is isolated so it can be swapped in.
- **Long audio and runaway repetition**: Whisper works in 30-second windows. By default whisper.cpp feeds the text recognized in the previous window to the next one as context; `no_context` does not stop that (it only discards context from a previous call). Kikimimi sets `n_max_text_ctx = 0`, which matches OpenAI's `condition_on_previous_text=False`. A vocabulary hint is attached to every window with `carry_initial_prompt`, with `n_max_text_ctx` limited to the hint's token count + 1 so no previous text gets in. When a window does fall into repetition, the retry picks the best of 5 candidates even in beam search (`greedy.best_of = 5`, as whisper-cli does; the default would sample just one). The repetition threshold (`entropy_thold`) stays at the default 2.4: raising it made normal speech retry more often, slowed things down, and in our reproduction turned easy-to-collapse repeated lines over music into varied hallucinations. Anything left over is cleaned up afterwards.
- **Why a local LLM for auditing and translation**: it is free, keeps the transcript on your Mac and works offline. llama.cpp is fast on Metal and ships an official prebuilt XCFramework. To keep a small model's output well-formed, it is constrained with a GBNF grammar down to the line numbers and the line count, and a line that grows too long is cut off (a guard against runaway repetition). Tokens are chosen greedily, so the same input always gives the same answer.
- **whisper.cpp and llama.cpp side by side**: the two frameworks each embed a different version of ggml.h. Putting both C modules into one Swift compilation makes their type definitions clash, so each C module is used only inside its wrapper (`internal import`), and the wrappers and KikimimiCore are built with library evolution so the app target never imports them. The overlapping symbols were checked as well; the two libraries never call into each other.
- **日本語＋英語 (Japanese + English)**: whisper transcribes 30 seconds at a time under one language token (`<|ja|>` and so on). VAD squeezes pauses to 0.1 s, so in a recording that switches between English and Japanese one 30-second window holds both. Hearing English under the Japanese token loops into 「彼は、彼は、…」, and the clean-up pass shortens that to the single broken Japanese line left inside the English (reproduced on English and Japanese read in turns, with a 25% error rate). Automatic detection does not help either: it decides once, on the first 30 seconds. With 日本語＋英語 the speech found by VAD is packed into chunks of 28 s or less, and whisper's language detection compares Japanese and English only for each chunk (without that restriction, short clips come out as Chinese or Korean). A chunk with an unsure result is split at its long pauses and detected again, and a switch with no pause is found by bisecting with 4 s and 2 s windows (a window with less than 1 s of speech is widened until it holds 1 s, since detection on near-silence is unreliable). Even a confident chunk is halved step by step to look for a short stretch of the other language in its middle (an island) when its other-language probability is above what is usual for the file (5× the median of the English chunks): transcribed as English, a Japanese remark is skipped untranslated and leaves nothing for the checks to find. Noise that spreads over a whole chunk is told apart by comparing the end windows, or the first two halves, and is not searched. Neighbouring chunks of the same language are joined (up to 10 minutes) and transcribed in that language with the same settings as the Japanese setting. The result gets cheap checks: repetition, low confidence, an amount of text that does not fit the speaking time, and speech with no text. A flagged region is detected again (when the result is unsure, switches and islands are searched first); the other-language parts, widened to cover every line they overlap, are transcribed in that language, and the result replaces the old text only when it is better (if it is the same language, the text stays; if a re-transcribed part comes back empty, the old line stays: the checks never delete text). The thresholds were measured on English and Japanese read speech (FLEURS) and on a Japanese talk.
- **Harness before fine-tuning**: most weaknesses of a small LLM (wanting to fix everything, writing comments, repeating the same mistake) can be stopped without changing its weights. So the ledger that remembers your decisions and applies them mechanically, the gates before an answer is applied, and the evaluation harness that compares before and after on the same scenes came first. The ledger works from the first correction and needs no training time or memory. Fine-tuning (LoRA) is for when dozens of corrections have built up, and only when the harness shows the adapter is not worse.
- **Signing**: ad-hoc. To distribute the app, sign it with a Developer ID and notarize it.

## Known limitations

- No speaker diarization. 日本語＋英語 splits by the language being spoken, not by voice.
- Even with 日本語＋英語, about 1.5 s around a switch with no pause can be lost. Insertions shorter than about 1.5 s (backchannels), and insertions in noisy recordings, may be missed and come out in the surrounding language or be dropped.
- Automatic detection decides the language once, from the first 30 seconds, so use 日本語＋英語 for recordings that switch languages.
- Translation goes one way only: into Japanese.
- The recording preview covers only the last 12 seconds (the whole recording is transcribed again when you stop).

## License

MIT License ([LICENSE](LICENSE)).

Downloaded at build time or at run time (not included in this repository):

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.2 XCFramework (MIT): downloaded from GitHub at build time
- Whisper models (MIT, OpenAI) converted for whisper.cpp: downloaded from [Hugging Face](https://huggingface.co/ggerganov/whisper.cpp) on first use
- [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) converted for whisper.cpp: likewise ([ggml-org/whisper-vad](https://huggingface.co/ggml-org/whisper-vad))
- [llama.cpp](https://github.com/ggml-org/llama.cpp) b12211 XCFramework (MIT): downloaded from GitHub at build time
- [Qwen3.5](https://huggingface.co/Qwen) (Apache-2.0) GGUF: downloaded from Hugging Face when you use the auditor or translator (quantized by [unsloth](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF) / [bartowski](https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF))

Included in this repository for the tests:

- `Tests/Fixtures/mixed-en-ja.wav`: English and Japanese read speech from [FLEURS](https://huggingface.co/datasets/google/fleurs) (Google, CC BY 4.0), joined. See [Tests/Fixtures/README.md](Tests/Fixtures/README.md)
