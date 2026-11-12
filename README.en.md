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
- Click a line to play just that line; it stops at the end of the line (click it again to stop; the space bar or the play button below also stops it, and pressing it again continues from where it stopped; right-click › ここから続けて再生 to keep playing from there); search highlights matches
- **Auditor**: after transcription, a reviewer looks for repeated sentences and misheard words. Only confident corrections are applied; the rest are kept as suggestions. Every change can be reviewed and undone
- **English → Japanese translation**: the original on the left, the Japanese translation on the right (Chinese, Korean and others can be translated to Japanese too). Translate everything at once, or only the sentences you want, one at a time, with the "訳" button on a line
- Export to txt / srt / vtt / Markdown / csv / json (original, Japanese, or both side by side)
- **Library**: finished results (transcript, translation, audit decisions) are saved on the Mac automatically and are listed again at the next launch
- **Notes and history**: write notes for each result (what you understood, phrases to remember). Right-click a row and choose "メモに引用" (Quote in notes) to paste that sentence with its time. Keep the current state as a "version" and go back to it later
- Japanese, English, Chinese, Korean and more, with automatic language detection
- **日本語＋英語 (Japanese + English)**: for recordings that switch between Japanese and English, such as an English lecturer with a Japanese interpreter. Each stretch of speech gets its own language and is transcribed in it; lines are tagged 英 or 日 and only the English lines are translated (it takes about 2–4× the time of the Japanese setting: longer the more often the language changes or short remarks cut in). Even with the language set to 日本語, 英語 or 自動判定, a recording found to mix Japanese and English is switched to this setting automatically (the result screen says so and lets you redo it in the original language only; it can be turned off in the settings)

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
3. Recognized text appears on the right as it is produced (rows are added in batches: up to 4 times a second while there are few rows, at most once a second once there are thousands; the list follows the newest row only while you are at the end, stops following when you scroll up or click a row to play it, and "末尾へ" (To the end) at the bottom right takes you back). Finished results are saved automatically (see "Library, notes and history" below). To use one in another app, write it to a file with "書き出す" (Export).

Recording (⌘R) asks for microphone permission the first time.

To use the auditor and the translator, download the LLM once: click "ダウンロード" (Download) on the start screen or the result screen, or use the "監査・翻訳" (Audit & translation) tab in Settings (⌘,). After that, every finished transcript is audited automatically, and English (or other non-Japanese) segments are translated into Japanese.

## Library, notes and history

Transcripts are saved on the Mac without you doing anything, and they are listed on the left again at the next launch (nothing is lost if you do not export).

- **Where**: `~/Library/Application Support/Kikimimi/Library` (next to the `Models` folder; the environment variable `KIKIMIMI_LIBRARY_DIR` changes it). Each result gets one folder holding `document.json` (transcript, translation, audit decisions, list of versions), `notes.md` (the notes, as plain text that other apps can read too) and `versions/` (the versions).
- **When**: when a transcription finishes (with at least some text), and afterwards whenever it changes through an audit, a translation, applying a fix and so on (changes within about a second are written together). Notes are saved within about a second of typing, and the notes pane shows "保存しました" (Saved) at its top right. Cancelled or failed transcriptions are not saved. Writing happens in the background, in order, so the window does not stall even with thousands of lines. When you quit, pending saves are written first.
- **Deleting**: right-click in the list on the left › "削除…" (Delete…). After you confirm, the folder (transcript, translation, notes, history) goes to the Trash. For a microphone recording, the recording in the app's `Recordings` folder goes to the Trash too. Results that were never saved (still transcribing, cancelled, failed) are removed from the list at once, as before.
- **The audio file was moved or deleted**: the result stays. It cannot be played, and the result shows "音声ファイルが見つかりません: <path>" (Audio file not found) with a button "音声を選び直す…" (Choose the audio again…); pick the new location and playback works again.
- **Unreadable results**: when a `document.json` is damaged, the file is renamed to `document.unreadable-<date>.json` in place, the result is left out of the list, and one message says how many were set aside.

**Notes**: tick "メモ" (Notes) in the controls row to show a notes pane to the right of the list (drag the divider to change its width). Write anything: what you understood, phrases to remember. Right-click a row and choose "メモに引用" (Quote in notes) to add that sentence with its time at the end of the notes, like `> [02:22] Have you ever ...`. "書き出す" (Export) › "メモ (.md)" writes the notes to a file.

**History (versions)**: "履歴" (History) in the controls row (or File › "版として保存…" (Save as a version…, ⌘S) / "履歴…" (History…)) opens the history sheet.
- "いまの状態を版として残す" (Keep the current state as a version): give it a name (optional) and press "保存" (Save) to keep a copy of the transcript, translation and notes as they are now. "新しい版として保存" (Save as a new version) adds a version; "いちばん新しい版に上書き" (Overwrite the newest version) replaces the newest version you kept yourself with the current state (when you do not want more versions).
- "この版に戻す…" (Go back to this version…): choose what to bring back ("文字起こしと訳" transcript and translation, "メモ" notes). The state before going back is kept automatically as a version ("自動 (戻す前)", automatic, before going back), so you can undo it.
- The trash button deletes a version. Versions cannot be kept or restored while the result is being audited or translated.
- The transcript, translation and notes are saved every time they change, even without versions. A version is a copy of one moment.

## Listening practice

The rows of a result double as English listening practice. Clicking a row plays it, and two buttons at the right end of the player bar below change how it plays. The settings are kept for the next launch (except "隠す" (Hide), which starts as "隠さない" (Hide nothing) at every launch).

- **Speed** (the "1.0×" button): choose 0.5×, 0.6×, 0.75×, 0.85×, 1.0× or 1.25×. It applies to normal playback and to playing a line, and changes at once even while playing. The pitch of the voice stays the same.
- **The "練習" (Practice) button** (tinted when any setting differs from the default):
  - "繰り返し" (Repeat): play a line 1, 2, 3 or 5 times, or "止めるまで" (until stopped).
  - "行のあとの間" (Pause after the line): "行と同じ長さだけ空ける" (as long as the line) leaves a pause after each play, to say the line aloud yourself (as long as the line took to play at the current speed, 1-15 s). During the pause the player bar shows "間 (声に出してみましょう)" (Pause: try saying it aloud).
  - "自動で次の行へ進む" (Go on to the next line): after the repeats and pauses, move on to the next line.
  - "隠す" (Hide): "原文を隠す" (Hide the original) turns the original text of every row that is not Japanese into grey bars (Japanese rows stay visible). "原文と訳を隠す" (Hide the original and the translation) hides the Japanese translation of those rows too. The eye button on a hidden row shows or hides that row alone (shown rows are hidden again when you change the hide setting or select another result). Searching still finds the real text.
  - "書き取りの欄を出す" (Show the dictation box): shows the dictation box under the list (below).
- **Keys**: ↓ plays the next line, ↑ the previous line, ← the current line again (also in the "再生" (Playback) menu). The space key and the play button stop a running sequence. While the focus is in a field you type into (such as the search field), the keys go to that field as usual. While you are working in the list of results on the left, the arrows move through that list (clicking a line brings them back to the lines). A line started by a key or by going on automatically is scrolled into view with as little movement as possible.
- Clicking a row, clicking the playing row again (stop), dragging the playback slider, "ここから続けて再生" (Play from here), selecting another result, deleting the result and starting a microphone recording also stop a running sequence.

**Dictation**: play a line, type what you heard into the box under the list and press Return: it is compared with the line and the result appears (the line is also shown in the list). Correct words are in the normal colour; for a wrong word, the word you typed is in red with a strikethrough, followed by the right word in green; a word you left out is in orange in square brackets; an extra word you typed is in red with a strikethrough. On the right it shows "12 / 14 語" (words; Japanese lines are compared character by character, "字") or "全部合っています" (all correct). Upper and lower case and punctuation around words do not count. Pressing Return again clears the box and plays the next line. There are also the buttons "もう一度聞く" (Listen again, ⌘L), "前の行" (Previous line) and "次の行" (Next line). Editing the text clears the result, and the box is cleared when the current line changes.

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
  - **Translating one sentence**: a non-Japanese line with no translation yet shows a "訳" button. It translates only the sentence that contains that line (for when translating everything is heavy on an 8 GB Mac; it also works with automatic translation turned off in the settings). Sentences are grouped and prompted the same way as "翻訳" (Translate), so a later "翻訳" or "残りを翻訳" (Translate the rest) skips them. Several presses are translated in turn; a waiting or running line shows a spinner instead of "訳". "中止" (Stop) cancels. A line that already has a translation can be translated again with "この文を訳し直す" (Translate this sentence again) in its right-click menu.
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

3. Train. This trains, converts the results to GGUF, compares the plain model with five intermediate adapters using the evaluation harness, and installs the best one only **if it is better than no adapter** (more lines fixed, and no more wrong fixes or harmed lines than before). The evaluation uses the scenes shipped with Kikimimi plus scenes built from held-out examples of your own corrections. An adapter that shows no gain, or makes things worse, is not installed.

   ```bash
   .venv-finetune/bin/python tools/finetune/finetune.py --data ~/Desktop/kikimimi-training.jsonl --model qwen3.5-2b --install
   ```

4. The "追加学習 (LoRA)" (Fine-tuning) section of the "監査・翻訳" tab turns the adapter on or off; "外す" (Remove) goes back to the plain LLM. An adapter made elsewhere can be added with "差分を追加…" (Add adapter) (one that does not match the selected LLM's family or size is refused; if an adapter cannot be loaded, the app runs without it and says so).

Things to know:

- **Memory needed**: about 8 GB to train 2B, 16 GB for 4B, 32 GB for 9B. On an 8 GB Mac, use 2B (the script stops and says so when memory is short). The first run downloads the training copy of the model (MLX format, e.g. `mlx-community/Qwen3.5-2B-4bit`) from Hugging Face.
- **At least 12 training examples** are required. For a handful of corrections, learned corrections already do the job without training. Fine-tuning pays off once you have dozens of corrections and want them to carry over to similar cases.
- **How much training, and which adapter**: by default the data is seen five times (300–1000 steps, with a decaying learning rate). No fixed number of steps is right, so five intermediate adapters are kept and the evaluation harness picks the best one. An example with Qwen3.5 0.8B and 12 corrections (90 training examples), on 24 lines with an error and 3 translation scenes, none seen in training:

  | | Lines fixed (automatically) | Wrong fixes | Correct lines harmed | Needless suggestions | Proper nouns kept in translation |
  |---|---|---|---|---|---|
  | No adapter | 3 (2) | 0 | 0 | 5 | 2/2 |
  | 100 steps | 2 (2) | 0 | 0 | 1 | 1/2 |
  | 200 steps | 12 (11) | 0 | 0 | 1 | 2/2 |
  | 300 steps | 14 (14) | 0 | 0 | 1 | 1/2 |
  | 400 steps | 14 (14) | 0 | 0 | 1 | 1/2 |

  The 300- and 400-step adapters fix the most lines, but they also make the translation turn "Roblox Studio" into 「ロブス・スタジオ」, so the harness rules them "worse" and picks the 200-step adapter, which leaves translation intact. In another experiment that kept a constant learning rate up to 600 steps, the model fixed almost nothing again after 500 steps (2 lines), and a run with another seed produced a wrong fix ("Roblocks → Robo"). Fine-tuning a small model is unstable like this, so always run the evaluation before using an adapter (the script does). These numbers come from running the same training in PyTorch and evaluating the converted adapters with llama.cpp.
- The script corrects three things that make training ineffective when mlx-lm is used as is (each was reproduced by running the same training in PyTorch):
  - **What is trained**: mlx-lm also trains on the marker that closes the "thinking" block before the answer. With Qwen3.5 nearly all of the training goes there, so the loss is restricted to the answer.
  - **The loss**: mlx-lm counts one padding position after the end of each example. With answer-only training (3–12 tokens) that one position dominates the loss (4.634 against 0.012 for one example), so it is excluded.
  - **The optimizer**: MLX's Adam does not apply bias correction by default. For the first few hundred steps the weights move about three times as far, and at a learning rate of 2e-4 training becomes unstable (validation loss 0.36 → 1.15 → 1.78), so bias correction is turned on.
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
- **Transcribe recordings that mix Japanese and English with 日本語＋英語 automatically** (on by default): with the language set to 日本語, 英語 or 自動判定, the language of chunks picked evenly across the recording (3 s of speech or more, up to 24) is checked before transcribing. When at least 2 of them, and at least 10% of the chunks detected, hold the other language (its probability is 0.25 or more; a chunk with both languages and an uncertain result counts too), the recording is transcribed with 日本語＋英語 (the language you set comes first; the result is the same as choosing 日本語＋英語). A recording in one language gives the same result as before, apart from the few seconds to a few tens of seconds the check takes. There is no check without VAD, or for short recordings with fewer than 4 chunks to check.
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

  While the app keeps running with its window closed (during a transcription or translation), click the Dock icon or choose File > メインウインドウを表示 (⌘0) to bring the window back. When nothing is in progress, closing the window quits the app. Finished results and notes are saved and are listed again at the next launch. Quitting (⌘Q) while work is in progress asks first, because that work stops (a transcription in progress keeps no partial result).
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
| Switching a mixed recording to 日本語＋英語 automatically from the Japanese setting (real whisper) | Verified on a Linux CPU. The 208 s recording read in turns and the 2.6-minute turn-taking recording were judged mixed and gave the same runs, switches and repairs as choosing 日本語＋英語. The Japanese-only talk (3.5 min) and JFK's 11 s (English setting) gave the same text as the plain setting. The English lecture with six 1–3 s Japanese remarks was judged not mixed (9 English, 1 unsure) and is transcribed in English as before. The 54 s clip is not checked (only 2 chunks) |
| 日本語＋英語 in the built app | GitHub Actions transcribes a 47 s English/Japanese recording with tiny and checks each line's language on every push |
| 日本語＋英語 speed on a Mac (Metal), and a 2-hour lecture | Not verified yet (awaiting a run on real hardware; measured without any cached results on a Linux CPU, it takes 2.4× the Japanese setting for a 3.5-minute Japanese-only talk and 3.9× for a 2.7-minute recording with a Japanese remark about every 30 s) |
| llama.cpp b12211 usage (grammar-constrained generation, cut-offs, cancellation, neutralized control tokens, Japanese UTF-8) | Checked against the real llama.cpp (Linux build) with a tiny random-weight GGUF |
| whisper.framework and llama.framework in one app | GitHub Actions runs the built app's `--selftest-llm` on every push |
| Audit and translation with the real Qwen3.5 2B / 4B (English and Japanese samples, sentences cut across segments, mishearings, repeats) | Verified on a Linux CPU (4B: 7 lines translated in 26 s, audit in 18 s). Found and fixed drift into Chinese and wrong auto-fixes along the way |
| Qwen3.5 speed on a Mac (Metal), and auditing/translating a long (1-hour) recording | Not verified yet (awaiting a run on real hardware) |
| Learned corrections, gates, evaluation harness | Unit tests. Measured with the real Qwen3.5 2B / 4B (Linux CPU, table above). In the built app, GitHub Actions runs the rules-only and with-ledger evaluations (all 10 learned lines fixed, no correct line harmed) and the training-data export on every push |
| Loading a LoRA adapter | Checked with the real llama.cpp (Linux) and Qwen3.5 0.8B: an all-zero adapter leaves the output unchanged, a random one changes it, a broken file or an adapter for another model is not loaded and the plain LLM is used. On GitHub's Mac, a zero adapter converted from the MLX layout also leaves the evaluation result unchanged |
| Fine-tuning (the MLX training itself) | Confirmed end to end on GitHub's Mac (macOS 15) with Qwen3.5 0.8B: train with MLX (425 steps, validation loss 0.80 → 0.11), convert five intermediate adapters to GGUF, compare them with the built app's evaluation harness and pick one. Of 5 lines never seen in training, the plain model found 0 and the chosen adapter found 4 (as suggestions; no wrong fix, no correct line harmed). The adapters from 85–255 steps found 0 and the one from 340 steps found 1. How the training must be done (answer-only loss, no padding position, Adam bias correction, number of steps and side effects) was worked out by running the same training in PyTorch and evaluating the converted adapters with the real llama.cpp (Linux). Not verified on real hardware (an 8 GB M1) or with 2B and larger (GitHub's Mac has a virtual GPU and needs 1 h 40 min for 425 steps on 0.8B; the speed on real hardware is unknown) |
| The confirmation before quitting, quitting when the window is closed, the fine-tuning settings screen | Not verified (implemented and built only; the UI cannot be exercised on Linux or on GitHub's Mac) |
| Library (automatic saving, reloading, deleting), notes, history (keeping, overwriting and restoring versions) | The storage (`LibraryStore`) is unit tested. In the app, GitHub's Mac runs the save check inside `--selftest-ui-load` (LIBRARY CHECK) on every push: in a temporary folder, using the same AppModel functions as the app, it saves the finished results (not the running one), writes notes, keeps versions A and B as new versions, overwrites with C (2 versions), restores the notes of A only (an automatic version is added, making 3; the transcript is unchanged), reloads the folder and compares the contents, and deletes a small result and checks that its folder is gone. It also prints how long writing the 3000-line result takes in the background. The look of the notes pane and the history sheet was checked only on the pictures from that run (07, 08). Not yet verified on real hardware |
| Listening practice (speed, repeat, pause after the line, going on to the next line, the ↓↑← keys, hiding, dictation) | The sequencer (`LineSequencer`), the settings, the dictation check and the hiding rule are unit tested. In the app, GitHub's Mac runs the practice check inside `--selftest-ui-load --audio` (PRACTICE CHECK) on every push: with the real sound of the 47 s recording, the real practice controller and player, it checks that one line at 0.5× stops by itself at its end and takes about twice the line's length, that repeat 2 at 1.25× plays exactly twice and stops, that the pause as long as the line lasts more than 1 s, that it goes on to the next line by itself and plays nothing after being stopped, that next, previous and again move the current line as expected (previous at the first line does nothing), and that the space-key path stops it both while playing and during the pause (about 30 s; skipped on a Mac that cannot play audio). The look of hidden rows with the eye button, and of the dictation box and its colours, was checked only on the pictures from that run (09, 10). The keys, and real hardware, are not verified yet |
| A transcript with thousands of lines keeps the window responsive while lines play and a transcription runs, and a single line stops at its end | GitHub Actions runs the built app's `--selftest-ui-load` on every push (3000 lines decide pass or fail; 8000 lines are measured for information only and do not fail the build, since a real transcript of a 2-hour recording has about 2000-4000 lines). It adds finished jobs (bilingual and plain) and a running job that starts with the same number of lines and grows, and for each action measures how long until the main thread is idle again (count, median, 95th percentile, maximum). The actions are: selecting a job, a playback-position update (advancing 0.2 s like the real observer; updates that keep the current row and updates that move it to another row are counted separately), starting and stopping a single line, appending one segment to the selected and to a non-selected job, one batch applied while a running job receives 10 segments a second, delivering 300 segments at once (timed from the start of applying the batch), and a progress update. Segments are delivered from another thread into the same buffer the transcription uses (batches are applied every 0.25-1 s depending on the number of rows). A watchdog thread also measures the main thread's wait per phase and how long it could not respond (also as a share of the phase), and lists the five longest stalls with the action before each. Without a window it also times building the list rows (a full rebuild from all lines, and appending 10 segments to a running job; median and maximum of 20 runs each). It fails above its limits (`UILoadSelfTest.Limits`, set for GitHub's runner). With 3000 lines it also really plays one line of the 47 s recording and checks that it stops at the end of the line and that the play button then continues from there; that part is skipped on a Mac that cannot play audio. After measuring, it also saves pictures of the window (`--screenshots`; kept as a CI artifact). Result on GitHub's Mac with 3000 lines: while a transcription runs, the main thread is busy 1-12% of the time, one batch of new lines takes 0.1-0.3 s, and opening a result takes 0.1-1.0 s. A single line stopped exactly at its end. Not verified on real hardware (a 2-hour recording) |

## Tests

The parts that do not depend on the UI (export, model catalog, WAV, hallucination filter, auditor, translator) live in `KikimimiCore` and are unit tested:

```bash
swift test
```

There is also a transcription diagnostic in the built app (no window opens). It prints the language found for each chunk, the stretches transcribed in one go, what the checks flagged and what was re-transcribed, each line's language, the time taken and the memory used. Without `--model` / `--vad` it uses the models downloaded in the app. `--from` / `--to` (seconds) cut out a part, `--languages ja` uses the Japanese setting, `--auto-mixed` (with `--languages ja` or similar) first checks whether Japanese and English are mixed (it prints the chunks checked and the decision), and `--report` writes the result as JSON.

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
    TranscriptRowCache.swift  Rows of the result list, translation stats and language label (while transcribing, only appended segments are added)
    Exporter.swift       txt / srt / vtt / md / csv / json
    ModelCatalog.swift   Model list, download URLs, model file validation
    HallucinationFilter.swift  Removes common hallucinations
    Practice/            Listening practice (the parts that do not depend on the player)
      PracticeSettings.swift  Speed, repeat, pause, go on, hide: the settings and how they are saved
      LineSequencer.swift  Decides what to do next (play, wait, stop)
      LineNeighbors.swift  The previous and next line, the line at a time
      DictationCheck.swift  Checks a dictation
      DictationDisplay.swift  How a dictation result is laid out
      HiddenText.swift   Which text of a row is hidden, the speed labels
    WAV.swift            Saves recordings (16-bit PCM)
    Library/             The library (saved results)
      SavedDocument.swift  A saved result, version headers and contents
      LibraryStore.swift   Reads and writes the result folders (keeps unreadable files aside)
      NoteQuote.swift    The text "メモに引用" (Quote in notes) adds
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
    LibraryWriter.swift  Writes to the library in the background, one write after another
    UILoadSelfTest.swift --selftest-ui-load (checks that a transcript with thousands of lines does not freeze the window, and the saving, for CI)
    AudioDecoder.swift   Audio/video to 16 kHz mono
    LiveRecorder.swift   Microphone recording
    PlayerController.swift  Playback, seeking and speed
    PracticeController.swift  Listening practice (playing lines in sequence, hiding, dictation); runs the player as the sequencer decides
    Views/               UI
      PracticeMenu.swift The speed and "練習" (Practice) buttons of the player bar, the pause note
      DictationBar.swift The dictation box and its result
      NotesPane.swift    The notes pane
      HistorySheet.swift The history sheet (keep, restore and delete versions)
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
  With 日本語, 英語 or 自動判定, the same VAD and chunks are built before transcribing, and chunks picked evenly across the recording (3 s of speech or more, up to 24) are detected with Japanese and English only, and the language with the larger sum of probability is taken as the main one. When at least 2 chunks, and at least 10% of the chunks detected, give the other language a probability of 0.25 or more (chunks detected as the other language, and chunks whose result is uncertain), the recording is transcribed with 日本語＋英語 (reusing the VAD and the detections from the check). Otherwise it is transcribed in one language as before. This came from a 2-hour lecture (an English lecturer and a Japanese interpreter) transcribed with 日本語, where the English parts came out broken: the user should not have to pick the setting.
- **Harness before fine-tuning**: most weaknesses of a small LLM (wanting to fix everything, writing comments, repeating the same mistake) can be stopped without changing its weights. So the ledger that remembers your decisions and applies them mechanically, the gates before an answer is applied, and the evaluation harness that compares before and after on the same scenes came first. The ledger works from the first correction and needs no training time or memory. Fine-tuning (LoRA) is for when dozens of corrections have built up, and only when the harness shows the adapter is not worse.
- **Signing**: ad-hoc. To distribute the app, sign it with a Developer ID and notarize it.

## Known limitations

- No speaker diarization. 日本語＋英語 splits by the language being spoken, not by voice.
- Even with 日本語＋英語, about 1.5 s around a switch with no pause can be lost. Insertions shorter than about 1.5 s (backchannels), and insertions in noisy recordings, may be missed and come out in the surrounding language or be dropped.
- Automatic detection decides the language once, from the first 30 seconds. For Japanese and English, the app first checks whether they are mixed and switches to 日本語＋英語 (when the setting is on), but an English recording whose only Japanese is short remarks (under 3 s) is likely to be judged not mixed, so choose 日本語＋英語 yourself to catch those remarks.
- Translation goes one way only: into Japanese.
- Use 日本語＋英語 with "無音を飛ばす (VAD)" turned on (the default). Without it, language detection on silent stretches is unreliable and can invent a switch, so a few seconds may be transcribed in the wrong language.
- A learned correction is a word replacement. A fix that is right on one line and wrong on another (two real words that sound alike) comes back only as a suggestion after one acceptance, but becomes automatic after two. If it stops fitting, delete it under "学習した直し" in Settings.
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
