# 引き継ぎ (ききみみ)

次の会話が、続きから始めるための覚え書き。作業の区切りで書き換える (済んだ項目は消す。前の形は git に在る)。

ここには写さない物:
- 決まり → `CLAUDE.md`
- 確かめの手順 → Skill `kikimimi-verify` (`.claude/skills/kikimimi-verify/SKILL.md`)
- 実機でまだ確かめていない事と、分かっている制限 → `README.md` の「検証状況」「既知の制限」

最後に書き換えた日: 2026-11-15

## 進み具合と決めた事

- 作業の枝は `feature/auditor-translation`。
- 2026-11-14: `CLAUDE.md` を、このプロジェクトの決まりに置き換えた。確かめの手順の Skill を足した。
- 2026-11-15: `make check-ui` (アプリの確認)、CI で Xcode 16.2 が無い時に止める事、この文書を足した。
- 最後に確かめた状態 (2026-11-14、コミット 182f088): 手元の `swift test` は 266 件で失敗 0、アプリの確認は終了コード 0。CI は Xcode 16.2 と 26.3 の 2 列とも成功。

## 大事な前提

- 利用者の Mac では、Bash の命令が門を通る (規則は `.claude/harness-gate.rules`。git には載っていない)。門の規則と設定は、エージェントからは変えない。変えたい時は、案として利用者に報告する。

## 残っている事

アプリ:
- `swift build` に、「Swift 6 の言語モードでは誤りになる」という警告が 5 か所出る (2026-11-14、手元)。`@unknown default` が無い switch: `PracticeController.swift:324`、`DictationBar.swift:105`、`AppModel.swift:940`、`WhisperSelfTest.swift:131`。Sendable: `AudioDecoder.swift:36`。直していない。
- CI の 2026-11-14 の実行で、Xcode 16.2 の列の最後の `--selftest-whisper` の段 (失敗にしない設定) の後に `Process completed with exit code 1` が出ている。同じ注記は、26.3 の列と 2026-11-12 の実行にも在る (どの段かは見ていない)。原因は調べていない。

エージェントの仕事の仕組み:
- 結果の一覧の決まり (`CLAUDE.md`) を、書き方で見る検査は無い。破った時の重さは、`make check-ui` と CI の 3000 行の確認が測る。
- 報告の型 (動かした事実と、確かめていない事を書く) を、どの指示ファイルに置くかが決まっていない。
- 門の規則に足す候補 (`git ls-files`・`git check-ignore` を通す、`make test check-ui` に確認を出す) は、利用者が規則を直すのを待っている。
- 前の引き継ぎに在った「実機でまだ確かめていない事」「分かっている小さな穴」「残っている案」の一覧は、ここに入っていない。2026-11-15 に利用者の Mac の中を探したが、その文書は見つからなかった。

## 続けるのに要る参照

- 門の説明と、門の記録のまとめを出す命令: 利用者の Mac の Harness 研究のフォルダの `deliverables/kikimimi/README.md`。
- CI が残す画面の絵: 実行ごとの成果物 `ui-shots-…` (14 日で消える)。手元では `build/ui-shots`。
