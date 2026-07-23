import Foundation

/// Encodes raw 16-bit PCM samples into a canonical little-endian WAV container.
///
/// The whisper backend expects mono, 16-bit PCM, 16 kHz audio (`Content-Type:
/// audio/wav`). This encoder produces exactly that layout: a 44-byte canonical
/// header (`RIFF`/`WAVE`/`fmt `/`data`, PCM format 1) followed by the sample
/// data. It is deliberately free of any AVFoundation dependency so it can be
/// unit-tested headlessly.
public enum WavEncoder {

    public enum WavError: Error, Equatable {
        case tooManySamples
    }

    /// Default capture format required by the whisper contract.
    public static let defaultSampleRate: UInt32 = 16_000
    public static let defaultChannels: UInt16 = 1
    public static let defaultBitsPerSample: UInt16 = 16

    /// Wraps mono 16-bit PCM samples in a canonical WAV file.
    ///
    /// - Parameters:
    ///   - samples: Interleaved 16-bit PCM samples. For mono this is simply the
    ///     sample stream in capture order.
    ///   - sampleRate: Samples per second (default 16 kHz).
    ///   - channels: Channel count (default 1 / mono).
    /// - Returns: A `Data` blob containing a complete `.wav` file.
    public static func encode(
        samples: [Int16],
        sampleRate: UInt32 = defaultSampleRate,
        channels: UInt16 = defaultChannels
    ) throws -> Data {
        let bitsPerSample = defaultBitsPerSample
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = samples.count * bytesPerSample

        // WAV size fields are unsigned 32-bit; guard against overflow rather
        // than silently truncating (an hour of 16 kHz mono is ~115 MB, so this
        // only trips on pathological input).
        guard dataByteCount <= Int(UInt32.max) - 36 else {
            throw WavError.tooManySamples
        }

        let byteRate = sampleRate * UInt32(channels) * UInt32(bytesPerSample)
        let blockAlign = channels * UInt16(bytesPerSample)

        var data = Data(capacity: 44 + dataByteCount)

        // RIFF chunk descriptor
        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(36 + dataByteCount)) // ChunkSize
        data.append(ascii: "WAVE")

        // fmt sub-chunk
        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16))          // Subchunk1Size (PCM)
        data.append(littleEndian: UInt16(1))           // AudioFormat = PCM
        data.append(littleEndian: channels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)

        // data sub-chunk
        data.append(ascii: "data")
        data.append(littleEndian: UInt32(dataByteCount))
        for sample in samples {
            data.append(littleEndian: UInt16(bitPattern: sample))
        }

        return data
    }
}

private extension Data {
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    mutating func append(littleEndian value: UInt16) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
