#!/bin/bash
# 変な保存ファイルを 1 場面ずつ入れた一時のライブラリで、確認用の起動 (8 秒) をさせる。
#
# 使い方: tools/monkey/run_scenes.sh <作業フォルダ> [場面の名前 ...]
#   場面の名前を渡さなければ、全部の場面を順に試す (場面の一覧は make_hostile_library.py)。
#   作業フォルダは、リポジトリの外の一時フォルダ (例: "$TMPDIR/kikimimi-monkey")。
# 出力: 場面ごとに 1 行 (終了コード | 報告の最後の行 | 名前を変えてとっておかれたファイルの数 | 落ちた時の行)。
#   終わりに、本物の設定が変わっていないかを 1 行で出す (0 lines でなければ、README の「後片付け」を読む)。
# 読み方: exit 0 と「LAUNCH SELFTEST OK」が、ふつう。exit 133 など (報告が空) は、アプリが落ちた。exit 3 は、止まった。
#
# 守る事: アプリは、`--selftest-launch` と一時のライブラリ (KIKIMIMI_LIBRARY_DIR) でだけ起こす。
# 動いているアプリが在る時は、その場面を飛ばす (止めない)。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${1:?usage: run_scenes.sh <work folder> [scene ...]}"; shift
BIN="$REPO/build/Kikimimi.app/Contents/MacOS/Kikimimi"
ALL="baseline huge-duration huge-time backwards same-id empty long-line many odd-title empty-title
source-dev-zero source-directory source-missing source-not-audio real-audio future-format odd-language covers-ring
odd-dates broken-version truncated empty-file not-utf8 array deep key-control key-not-utf8 key-bad-escape
key-lone-surrogate odd-notes"
[ "$#" -gt 0 ] || set -- $ALL
mkdir -p "$WORK/scenes" "$WORK/models-empty"
defaults read local.kikimimi.app > "$WORK/defaults-before.txt" 2>&1
# 回ごとに、新しいライブラリのフォルダを使う (前の回の「とっておいたファイル」を数えないように)
RUN="$(date +%Y%m%d-%H%M%S)"

for scene in "$@"; do
  LIB="$WORK/scenes/$RUN/lib-$scene"
  mkdir -p "$LIB"
  /usr/bin/python3 -I "$HERE/make_hostile_library.py" "$LIB" baseline "$scene" > "$WORK/scenes/$scene.ids" 2>&1
  if pgrep -x Kikimimi > /dev/null; then echo "$scene: SKIPPED (Kikimimi is running)"; continue; fi
  KIKIMIMI_LIBRARY_DIR="$LIB" KIKIMIMI_MODELS_DIR="$WORK/models-empty" \
    "$BIN" --selftest-launch 8 --report "$WORK/scenes/$scene.report" > "$WORK/scenes/$scene.log" 2>&1
  code=$?
  last="$(tail -n 1 "$WORK/scenes/$scene.report" 2>/dev/null | cut -c1-90)"
  aside="$(find "$LIB" -name 'document.unreadable-*' | wc -l | tr -d ' ')"
  crash="$(grep -a -m1 -E "Fatal error|EXC_" "$WORK/scenes/$scene.log" | cut -c1-140)"
  echo "$scene: exit $code | $last | set aside $aside | $crash"
done

defaults read local.kikimimi.app > "$WORK/defaults-after.txt" 2>&1
echo "REAL SETTINGS DIFF: $(diff "$WORK/defaults-before.txt" "$WORK/defaults-after.txt" | wc -l | tr -d ' ') lines"
