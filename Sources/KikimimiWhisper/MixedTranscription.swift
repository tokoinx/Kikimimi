import Foundation
import KikimimiCore

/// 「日本語＋英語」の文字起こし (KikimimiCore の MixedPipeline) に、whisper.cpp をつなぐ。
/// 推論は WhisperContext の中で行い、呼び出しはすべて WhisperContext のロックを持ったまま進む
/// (VAD → 判定 → 文字起こし → 点検と直し の途中で、ライブプレビューが割り込まない)。
final class WhisperEngine: MixedEngine {
    private let context: WhisperContext
    private let options: WhisperOptions
    private let shouldCancel: () -> Bool

    init(context: WhisperContext, options: WhisperOptions, shouldCancel: @escaping () -> Bool) {
        self.context = context
        self.options = options
        self.shouldCancel = shouldCancel
    }

    func speechMap(of samples: [Float]) throws -> SpeechMap? {
        try context.speechMap(samples, options: options)
    }

    func detectLanguage(_ samples: [Float], range: Range<Int>, candidates: [String]) throws -> [Float]? {
        if shouldCancel() { throw WhisperError.cancelled }
        return context.detectLanguage(samples, range: range, candidates: candidates, threads: options.threads)
    }

    func decode(_ samples: [Float], range: Range<Int>, language: String, hint: String?, useVAD: Bool,
                onProgress: (Double) -> Void, onSegment: (DecodedSegment) -> Void) throws -> [DecodedSegment] {
        // whisper のコールバックは whisper_full の中でだけ呼ばれる (戻ったあとには残らない)
        try withoutActuallyEscaping(onProgress) { progress in
            try withoutActuallyEscaping(onSegment) { segment in
                try context.decode(samples, range: range, language: language, hint: hint, useVAD: useVAD,
                                   options: options, onProgress: progress, onSegment: segment,
                                   shouldCancel: shouldCancel)
            }
        }
    }
}
