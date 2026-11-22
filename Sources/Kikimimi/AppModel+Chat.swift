// チャットの所: LLM を走らせる口と、チャットから設定を読み書きする表。

import Foundation
import KikimimiCore
import KikimimiLLM

extension AppModel {
    // MARK: チャット (LLM)

    /// チャットの答えを、選んでいる LLM で出す。差分 (adapter) は渡さない (監査・翻訳を学んだ差分なので)。
    /// 監査・翻訳が同じモデルを差分なしで使っている最中なら、その合間 (かたまりの `generate` の手前) に先に通る。
    /// 監査・翻訳が差分を使っている時・別のモデルの時は、今までどおり、それらが終わるまで待つ
    func runChatLLM(shouldCancel: @escaping @Sendable () -> Bool,
                    _ body: @escaping (LlamaEngine) throws -> String) async throws -> String {
        try await llm.runInteractive(modelPath: currentLLM.url.path, shouldCancel: shouldCancel, body)
    }

    /// チャットの窓を閉じた時: 監査・翻訳の仕事が無ければ、LLM を手放す (数 GB のメモリを空ける)
    func releaseLLMAfterChat() {
        guard worker == nil, !chat.isAnswering else { return }
        llm.unload()
    }

    /// チャットから変える案を出せる設定の一覧
    var chatCatalog: [ChatSettingItem] { ChatSettingsCatalog.items() }

    /// チャットに見せる、今の設定の値 (`ChatSettingsAccess` の形。toggle は "on" / "off")。一覧に無い鍵は nil
    func currentValue(for key: String) -> String? {
        guard let setting = SettingKey(rawValue: key) else { return nil }
        return chatAccess(setting)?.get()
    }

    /// チャットから設定 1 つを読み書きする口 (値はチャットの書き方。toggle は "on" / "off")
    private struct ChatAccess {
        let get: () -> String
        /// 当てたら true。値は `normalizedValue` で確かめた後の物
        let set: (String) -> Bool
    }

    /// 設定ごとに、どのプロパティを読み書きするか。nil は、チャットから触れない物。
    /// 設定を足したら、ここに足す (足し忘れは、コンパイルが止める)。
    /// 書くのは、設定の画面と同じ道 (このモデルの値を変える。didSet が保存する)
    private func chatAccess(_ key: SettingKey) -> ChatAccess? {
        // 入り切り: "on" / "off" と Bool の橋渡し
        func toggle(_ path: ReferenceWritableKeyPath<AppModel, Bool>) -> ChatAccess {
            ChatAccess(get: { self[keyPath: path] ? "on" : "off" },
                       set: { value in
                           self[keyPath: path] = value == "on"
                           return true
                       })
        }
        // 文: 当てる前の確かめ (`accepts`) が通った時だけ当てる
        func text(_ path: ReferenceWritableKeyPath<AppModel, String>,
                  accepts: @escaping (String) -> Bool = { _ in true }) -> ChatAccess {
            ChatAccess(get: { self[keyPath: path] },
                       set: { value in
                           guard accepts(value) else { return false }
                           self[keyPath: path] = value
                           return true
                       })
        }
        switch key {
        case .uiLanguage:
            // 設定の画面と同じ: didSet が文を引き直し、保存し、開き直しの案内の印を立てる
            return ChatAccess(get: { self.uiLanguage.rawValue },
                              set: { value in
                                  guard let language = UILanguage(rawValue: value) else { return false }
                                  self.uiLanguage = language
                                  return true
                              })
        case .languageCode: return text(\.languageCode, accepts: { Languages.isKnown($0) })
        // 設定の画面と同じ: 入っていないモデルも選べる (使う時に取得する)
        case .modelID: return text(\.modelID, accepts: { ModelCatalog.spec(id: $0) != nil })
        case .preferAccuracy: return toggle(\.preferAccuracy)
        case .useVAD: return toggle(\.useVAD)
        case .autoVADOff: return toggle(\.autoVADOff)
        case .filterHallucinations: return toggle(\.filterHallucinations)
        case .autoMixedLanguage: return toggle(\.autoMixedLanguage)
        case .livePreview: return toggle(\.livePreview)
        case .initialPrompt: return text(\.initialPrompt)
        // 設定の画面と同じ: didSet が差分の有無を読み直す。入っていないモデルも選べる
        case .llmModelID: return text(\.llmModelID, accepts: { LLMCatalog.spec(id: $0) != nil })
        case .autoAudit: return toggle(\.autoAudit)
        case .translationLanguage: return text(\.translationLanguage, accepts: { TranslationTarget.all.contains($0) })
        case .autoTranslate: return toggle(\.autoTranslate)
        case .useLedger: return toggle(\.useLedger)
        case .reuseTranslationMemory: return toggle(\.reuseTranslationMemory)
        case .useAdapter: return toggle(\.useAdapter)
        // 結果の画面の「対訳」のチェックと同じ: 選んでいる結果が在れば、その結果の見え方 (設定が入、または行の「訳」の印) を読み、
        // 同じ道 (setShowsBilingual。切にすると、その結果の印も消す) で書く。選んでいる結果が無ければ、設定の値
        case .showBilingual:
            return ChatAccess(get: {
                                  let on = self.selectedJob.map { self.showsBilingual($0) } ?? self.showBilingual
                                  return on ? "on" : "off"
                              },
                              set: { value in
                                  if let job = self.selectedJob {
                                      self.setShowsBilingual(value == "on", for: job)
                                  } else {
                                      self.showBilingual = value == "on"
                                  }
                                  return true
                              })
        case .showNotes: return toggle(\.showNotes)
        case .practiceDictation: return toggle(\.practice.showsDictation)
        // チャットから触れない物 (ChatSettingsCatalog.excludedKeys にも入っている)
        case .notesWidth, .practice: return nil
        }
    }

    /// 今、この設定を変えられるか。変えられない時は、その理由 (変えられる時は nil)。
    /// 設定の画面の部品を押せなくするのも、チャットの札に「変える」を出さないのも、`applyChatSetting` が断るのも、これを使う。
    /// 設定を足したら、ここで決める (決め忘れは、コンパイルが止める)
    func unavailableReason(for key: SettingKey) -> SettingUnavailableReason? {
        switch key {
        // 無音を飛ばすが切の時は、「自動でやり直す」は働かない
        case .autoVADOff: return useVAD ? nil : .needsOn(.useVAD)
        // 差分が 1 つも入っていない時は、「差分を使う」は働かない
        case .useAdapter: return hasAdapter || hasTranslationAdapter ? nil : .noAdapter
        case .uiLanguage, .languageCode, .modelID, .preferAccuracy, .useVAD, .filterHallucinations,
             .autoMixedLanguage, .livePreview, .initialPrompt, .llmModelID, .autoAudit, .translationLanguage,
             .autoTranslate, .useLedger, .reuseTranslationMemory, .showBilingual, .showNotes, .notesWidth,
             .practice, .practiceDictation:
            return nil
        }
    }

    /// 今の設定の値の写し (LLM のスレッドで読むので、メインで写しておく)
    func chatSettingsSnapshot() -> ChatSettingsSnapshot {
        var values: [String: String] = [:]
        for item in chatCatalog {
            if let value = currentValue(for: item.key) { values[item.key] = value }
        }
        return ChatSettingsSnapshot(values: values)
    }

    /// チャットの案を当てる (利用者が札の「変える」を押した時だけ呼ぶ)。当てたら true。
    /// 一覧に在る鍵だけを、値をもう 1 回確かめてから、設定の画面と同じ道 (このモデルの値を変える。didSet が保存する) で当てる。
    /// リサーチの鍵と、一覧に無い鍵と、今は変えられない設定 (`unavailableReason(for:)`) は、必ず断る
    func applyChatSetting(key: String, value raw: String) -> Bool {
        guard key != ChatSettingsCatalog.researchKey, !ChatSettingsCatalog.excludedKeys.contains(key),
              let item = chatCatalog.first(where: { $0.key == key }),
              let value = item.normalizedValue(raw),
              let setting = SettingKey(rawValue: key), unavailableReason(for: setting) == nil,
              let access = chatAccess(setting) else { return false }
        return access.set(value)
    }
}
