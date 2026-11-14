# ききみみ (Kikimimi) の決まり

このプロジェクトだけの決まり。どの作業でも守る。利用者の直接の指示と食い違う時は、直接の指示に従う。
どのプロジェクトにも共通の決まり (モデルの使い分けなど) は `~/.claude/CLAUDE.md` に在る。ここには写さない。

## コード

- Swift 6.0 (Xcode 16.2) でビルドが通るように書く。引数・仮引数・タプルの末尾にカンマを書かない。Swift 6.1 以降では通ってしまうので、新しい Xcode で通っても守れているとは限らない (検査: CI の Xcode 16.2 の列)。
- macOS 14 で動く API だけを使う (検査: `Package.swift` の `.macOS(.v14)` で、コンパイラが止める)。
- コメントと画面の文は、平易な日本語で書く (文面のみ。機械の検査なし)。

## 結果の一覧 (`Sources/Kikimimi/Views/TranscriptDetailView.swift`)

破ると、数千行の結果で画面が 5〜20 秒固まる。理由と測った値は、このファイルの注釈に在る。

- 一覧は、`GeometryReader` の中の `ScrollView` + `LazyVStack` に置き、大きさを外から決める。
- 一覧は、結果ごとに `.id(job.id)` で作り直す。行には `.id()` を付けない。
- 一覧を `HSplitView`・`VSplitView` で包まない。
- 一覧の `body` は、よく変わる状態 (再生位置・メモ・練習) を読まない。

(検査: 書き方を見る検査は無い。破った時の重さは、下の「アプリの確認」が測る。)

## git

- push は `feature/auditor-translation` だけ。main へのマージと PR は、利用者の OK があるまで行わない (検査: この Mac の門が、main への push を拒み、`git merge` と `gh` に確認を出す。ほかの場所では文面のみ)。

## 確かめ方と「完了」

- 「完了」と報告する前に `swift test` を走らせ、失敗が 0 件である事を見る。件数は、走らせた出力から写す。
- 画面 (`Sources/Kikimimi`) を変えた時は、加えて「アプリの確認」を行う: アプリを作り、`--selftest-ui-load 3000` を音声と絵の指定つきで走らせ、「UI LOAD OK」「LIBRARY CHECK OK」「PRACTICE CHECK OK」が出て、終了コードが 0 である事を見る。命令は `.github/workflows/build.yml` の「UI load self-test (3000 lines, …)」の段と同じ。終了コードの意味は `Sources/Kikimimi/UILoadSelfTest.swift` の始めの注釈に在る。

## 命令の書き方 (この Mac では、Bash の命令が門を通る)

- 確認で止まる書き方を避ける: リダイレクト (`>`、`2>&1`)、変数 (`$PWD` など)、`$( )`、`\` での空白の逃がし (門が命令を分解できない)。`cd` と `git -C` (規則に当たらない)。
- パスは、プロジェクトの根からの相対パスか、二重引用符で囲んだ絶対パスで書く。

## 記録の置き場

- 確かめた事とまだ確かめていない事の表は `README.md` の「検証状況」、分かっている制限は「既知の制限」に在る。
