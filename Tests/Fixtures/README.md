# Test fixtures

## mixed-en-ja.wav

47.8 s, 16 kHz, mono, 16-bit PCM. English and Japanese read speech in turns, used by CI to check the 日本語＋英語 mode
(`Kikimimi --selftest-whisper Tests/Fixtures/mixed-en-ja.wav --languages ja,en --expect Tests/Fixtures/mixed-en-ja.expect.json`):

| Time (s) | Language | Note |
|---|---|---|
| 0.30–15.36 | English | two sentences |
| 16.06–26.07 | Japanese | after a 0.7 s pause |
| 26.77–36.02 | English | after a 0.7 s pause |
| 36.02–47.49 | Japanese | no pause before it |

`mixed-en-ja.expect.json` lists these intervals. The self-test checks only the text whose middle lies 1.5 s or more
inside an interval, because the switch with no pause can be found up to about 1.5 s off.

The clips come from the test split of FLEURS (`en_us` and `ja_jp`):

> Alexis Conneau, Min Ma, Simran Khanuja, Yu Zhang, Vera Axelrod, Siddharth Dalmia, Jason Riesa, Clara Rivera,
> Ankur Bapna. "FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech." 2022.
> https://huggingface.co/datasets/google/fleurs — licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

Changes: utterances were trimmed with Silero VAD, cut and joined with short silences (FLEURS audio is already 16 kHz mono).
