# ききみみ (Kikimimi) の決まり

このプロジェクトだけの決まり。どの作業でも守る。利用者の直接の指示と食い違う時は、直接の指示に従う。
どのプロジェクトにも共通の決まり (モデルの使い分けなど) は `~/.claude/CLAUDE.md` に在る。ここには写さない。

## コード

- Swift 6.0 (Xcode 16.2) でビルドが通るように書く。引数・仮引数・タプルの末尾にカンマを書かない。Swift 6.1 以降では通ってしまうので、新しい Xcode で通っても守れているとは限らない (検査: CI の Xcode 16.2 の列)。
- macOS 14 で動く API だけを使う (検査: `Package.swift` の `.macOS(.v14)` で、コンパイラが止める)。
- コメントは、平易な日本語で書く (文面のみ。機械の検査なし)。
- 画面の文は、コードに日本語で直に書かない。`L("英語の文")`・`LPlural(…)` で書き (鍵 = 平易な英語。英語の画面にはそのまま出る)、同じ鍵の訳を、日本語の表 (`Sources/KikimimiCore/L10n/ja/`) と、ほかの 11 言語の表 (`Sources/KikimimiCore/L10n/<コード>/`) の全部に足す。手順・英語の書き方・語の一覧・訳さない物は `docs/L10N.md` (検査: `swift test` の `L10nTests`。鍵が表に無い・表に使っていない鍵が在る・言語ごとに鍵や置き換えの印が合わない・`L` を通らない日本語の文が残っている、のどれでも落ちる)。

## 結果の一覧 (`Sources/Kikimimi/Views/TranscriptListView.swift`)

破ると、数千行の結果で画面が 5〜20 秒固まる。理由と測った値は、このファイルと、呼ぶ側 (`TranscriptDetailView.swift` の `transcriptColumn`) の注釈に在る。よく変わる状態を見る部品は、`TranscriptListSupport.swift` に置く。

- 一覧は、`GeometryReader` の中の `ScrollView` + `LazyVStack` に置き、大きさを外から決める。
- 一覧は、結果ごとに `.id(job.id)` で作り直す。行には `.id()` を付けない。
- 一覧を `HSplitView`・`VSplitView` で包まない。
- 一覧の `body` は、よく変わる状態 (再生位置・メモ・練習) を読まない。

(検査: `swift test` の `TranscriptListRulesTests` が、4 つとも書き方で見る。別のファイルの関数を通して状態を読む形などは見逃す。破った時の重さは、下の「アプリの確認」が測る。)

## git

- push は `feature/auditor-translation` だけ。main へのマージと PR は、利用者の OK があるまで行わない (検査: この Mac の門が、main への push を拒み、`gh pr` に確認を出す。`git merge` は確認なしで通るので、文面のみ。ほかの場所でも文面のみ)。

## 確かめ方と「完了」

- 「完了」と報告する前に `swift test` を走らせ、失敗が 0 件である事を見る。件数は、走らせた出力から写す。
- 画面 (`Sources/Kikimimi`) を変えた時は、加えて「アプリの確認」を行う: アプリを作り、`--selftest-ui-load 3000` を音声と絵の指定つきで走らせ、「UI LOAD OK」「LIBRARY CHECK OK」「PRACTICE CHECK OK」「CHAT CHECK OK」が出て、終了コードが 0 である事を見る。手順・命令・出力と終了コードの読み方は、Skill `kikimimi-verify` (`.claude/skills/kikimimi-verify/SKILL.md`) に在る。

## 命令の書き方 (この Mac では、Bash の命令が門を通る)

門は、規則に当たらない命令と、分解できない命令 (リダイレクト・`$( )`・変数を含む物) を、確認なしで通す。確認になる命令と拒否される命令の一覧は、規則のファイル `.claude/harness-gate.rules` に在る (ここには写さない)。

- 命令は、そのまま書く。`python3 -c` の subprocess などで包まない。
- 拒否される命令 (`rm -r`、`git reset --hard`、`git clean -f`、main への push、強制 push) は、`bash -c` や `env` で包んだ形、`git -c`・`git -C` を付けた形、リダイレクトを付けた形でも拒否される。
- 分解できない命令の文の中に、拒否の語 (例: `git reset --hard`) が在ると、誤って拒否される。その時は、リダイレクトや変数を外して書き直す。

## 記録の置き場

- 続きの作業は、先に `docs/HANDOFF.md` (進み具合・残っている事) を読む。作業の区切りで書き換える。
- 確かめた事とまだ確かめていない事の表は `README.md` の「検証状況」、分かっている制限は「既知の制限」に在る。
