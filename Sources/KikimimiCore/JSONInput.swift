import Foundation

/// ファイルから読む JSON の見張り。JSONDecoder に渡す前に、ここを通す。
///
/// macOS 14 の JSONDecoder (Foundation) は、名前 (鍵) の文字列が JSON として正しくないと、投げずに落ちる
/// (`Fatal error: 'try!' expression unexpectedly raised an error: ...`)。2026-11-28 に、Swift 6.0.3・macOS 14 で確かめた形:
/// - そのままの制御文字: `{"<0x01>":0}`
/// - UTF-8 として読めないバイト: `{"<0xFF>":0}`
/// - 知らない逃がし・16 進でない `\u`: `{"\q":0}`・`{"\uZZZZ":0}`
/// - 対にならない `\u` のサロゲート: `{"\uD800":0}`・`{"\uDC00":0}`
/// どれも、どの型に読んでも落ちる (値の文字列なら、ふつうに投げる)。保存ファイルの 1 バイトが壊れただけで、
/// アプリが起動のたびに落ちるので、読む前に、文字列を全部 (名前も値も) JSON の決まりで確かめて断る。
/// 断る物は、どれも値の中なら JSONDecoder も投げる物なので、読めるファイルは減らない
public enum JSONInput {
    /// JSON として読めない所が在る時に投げる (読めないファイルと同じ扱いになる)
    public struct Unreadable: Error, Equatable {
        /// 見つけた所 (バイトの位置。UTF-8 として読めない時は -1)
        public let offset: Int
    }

    /// 見張りを通してから読む
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, with decoder: JSONDecoder) throws -> T {
        if let offset = problemOffset(in: data) { throw Unreadable(offset: offset) }
        return try decoder.decode(type, from: data)
    }

    /// JSON の決まりに合わない所の位置 (無ければ nil)。見るのは:
    /// UTF-8 として読めるか、文字列の外の制御文字 (空白のタブ・改行・復帰を除く)、
    /// 文字列の中の制御文字・逃がし (`\` の後ろ)・`\u` の 16 進とサロゲートの対
    public static func problemOffset(in data: Data) -> Int? {
        guard String(data: data, encoding: .utf8) != nil else { return -1 }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 0
            var inString = false
            // 直前の `\u` が、対の前の半分 (D800〜DBFF) だったか
            var wantsLowSurrogate = false
            func hexUnit(at start: Int) -> Int? {
                guard start + 4 <= count else { return nil }
                var value = 0
                for k in start..<(start + 4) {
                    let b = bytes[k]
                    let digit: Int
                    switch b {
                    case 0x30...0x39: digit = Int(b) - 0x30
                    case 0x41...0x46: digit = Int(b) - 0x41 + 10
                    case 0x61...0x66: digit = Int(b) - 0x61 + 10
                    default: return nil
                    }
                    value = value * 16 + digit
                }
                return value
            }
            while i < count {
                let b = bytes[i]
                if !inString {
                    if b == 0x22 {
                        inString = true
                    } else if b < 0x20, b != 0x09, b != 0x0A, b != 0x0D {
                        return i
                    }
                    i += 1
                    continue
                }
                if b == 0x5C { // バックスラッシュ
                    guard i + 1 < count else { return i }
                    let next = bytes[i + 1]
                    if next == 0x75 { // u
                        guard let unit = hexUnit(at: i + 2) else { return i }
                        let isHigh = (0xD800...0xDBFF).contains(unit)
                        let isLow = (0xDC00...0xDFFF).contains(unit)
                        if wantsLowSurrogate != isLow { return i }
                        wantsLowSurrogate = isHigh
                        i += 6
                        continue
                    }
                    guard !wantsLowSurrogate, [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(next) else { return i }
                    i += 2
                    continue
                }
                // 対の前の半分の後ろに、`\u` の後ろの半分が来ていない
                if wantsLowSurrogate { return i }
                if b == 0x22 {
                    inString = false
                } else if b < 0x20 {
                    return i
                }
                i += 1
            }
            // 文字列の途中で終わっている (閉じる `"` が無い) 物も、JSON ではないので断る
            return inString ? count : nil
        }
    }
}
