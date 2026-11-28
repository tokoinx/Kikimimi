#!/bin/bash
# 命令の引数の、変な形を試す。1 つずつ起こし、決めた秒数で終わらなければ止める。
#
# 使い方: tools/monkey/run_cli_cases.sh <作業フォルダ> <組の名前>
#   quick: すぐ終わるはずの物 (知らない確認の名前・数でない秒数・引数の不足・モデルでないファイル)。1 分ほど
#   load:  画面の重さの確認に、変な音声・書けない絵の置き場・知らない言語を渡す。10 分ほど
# 出力: 場面ごとに 1 行。「exit N after S s」か「STILL RUNNING after S s (stopped it)」。
#   終わりに、本物の設定が変わっていないかを 1 行で出す (0 lines でなければ、README の「後片付け」を読む)。
#
# 守る事: どの回も `--selftest-` で始まる引数か、窓を出さない道具の引数 (`--version` など) を必ず付ける
# (付けないと、ふつうの起動になり、本物の設定とライブラリを使う)。場面を足す時も、これを守る。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${1:?usage: run_cli_cases.sh <work folder> <quick|load>}"
GROUP="${2:?usage: run_cli_cases.sh <work folder> <quick|load>}"
BIN="$REPO/build/Kikimimi.app/Contents/MacOS/Kikimimi"
OUT="$WORK/cli"
ROWS="${KIKIMIMI_MONKEY_ROWS:-300}"
mkdir -p "$OUT/lib" "$WORK/models-empty"
defaults read local.kikimimi.app > "$WORK/defaults-before.txt" 2>&1

run_case() {
  name="$1"; limit="$2"; shift 2
  if pgrep -x Kikimimi > /dev/null; then echo "$name: SKIPPED (Kikimimi is running)"; return; fi
  KIKIMIMI_LIBRARY_DIR="$OUT/lib" KIKIMIMI_MODELS_DIR="$WORK/models-empty" "$BIN" "$@" > "$OUT/$name.log" 2>&1 &
  pid=$!
  waited=0
  while kill -0 "$pid" 2> /dev/null && [ "$waited" -lt "$limit" ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2> /dev/null; then
    kill "$pid"; wait "$pid" 2> /dev/null
    echo "$name: STILL RUNNING after $limit s (stopped it) | $(tail -n 1 "$OUT/$name.log" | cut -c1-110)"
  else
    wait "$pid"; code=$?
    echo "$name: exit $code after ${waited} s | $(grep -a -E 'UI LOAD (OK|FAILED)|SELFTEST (OK|FAILED)|CHECK FAILED|Fatal error|usage|unknown' "$OUT/$name.log" | tail -n 2 | tr '\n' ' ' | cut -c1-200)"
  fi
}

case "$GROUP" in
  quick)
    run_case unknown-selftest 15 --selftest-typo
    run_case launch-bad-number 40 --selftest-launch abc --report /nonexistent-dir-kikimimi/r.txt
    run_case llm-no-path 20 --selftest-llm
    run_case llm-not-a-model 30 --selftest-llm /etc/hosts
    run_case whisper-no-args 30 --selftest-whisper
    run_case whisper-not-audio 30 --selftest-whisper --audio /etc/hosts
    run_case version-with-junk 15 --version --junk "" "$(printf 'a\nb')"
    ;;
  load)
    run_case load-fewest-rows 400 --selftest-ui-load 1
    run_case load-audio-dev-zero 400 --selftest-ui-load "$ROWS" --audio /dev/zero
    run_case load-audio-not-audio 400 --selftest-ui-load "$ROWS" --audio /etc/hosts
    run_case load-audio-missing 400 --selftest-ui-load "$ROWS" --audio /nonexistent-kikimimi.wav
    run_case load-shots-unwritable 400 --selftest-ui-load "$ROWS" --audio "$REPO/Tests/Fixtures/mixed-en-ja.wav" --screenshots /nonexistent-dir-kikimimi/shots
    run_case load-language-unknown 400 --selftest-ui-load "$ROWS" --ui-language xx
    ;;
  *)
    echo "unknown group: $GROUP (quick or load)"; exit 2
    ;;
esac

defaults read local.kikimimi.app > "$WORK/defaults-after.txt" 2>&1
echo "REAL SETTINGS DIFF: $(diff "$WORK/defaults-before.txt" "$WORK/defaults-after.txt" | wc -l | tr -d ' ') lines"
