#!/bin/bash
# GitHub Actions の build の run が終わるまで待ち、結果を短く出す。
#
# 使い方: tools/ci-watch/watch-build.sh <run の ID> [<リポジトリ。既定は tokoinx/Kikimimi>]
#
# この台本は、読むだけ (gh run watch・gh run view)。run を走らせ直す・止めるなど、GitHub の側を変える命令は、
# 台本の中からは走らせない。この Mac の門は、台本の中の命令までは見ないので、確認の出る命令 (gh run rerun・gh api
# など) を台本で包むと、確認なしで通ってしまう (2026-11-28 に、自動の走らせ直しと gh api を外した)。
#
# 列 (ジョブ) が「ランナーが付かないまま取り消し」になった時は、走らせ直す命令を出すだけにする。
#   - 見分け方: conclusion が cancelled で、段が 1 つも走っていない。
#     GitHub の注記は「The job was not acquired by Runner of type hosted even after multiple attempts」。
#   - 理由: GitHub の macOS のランナーの空きが足りない時、列は 15 分待って取り消される (コードの失敗ではない)。
#     2026-11-26 の 12:35〜15:45 (UTC) に 3 回起きた。その間、始まるまで 5〜10 分待った列も在った (ふだんは 3 秒ほど)。
# 失敗 (failure) の列が在る時は、走らせ直しを勧めない (コードの失敗かもしれないので、ログを読む)。
#
# 出す物: 列の結果と時刻、終わりの結果、試験の件数の行、アプリの確認の OK・FAILED・SLOW の行。
# gh (GitHub CLI) が要る。

RUN="$1"
REPO="${2:-tokoinx/Kikimimi}"
if [ -z "$RUN" ]; then
  echo "usage: tools/ci-watch/watch-build.sh <run id> [<owner/repo>]"
  exit 2
fi

# gh run watch は、通信が切れると、run が終わる前に戻る事が在る (2026-11-28 に 2 回見た)。
# run が終わった (status が completed) のを確かめるまで、掛け直す
while :; do
  gh run watch "$RUN" --repo "$REPO" --interval 30 --exit-status > /dev/null 2>&1
  WATCH=$?
  STATUS=$(gh run view "$RUN" --repo "$REPO" --json status --jq .status 2> /dev/null)
  [ "$STATUS" = "completed" ] && break
  sleep 30
done
echo "watch exit $WATCH"
gh run view "$RUN" --repo "$REPO" --json jobs \
  --jq '.jobs[] | [.name, (.conclusion // "-"), ("steps " + ((.steps | length) | tostring)), (.startedAt // "-"), (.completedAt // "-")] | @tsv'
gh run view "$RUN" --repo "$REPO" --json conclusion,attempt \
  --jq '"conclusion " + .conclusion + ", attempt " + (.attempt | tostring)'

CONCLUSION=$(gh run view "$RUN" --repo "$REPO" --json conclusion --jq .conclusion)
if [ "$CONCLUSION" != "success" ]; then
  FAILED=$(gh run view "$RUN" --repo "$REPO" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "failure")] | length')
  NORUNNER=$(gh run view "$RUN" --repo "$REPO" --json jobs \
    --jq '[.jobs[] | select(.conclusion == "cancelled" and ((.steps | length) == 0))] | length')
  if [ "$FAILED" = "0" ] && [ "$NORUNNER" != "0" ]; then
    echo "cancelled without a runner: $NORUNNER job(s). This is not a code failure. To run them again (the gate asks first):"
    echo "  gh run rerun $RUN --repo $REPO --failed"
  else
    echo "failed jobs $FAILED, cancelled without a runner $NORUNNER: read the log before running anything again"
  fi
fi

# 試験の件数 (全体の行だけ。100 件より少ない組の行は出さない) と、アプリの確認の行
gh run view "$RUN" --repo "$REPO" --log \
  | grep -a -E "Executed [0-9]{3,} tests, with|UI LOAD OK|CHECK OK|CHECK FAILED|UI LOAD: SLOW|UI LOAD FAILED|UI LOAD RETRY: the|narrow window|screenshot failed" \
  | grep -a -v -E 'echo|ui-load-3000-run1\.log' | cut -f1,3-| sed -E 's/[0-9T:.-]+Z //' | cut -c1-200 | sort | uniq -c
