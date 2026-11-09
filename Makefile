.PHONY: app run install test clean reset

app:            ## Kikimimi.app を build/ に作る
	Scripts/build-app.sh

run: app        ## ビルドして起動 (起動中の Kikimimi は先に終了させる)
	@if pgrep -x Kikimimi >/dev/null; then \
		echo "▸ 起動中の Kikimimi を終了します"; \
		pkill -TERM -x Kikimimi || true; \
		for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Kikimimi >/dev/null || break; sleep 0.5; done; \
		pkill -KILL -x Kikimimi 2>/dev/null || true; \
		sleep 0.5; \
	fi
	open build/Kikimimi.app

install: app    ## /Applications にコピー
	rm -rf /Applications/Kikimimi.app
	ditto build/Kikimimi.app /Applications/Kikimimi.app
	@echo "✓ /Applications/Kikimimi.app"

test:           ## コアのユニットテスト
	swift test

clean:          ## ビルド成果物を消す
	rm -rf .build build

reset:          ## 依存 (whisper.cpp / llama.cpp) を取り直す
	swift package reset
	rm -rf build
