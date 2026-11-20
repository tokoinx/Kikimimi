# リンクの検査 (check-links)

リンク切れと、古くなった依存に、早く気づくための道具。python3 の標準ライブラリだけで動く。
CI では `.github/workflows/links.yml` が、週 1 回 (月曜 03:17 UTC) と、関係するファイルを変えた push の時に走らせる。

## 何を見るか

- **実行時の URL**: アプリがモデルを取りに行く URL。モデルの一覧 `Sources/KikimimiCore/Catalog/models.json` (アプリが埋め込むのと同じ JSON) から作る。
  Whisper の各モデル (`whisper.fileNameTemplate` と `whisper.downloadURLTemplate` の `{id}`・`{fileName}` を置き換える) → VAD (`vad.url`) → LLM の tree API (`llm.treeURLTemplate` の `{repository}` を、モデルの順 × リポジトリの順に置き換える) の順。
  LLM は、アプリがファイルの一覧を読む tree API の URL を見る (取るファイルは、その一覧から選ぶため)。
  置き換えはアプリと同じやり方で、両方が同じ URL になる事は Swift の試験 (`LinkListTests`) が見る。
- **文書・CI の URL**: `README.md`・`README.en.md`・`docs/**/*.md`・`Package.swift`・`.github/workflows/*.yml`・`tools/**/*.py`・`tools/**/*.md`・`.claude/skills/**/*.md` に書いてある `https://…`。
  組み立て途中の URL (`${…}`・`{…}`・`<…>`・`$(`・`\(`・`…` が続く物、`"…/" + 名前` の形) は飛ばす。
- **依存の新しさ (参考)**: `Package.swift` の binaryTarget (llama.cpp・whisper.cpp) の版と、最新の版。失敗にはしない。
  「最新」は、今の zip と同じ形の名前 (版の所だけ違う) の zip が付いた、いちばん新しい release (直近 30 個から探す)。
  GitHub の「latest」の印は使わない (llama.cpp の bNNNN は prerelease の印が付き、latest は zip の無い v1.0.0 を指す。whisper.cpp の zip は vX.Y.Z でなく bNNNN の release に付く)。latest の印の release は、参考に別に出す。
  版の名前の形が変わった時 (v1.9.2 → b5454 など) は `tag form changed` と出す。

調べ方: まず HEAD。403 / 405 / 501 なら 1 バイトだけの GET (`Range: bytes=0-0`)。転送は 10 回まで追う。待ちは 20 秒、やり直しは 2 回 (間 3 秒)。

## 走らせ方

```sh
python3 tools/check-links/check_links.py                       # 全部
python3 tools/check-links/check_links.py --runtime-only        # 実行時の URL だけ
python3 tools/check-links/check_links.py --docs-only           # 文書・CI の URL だけ
python3 tools/check-links/check_links.py --urls-file 一覧.txt  # 1 行に 1 つの一覧の URL だけ (依存は見ない)
python3 tools/check-links/check_links.py --report out.json     # 結果を JSON にも書く
python3 tools/check-links/check_links.py --list-runtime        # 実行時の URL を、調べずに 1 行に 1 つ出すだけ (ネットにつながない)
```

macOS では `/usr/bin/python3` で走らせる (python.org の版は、証明書を入れていないと、全部の URL が切れて見える)。

`--no-deps` を付けると、依存の新しさを見ない。`GITHUB_TOKEN` が在れば、`api.github.com` への問い合わせにだけ付ける。

## 結果の読み方

| 印 | 意味 | 失敗になるか |
|---|---|---|
| `OK` | 生きている | ならない |
| `MOVED` | 始めの応答が 301 / 308 で、別の URL に移った (行き先を出す) | ならない (書き換えるとよい) |
| `UNSURE` | 429・5xx・待ちきれない、がやり直しても続いた。相手の一時の都合かもしれない | ならない |
| `BROKEN` | 4xx・つながらない | なる |

終わりの行は `LINK CHECK OK (N urls)` か `LINK CHECK FAILED: N broken`。終了コードは、`BROKEN` が在れば 1、無ければ 0。
`DEPENDENCY: llama.cpp b12556 is the latest (…)` は、今の版が最新の時の出力 (古い時は `DEPENDENCY: llama.cpp <今の版> -> latest <最新の版> (…)`。括弧の中は、その zip の名前など)。`unknown (rate limited)` は GitHub の回数の制限で読めなかった事。
GitHub Actions の上では、`BROKEN` は error、`MOVED`・`UNSURE`・古い依存は warning の注釈になる。
実行時の URL の `UNSURE` は、続いているかを見られないので、毎回 warning に出る。続く時は手で確かめる。

## ignore.txt の足し方

調べない URL を、1 行に 1 つ書く (前方一致)。例の URL・手元の URL・後ろに名前を足して使う元の URL などを入れる。
足す時は、なぜ調べないかを上の行に `#` の注釈で書く。切れた URL を黙らせるためには使わない。

## 切れていた時にやる事

- **モデルの URL (実行時の URL)**: 取り先が動いた。新しい URL を確かめ、`Sources/KikimimiCore/Catalog/models.json` だけを直す (Whisper・VAD・LLM の全部がここに在る。この検査も同じファイルを読む)。
  直した後、`/usr/bin/python3 Scripts/generate-model-catalog.py` でアプリに埋め込む Swift のファイルを作り直し、`swift test` を通す (作り直し忘れは `ModelCatalogDataTests` が止める)。
- **依存の zip (`Package.swift`)**: 新しい版の zip を落とし、`swift package compute-checksum <zip>` で checksum を出し、`Package.swift` の `url:` と `checksum:` を直す。その後、`swift test` とアプリの確認を通す。名前の形が変わっていた時 (例: whisper.cpp は bNNNN の release に付く形になった) は、新しい release の zip の名前を見て、URL を書き直す。
- **文書の URL**: 新しい URL に書き換えるか、要らなければ消す。
- `MOVED` は、行き先に書き換えておくと、後で切れにくい。
