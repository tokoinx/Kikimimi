#!/bin/bash
# GitHub Actions の build の run が終わるまで待ち、結果を短く出す。
#
# 使い方: tools/ci-watch/watch-build.sh <run の ID> [<リポジトリ。既定は tokoinx/Kikimimi>]
#
# 列 (ジョブ) が「ランナーが付かないまま取り消し」になった時だけ、その列を走らせ直す (3 回まで)。
#   - 見分け方: conclusion が cancelled で、runner_name が空 (段が 1 つも走っていない)。
#     GitHub の注記は「The job was not acquired by Runner of type hosted even after multiple attempts」。
#   - 理由: GitHub の macOS のランナーの空きが足りない時、列は 15 分待って取り消される (コードの失敗ではない)。
#     2026-11-26 の 12:35〜15:45 (UTC) に 3 回起きた。その間、始まるまで 5〜10 分待った列も在った (ふだんは 3 秒ほど)。
# 失敗 (failure) の列が在る時は、走らせ直さない (コードの失敗かもしれないので、ログを読む)。
#
# 出す物: 回ごとの列の結果と時刻、終わりの結果、試験の件数の行、アプリの確認の OK・FAILED・SLOW の行。
# gh (GitHub CLI) が要る。

RUN="$1"
REPO="${2:-tokoinx/Kikimimi}"
if [ -z "$RUN" ]; then
  echo "usage: tools/ci-watch/watch-build.sh <run id> [<owner/repo>]"
  exit 2
fi

for round in 1 2 3 4; do
  gh run watch "$RUN" --repo "$REPO" --interval 30 --exit-status > /dev/null 2>&1
  echo "watch exit $? (round $round)"
  gh api "repos/$REPO/actions/runs/$RUN/jobs" \
    --jq '.jobs[] | [.name, .conclusion, .runner_name, .created_at, .started_at, .completed_at] | @tsv'
  CONCLUSION=$(gh run view "$RUN" --repo "$REPO" --json conclusion --jq .conclusion)
  [ "$CONCLUSION" = "success" ] && break
  FAILED=$(gh api "repos/$REPO/actions/runs/$RUN/jobs" \
    --jq '[.jobs[] | select(.conclusion == "failure")] | length')
  NORUNNER=$(gh api "repos/$REPO/actions/runs/$RUN/jobs" \
    --jq '[.jobs[] | select(.conclusion == "cancelled" and (.runner_name == "" or .runner_name == null))] | length')
  if [ "$FAILED" != "0" ] || [ "$NORUNNER" = "0" ] || [ "$round" = "4" ]; then
    echo "not rerunning: failed jobs $FAILED, cancelled without a runner $NORUNNER, round $round"
    break
  fi
  echo "rerunning the cancelled jobs (no runner was assigned)"
  gh run rerun "$RUN" --repo "$REPO" --failed
  sleep 30
done

gh run view "$RUN" --repo "$REPO" --json conclusion,attempt \
  --jq '"conclusion " + .conclusion + ", attempt " + (.attempt | tostring)'
# 試験の件数 (全体の行だけ。100 件より少ない組の行は出さない) と、アプリの確認の行
gh run view "$RUN" --repo "$REPO" --log \
  | grep -a -E "Executed [0-9]{3,} tests, with|UI LOAD OK|CHECK OK|CHECK FAILED|UI LOAD: SLOW|UI LOAD FAILED|UI LOAD RETRY: the|narrow window|screenshot failed" \
  | grep -a -v -E 'echo|ui-load-3000-run1\.log' | cut -f1,3-| sed -E 's/[0-9T:.-]+Z //' | cut -c1-200 | sort | uniq -c
