import Foundation

/// llama.cpp の入れ物 (batch) に入れた時と、計算 (`llama_process`) の戻り値を見て、失敗なら `LLMError.decodeFailed` を投げる。
///
/// `LlamaEngine` (KikimimiLLM) が、トークンを 1 つ入れるたび・1 回計算するたびに呼ぶ。
/// llama.cpp を読み込まずに、番号の決まり (どの失敗がどの番号になるか) を試験で確かめられるように、ここに置く。
/// 毎トークン呼ぶので、静的な関数だけにする (クロージャや包みは使わない)
public enum LLMBatchCheck {
    /// 位置を入れられなかった時の番号 (llama.cpp には無い、このアプリが決めた番号)
    public static let positionFailedCode: Int32 = -100
    /// 出力の印を入れられなかった時の番号 (llama.cpp には無い、このアプリが決めた番号)
    public static let outputFailedCode: Int32 = -101

    /// `llama_batch_ext_add_token` の戻り値を見る。0 以上は入れた場所の番号なので、そのまま返す。
    /// 負の数は失敗で、その番号のまま投げる (-1 = 入れ物が一杯、-2 = トークンが無効、-3 = 列の番号が無効)
    @inlinable
    public static func added(_ index: Int32) throws -> Int32 {
        guard index >= 0 else { throw LLMError.decodeFailed(index) }
        return index
    }

    /// `llama_batch_ext_set_pos` の結果を見る。入れられなかったら -100 を投げる
    @inlinable
    public static func positionSet(_ ok: Bool) throws {
        guard ok else { throw LLMError.decodeFailed(positionFailedCode) }
    }

    /// `llama_batch_ext_set_output_logits` の結果を見る。入れられなかったら -101 を投げる
    @inlinable
    public static func outputMarked(_ ok: Bool) throws {
        guard ok else { throw LLMError.decodeFailed(outputFailedCode) }
    }

    /// `llama_process` の戻り値を見る。0 以外は失敗で、その番号のまま投げる
    @inlinable
    public static func processed(_ rc: Int32) throws {
        guard rc == 0 else { throw LLMError.decodeFailed(rc) }
    }
}
