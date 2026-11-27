# CI の build を待つ道具

`watch-build.sh` は、GitHub Actions の build の run が終わるまで待ち、列 (Xcode 16.2・26.3) ごとの結果と、試験の件数、アプリの確認の行を短く出します。

```bash
tools/ci-watch/watch-build.sh <run の ID>
```

run の ID は、push の後に `gh run list --repo tokoinx/Kikimimi --commit <コミットの全部の SHA>` で分かります。20〜30 分かかるので、裏で走らせます。

## 列が「cancelled」になった時

列にランナーが付かないまま 15 分たつと、GitHub がその列を取り消し、run は failure になります。コードの失敗ではありません。

- 見分け方: 列の conclusion が `cancelled`、`runner_name` が空、段が 1 つも走っていない。注記は「The job was not acquired by Runner of type hosted even after multiple attempts」。
- 対応: 取り消された列だけを走らせ直す (`gh run rerun <run の ID> --failed`)。この道具は、それを 3 回まで自動で行います。成功した列は、走らせ直しません。
- 起きた例: 2026-11-26 の 12:35〜15:45 (UTC) に 3 回 (main の a4df723 で 2 回、枝の 314724e で 1 回)。同じ時間帯に、始まるまで 5〜10 分待った列も在りました (ふだんは 3 秒ほど)。Xcode の版には関係なく、GitHub の障害の履歴にも知らせは在りませんでした。

列が `failure` の時は、走らせ直しません。ログを読んで、原因を見ます。
