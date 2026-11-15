#!/usr/bin/env bash
# 組み立てたアプリを起動する (make run の後半)。
# 動いている「ききみみ」は先に終了させ、必ず新しく起動して、数秒後に動いているかを確かめる。
# (`open build/Kikimimi.app` だけだと、前のものが動いているときは呼び出すだけで、新しい版は起動しない)
set -u
cd "$(dirname "$0")/.."
APP="build/Kikimimi.app"

if [ ! -x "$APP/Contents/MacOS/Kikimimi" ]; then
  echo "✗ $APP がありません。先に make app を実行してください。" >&2
  exit 1
fi

# 画面のある Kikimimi のプロセス番号 (端末から動かす --selftest-… / --eval-llm / --export-training / --version は除く。
# 何分もかかる評価を、make run が途中で止めてしまわないように)
gui_pids() {
  local pid args
  for pid in $(pgrep -x Kikimimi 2>/dev/null); do
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      ""|*--selftest-*|*--eval-llm*|*--export-training*|*--version*) ;;
      *) echo "$pid" ;;
    esac
  done
}

SELFTESTS="$(ps -axo pid=,args= | grep -E '[K]ikimimi.*--(selftest-|eval-llm)' || true)"
if [ -n "$SELFTESTS" ]; then
  echo "▸ 確認用・評価用の実行が動いています (終わるまで Mac が重くなります。止めるときは、その端末で Ctrl-C):"
  echo "$SELFTESTS" | sed 's/^/    /'
fi

OLD="$(gui_pids | tr '\n' ' ')"
if [ -n "${OLD// /}" ]; then
  echo "▸ 起動中の Kikimimi を終了します (PID $OLD)"
  kill -TERM $OLD 2>/dev/null || true
  for _ in $(seq 1 20); do
    [ -z "$(gui_pids)" ] && break
    sleep 0.5
  done
  LEFT="$(gui_pids | tr '\n' ' ')"
  if [ -n "${LEFT// /}" ]; then
    kill -KILL $LEFT 2>/dev/null || true
    sleep 1
  fi
fi

open -n "$APP"

# 起動したか (新しいプロセスができて、数秒後も動いているか) を確かめる
NEW=""
for _ in $(seq 1 30); do
  NEW="$(gui_pids | head -1)"
  [ -n "$NEW" ] && break
  sleep 0.5
done
if [ -n "$NEW" ]; then
  sleep 3
  if kill -0 "$NEW" 2>/dev/null; then
    echo "✓ 起動しました (PID $NEW)"
    exit 0
  fi
fi
echo "✗ 起動していません。原因を調べます (make doctor と同じ)"
Scripts/doctor.sh || true
exit 1
