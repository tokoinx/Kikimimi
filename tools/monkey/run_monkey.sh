#!/bin/bash
# 変な保存ファイルを全部の場面で 1 つのライブラリに入れ、開いた後の画面を、でたらめな順に触る (--selftest-monkey)。
#
# 使い方: tools/monkey/run_monkey.sh <作業フォルダ> [種 ...]
#   種を渡さなければ、1〜5 を順に試す。回数は環境変数 KIKIMIMI_MONKEY_STEPS (既定 300)。
#   作業フォルダは、リポジトリの外の一時フォルダ (例: "$TMPDIR/kikimimi-monkey")。
# 出力: 種ごとに 1 行 (終了コード | 最後の MONKEY の行 | 落ちた時の行)。
#   終わりに、本物の設定が変わっていないかを 1 行で出す (0 lines でなければ、README の「後片付け」を読む)。
# 読み方: exit 0 と「MONKEY OK」が、ふつう。exit 3 は止まった、exit 10 はいつも成り立つ事が破れた、
#   exit 133 など (最後の行が「MONKEY: step …」) は、その操作でアプリが落ちた。
#
# 守る事: アプリは、`--selftest-monkey` と一時のライブラリ (KIKIMIMI_LIBRARY_DIR) でだけ起こす。
# 動いているアプリが在る時は、その種を飛ばす (止めない)。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${1:?usage: run_monkey.sh <work folder> [seed ...]}"; shift
BIN="$REPO/build/Kikimimi.app/Contents/MacOS/Kikimimi"
STEPS="${KIKIMIMI_MONKEY_STEPS:-300}"
# 入れない場面 (空白で区切る。止まると分かっている場面を外して、先を試す時。外したら、そう報告する)
SKIP_ARGS=""
for scene in ${KIKIMIMI_MONKEY_SKIP:-}; do SKIP_ARGS="$SKIP_ARGS --skip $scene"; done
[ -n "$SKIP_ARGS" ] && echo "SCENES LEFT OUT:${SKIP_ARGS// --skip / }"
[ "$#" -gt 0 ] || set -- 1 2 3 4 5
mkdir -p "$WORK/monkey" "$WORK/models-empty"
defaults read local.kikimimi.app > "$WORK/defaults-before.txt" 2>&1
# 回ごとに、新しいフォルダを使う (前の回の直し・版・とっておいたファイルを持ち込まないように)
RUN="$(date +%Y%m%d-%H%M%S)"

for seed in "$@"; do
  # 種ごとに、新しいライブラリ (前の種が直した結果を、次の種に持ち込まない)
  LIB="$WORK/monkey/$RUN/lib-seed-$seed"
  mkdir -p "$LIB"
  /usr/bin/python3 -I "$HERE/make_hostile_library.py" "$LIB" $SKIP_ARGS > "$WORK/monkey/$RUN/seed-$seed.ids" 2>&1
  if pgrep -x Kikimimi > /dev/null; then echo "seed $seed: SKIPPED (Kikimimi is running)"; continue; fi
  REPORT="$WORK/monkey/$RUN/seed-$seed.report"
  KIKIMIMI_LIBRARY_DIR="$LIB" KIKIMIMI_MODELS_DIR="$WORK/models-empty" \
    "$BIN" --selftest-monkey --seed "$seed" --steps "$STEPS" --report "$REPORT" > "$WORK/monkey/$RUN/seed-$seed.log" 2>&1
  code=$?
  last="$(grep -a '^MONKEY' "$REPORT" 2>/dev/null | grep -av 'notice:' | tail -n 1 | cut -c1-200)"
  crash="$(grep -a -m1 -E "Fatal error|EXC_" "$WORK/monkey/$RUN/seed-$seed.log" | cut -c1-140)"
  echo "seed $seed: exit $code | $last | $crash"
done

defaults read local.kikimimi.app > "$WORK/defaults-after.txt" 2>&1
echo "REAL SETTINGS DIFF: $(diff "$WORK/defaults-before.txt" "$WORK/defaults-after.txt" | wc -l | tr -d ' ') lines"
