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
say "\$ df -h ."; df -h . 2>&1 | tail -1 | tee -a "$OUT"; say ""
say "\$ memory_pressure | tail -1"; memory_pressure 2>&1 | tail -1 | tee -a "$OUT"; say ""
run sysctl vm.swapusage

say "-- 動いている Kikimimi (確認用の実行も含む) --"
RUNNING="$(ps -axo pid=,etime=,rss=,args= | grep '[K]ikimimi.app/Contents/MacOS/Kikimimi' || true)"
if [ -n "$RUNNING" ]; then
  say "$RUNNING"
  say "↑ 動いているものがあると、'open build/Kikimimi.app' は新しく起動せず、それを呼び出すだけになります。"
  say "  'make run' は、動いているものを終了させてから新しく起動します。"
else
  say "(なし)"
fi
say ""
say "\$ lsappinfo list | grep -i -A8 kikimimi"; lsappinfo list 2>/dev/null | grep -i -A8 kikimimi | head -40 | tee -a "$OUT"; say ""
say "\$ ls -d /Applications/Kikimimi.app (別の場所の同じアプリ)"; ls -d /Applications/Kikimimi.app 2>&1 | tee -a "$OUT"; say ""
say "-- 起動の記録の末尾 (~/Library/Logs/Kikimimi/launch.log) --"
tail -12 "$HOME/Library/Logs/Kikimimi/launch.log" 2>/dev/null | tee -a "$OUT" || true
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
run codesign --verify --deep --strict --verbose=2 "$APP"
say "\$ $BIN --version"; "$BIN" --version 2>&1 | head -5 | tee -a "$OUT"; say ""
say "\$ otool -l $BIN | grep -A4 LC_BUILD_VERSION"; otool -l "$BIN" 2>&1 | grep -A4 LC_BUILD_VERSION | tee -a "$OUT"; say ""
say "\$ otool -L $BIN | grep -E 'whisper|llama'"; otool -L "$BIN" 2>&1 | grep -E 'whisper|llama' | tee -a "$OUT"; say ""
say "\$ otool -l $BIN | grep -A2 LC_RPATH"; otool -l "$BIN" 2>&1 | grep -A2 LC_RPATH | tee -a "$OUT"; say ""
say "\$ xattr $APP"; xattr "$APP" 2>&1 | tee -a "$OUT"; say ""

say "-- 起動の確認 (ウインドウが出て、数秒で自動的に閉じます) --"
say "\$ $BIN --selftest-launch 5 --reopen"
"$BIN" --selftest-launch 5 --reopen 2>&1 | tail -40 | tee -a "$OUT"
CODE=${PIPESTATUS[0]}
say "終了コード: $CODE"
say ""
if [ "$CODE" = 0 ]; then
  # LaunchServices 経由 (open) でも起動できるか。シェルからは起動できて、ここだけ失敗するなら、macOS 側の登録の問題
  say "-- open からの起動の確認 --"
  REPORT="$PWD/build/doctor-open.txt"
  rm -f "$REPORT"
  say "\$ open -n -W $APP --args --selftest-launch 5 --report $REPORT"
  open -n -W "$APP" --args --selftest-launch 5 --report "$REPORT" 2>&1 | tee -a "$OUT"
  if [ -f "$REPORT" ] && grep -q "LAUNCH SELFTEST OK" "$REPORT"; then
    say "✓ open からも起動できました"
  else
    say "✗ open からは起動できませんでした"
    [ -f "$REPORT" ] && tee -a "$OUT" < "$REPORT"
    CODE=5
  fi
  say ""
fi
# クラッシュの記録は、落ちてから数秒後に書かれる
[ "$CODE" = 0 ] || sleep 4

say "-- この 1 時間のクラッシュの記録 --"
FOUND=0
for DIR in "$HOME/Library/Logs/DiagnosticReports" "/Library/Logs/DiagnosticReports"; do
  [ -d "$DIR" ] || continue
  while IFS= read -r REPORT; do
    FOUND=1
    say "● $REPORT"
    # 先頭 (例外の種類・落ちたスレッド) だけを載せる
    head -c 6000 "$REPORT" 2>/dev/null | tee -a "$OUT"
    say ""
  done < <(find "$DIR" -maxdepth 1 -name 'Kikimimi*' -mmin -60 2>/dev/null | head -3)
done
[ "$FOUND" = 1 ] || say "(なし)"
say ""

if [ "$CODE" = 0 ]; then
  say "✓ 起動できます。'make run' で起動してください ('open $APP' だけだと、前のものが動いているときは新しく起動しません)。"
else
  say "✗ 起動の確認が失敗しました (終了コード $CODE)。この build/doctor.txt の内容をそのまま報告してください。"
fi
say ""
say "結果: $OUT"
exit "$CODE"
