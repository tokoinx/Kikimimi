.PHONY: app run doctor install test clean reset

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

clean:          ## ビルド成果物を消す
	rm -rf .build build

reset:          ## 依存 (whisper.cpp / llama.cpp) を取り直す
	swift package reset
	rm -rf build
