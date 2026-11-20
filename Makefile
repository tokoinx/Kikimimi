.PHONY: app run doctor install test check-ui check-chat check-llm-queue check-links clean reset

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

check-chat:     ## チャットの答えを本物の LLM で測る (画面は出さない。make check-chat LLM=<モデル.gguf>。先に make app で作っておく)
	@test -n "$(LLM)" || { echo "usage: make check-chat LLM=<model.gguf>"; exit 2; }
	build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-chat "$(LLM)"

check-llm-queue: ## 監査・翻訳の最中にチャットが割り込めるかを本物の LLM で確かめる (画面は出さない。make check-llm-queue LLM=<モデル.gguf> [ADAPTER=<差分.gguf>]。先に make app で作っておく)
	@test -n "$(LLM)" || { echo "usage: make check-llm-queue LLM=<model.gguf> [ADAPTER=<lora.gguf>]"; exit 2; }
	build/Kikimimi.app/Contents/MacOS/Kikimimi --selftest-llm-queue "$(LLM)" $(if $(ADAPTER),--adapter "$(ADAPTER)")

check-links:    ## 文書とアプリが使うリンクが切れていないかを見る (ネットにつなぐ。一覧は tools/check-links/runtime-urls.txt)
	python3 tools/check-links/check_links.py

clean:          ## ビルド成果物を消す
	rm -rf .build build

reset:          ## 依存 (whisper.cpp / llama.cpp) を取り直す
	swift package reset
	rm -rf build
