#!/usr/bin/env bash
# 「起動しない」ときの診断。環境・組み立てたアプリ・起動の確認・クラッシュの記録を build/doctor.txt にまとめる。
# 使い方: make doctor   (結果の build/doctor.txt を、そのまま報告に貼れる)
set -u
cd "$(dirname "$0")/.."

APP="build/Kikimimi.app"
BIN="$APP/Contents/MacOS/Kikimimi"
OUT="build/doctor.txt"
mkdir -p build
: > "$OUT"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
run() { say "\$ $*"; "$@" 2>&1 | tee -a "$OUT"; say ""; }

say "== ききみみ 診断 ($(date '+%Y-%m-%d %H:%M:%S')) =="
say ""
say "-- 環境 --"
run sw_vers
run uname -m
say "memory: $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB"
run xcodebuild -version
run swift --version
run git log --oneline -1
say "\$ git status --short"; git status --short 2>&1 | head -20 | tee -a "$OUT"; say ""

say "-- 動いている Kikimimi (確認用の実行も含む) --"
pgrep -fl Kikimimi 2>&1 | tee -a "$OUT" || say "(なし)"
say ""

say "-- 組み立てたアプリ --"
if [ ! -d "$APP" ]; then
  say "✗ $APP がありません。'make run' の途中で止まっています。'make app' の出力の最後のエラーを確認してください。"
  say ""
  say "結果: $OUT"
  exit 1
fi
run ls -la "$APP/Contents" "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
if [ ! -x "$BIN" ]; then
  say "✗ 実行ファイル $BIN がありません。'make app' の出力の最後のエラーを確認してください。"
  say ""
  say "結果: $OUT"
  exit 1
fi
run codesign --verify --strict --verbose=2 "$APP"
say "\$ otool -L $BIN | grep -E 'whisper|llama'"; otool -L "$BIN" 2>&1 | grep -E 'whisper|llama' | tee -a "$OUT"; say ""
say "\$ otool -l $BIN | grep -A2 LC_RPATH"; otool -l "$BIN" 2>&1 | grep -A2 LC_RPATH | tee -a "$OUT"; say ""
say "\$ xattr $APP"; xattr "$APP" 2>&1 | tee -a "$OUT"; say ""

say "-- 起動の確認 (ウインドウが出て、数秒で自動的に閉じます) --"
MARK="$(mktemp)"
say "\$ $BIN --selftest-launch"
"$BIN" --selftest-launch 2>&1 | tail -40 | tee -a "$OUT"
CODE=${PIPESTATUS[0]}
say "終了コード: $CODE"
say ""
# クラッシュの記録は、落ちてから数秒後に書かれる
[ "$CODE" = 0 ] || sleep 4

say "-- この確認より後のクラッシュの記録 --"
FOUND=0
for DIR in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  [ -d "$DIR" ] || continue
  while IFS= read -r REPORT; do
    FOUND=1
    say "● $REPORT"
    # 先頭 (例外の種類・落ちたスレッド) だけを載せる
    head -c 6000 "$REPORT" 2>/dev/null | tee -a "$OUT"
    say ""
  done < <(find "$DIR" -maxdepth 1 -name 'Kikimimi*' -newer "$MARK" 2>/dev/null | head -3)
done
[ "$FOUND" = 1 ] || say "(なし)"
rm -f "$MARK"
say ""

if [ "$CODE" = 0 ]; then
  say "✓ 起動できました。'open $APP' で何も起きないときは、上の「動いている Kikimimi」に前の実行が残っていないか確認し、'make run' で起動し直してください。"
else
  say "✗ 起動の確認が失敗しました (終了コード $CODE)。この build/doctor.txt の内容をそのまま報告してください。"
fi
say ""
say "結果: $OUT"
exit "$CODE"
