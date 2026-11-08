import Foundation

/// 16-bit PCM の WAV を読み書きする (録音の保存とテスト用)。
public enum WAV {
    public enum DecodeError: Error, Equatable {
        case notWAV
        case unsupported(String)
    }

    /// [-1, 1] の Float 列を 16-bit モノラル WAV にする。
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                              // PCM
        u16(1)                              // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))         // byte rate
        u16(2)                              // block align
        u16(16)                             // bits per sample
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        data.reserveCapacity(data.count + dataBytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let clipped = max(-1, min(1, s))
            pcm[i] = Int16((clipped * 32767).rounded())
        }
        pcm.withUnsafeBytes { raw in
            if Int16(littleEndian: 1) == 1 {
                data.append(contentsOf: raw)
            } else {
                for v in pcm { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
            }
        }
        return data
    }

    /// 16-bit PCM WAV を読み、モノラルにまとめた Float 列とサンプルレートを返す。
    public static func decode(_ data: Data) throws -> (samples: [Float], sampleRate: Int) {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { UInt32(bytes[o]) | UInt32(bytes[o+1]) << 8 | UInt32(bytes[o+2]) << 16 | UInt32(bytes[o+3]) << 24 }
        func u16(_ o: Int) -> UInt16 { UInt16(bytes[o]) | UInt16(bytes[o+1]) << 8 }
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WAVE".utf8) else {
            throw DecodeError.notWAV
        }
        var offset = 12
        var channels = 0, rate = 0, bits = 0, format = 0
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset+4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == "fmt " {
                guard body + 16 <= bytes.count else { throw DecodeError.notWAV }
                format = Int(u16(body)); channels = Int(u16(body + 2)); rate = Int(u32(body + 4)); bits = Int(u16(body + 14))
            } else if id == "data" {
                guard format == 1 || format == 0xFFFE, bits == 16, channels > 0 else {
                    throw DecodeError.unsupported("format=\(format) bits=\(bits) ch=\(channels)")
                }
                let end = min(bytes.count, body + size)
                let frames = (end - body) / (2 * channels)
                var out = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    var acc: Float = 0
                    for c in 0..<channels {
                        let o = body + (f * channels + c) * 2
                        acc += Float(Int16(bitPattern: u16(o))) / 32768
                    }
                    out[f] = acc / Float(channels)
                }
                return (out, rate)
            }
            offset = body + size + (size & 1)
        }
        throw DecodeError.notWAV
    }
}
