.PHONY: app run doctor install test check-ui clean reset

app:            ## Kikimimi.app を build/ に作る
	Scripts/build-app.sh

run: app        ## ビルドして起動 (起動中の Kikimimi は先に終了させ、起動できたかを確かめる)
	@Scripts/run-app.sh

doctor:         ## 起動しないときの診断 (結果は build/doctor.txt)
	@Scripts/doctor.sh

install: app    ## /Applications にコピー
	rm -rf /Applications/Kikimimi.app
	ditto build/Kikimimi.app /Applications/Kikimimi.app
	@echo "✓ /Applications/Kikimimi.app"

test:           ## コアのユニットテスト
	swift test

check-ui:       ## アプリの確認 (3000 行・1 行の再生・練習。ウインドウが開き、音が鳴る。先に make app で作っておく)
	build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-ui-load 3000 --audio Tests/Fixtures/mixed-en-ja.wav --screenshots build/ui-shots

clean:          ## ビルド成果物を消す
	rm -rf .build build

reset:          ## 依存 (whisper.cpp / llama.cpp) を取り直す
	swift package reset
	rm -rf build
