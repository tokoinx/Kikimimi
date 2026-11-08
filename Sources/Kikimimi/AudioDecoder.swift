import AVFoundation
import Foundation
import KikimimiCore

/// 音声・動画ファイルを whisper.cpp が受け取れる 16 kHz モノラル Float に変換する。
enum AudioDecoder {
    static let sampleRate: Double = 16_000

    enum DecodeError: LocalizedError {
        case noAudioTrack(String)
        case cannotRead(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack(let name): return "「\(name)」に音声トラックがありません。"
            case .cannotRead(let name): return "「\(name)」を音声として読み込めませんでした。対応していない形式の可能性があります。"
            }
        }
    }

    static func decode(url: URL, cancelFlag: CancelFlag? = nil) async throws -> [Float] {
        let name = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw DecodeError.cannotRead(name)
        }
        guard !tracks.isEmpty else { throw DecodeError.noAudioTrack(name) }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[Float], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try readPCM(asset: asset, tracks: tracks, name: name, cancelFlag: cancelFlag))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func readPCM(asset: AVAsset, tracks: [AVAssetTrack], name: String, cancelFlag: CancelFlag?) throws -> [Float] {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw DecodeError.cannotRead(name)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecodeError.cannotRead(name) }
        reader.add(output)
        guard reader.startReading() else { throw DecodeError.cannotRead(name) }

        var samples: [Float] = []
        let floatSize = MemoryLayout<Float>.size
        while let sampleBuffer = output.copyNextSampleBuffer() {
            if cancelFlag?.isSet == true {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let count = CMBlockBufferGetDataLength(block) / floatSize
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(Float(0), count: count))
            let status: OSStatus = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * floatSize,
                                           destination: raw.baseAddress!.advanced(by: start * floatSize))
            }
            guard status == kCMBlockBufferNoErr else { throw DecodeError.cannotRead(name) }
        }
        if reader.status == .failed {
            throw DecodeError.cannotRead(name)
        }
        return samples
    }
}
