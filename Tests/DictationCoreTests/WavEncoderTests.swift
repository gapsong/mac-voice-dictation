import Testing
import Foundation
@testable import DictationCore

/// Reads a little-endian UInt32 at a byte offset.
private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for i in 0..<4 { value |= UInt32(data[offset + i]) << (8 * i) }
    return value
}

/// Reads a little-endian UInt16 at a byte offset.
private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
    var value: UInt16 = 0
    for i in 0..<2 { value |= UInt16(data[offset + i]) << (8 * i) }
    return value
}

private func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
    String(decoding: data.subdata(in: offset..<offset + length), as: UTF8.self)
}

@Suite struct WavEncoderTests {

    @Test func headerIsCanonical16kHzMono16Bit() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768, 100, -100, 5000]
        let data = try WavEncoder.encode(samples: samples)

        // Total size = 44-byte header + 2 bytes per sample.
        #expect(data.count == 44 + samples.count * 2)

        // Chunk tags.
        #expect(ascii(data, 0, 4) == "RIFF")
        #expect(ascii(data, 8, 4) == "WAVE")
        #expect(ascii(data, 12, 4) == "fmt ")
        #expect(ascii(data, 36, 4) == "data")

        // ChunkSize = 36 + dataBytes.
        #expect(readU32(data, 4) == UInt32(36 + samples.count * 2))

        // Subchunk1Size = 16, AudioFormat = 1 (PCM).
        #expect(readU32(data, 16) == 16)
        #expect(readU16(data, 20) == 1)

        // NumChannels = 1 (mono).
        #expect(readU16(data, 22) == 1)

        // SampleRate = 16000.
        #expect(readU32(data, 24) == 16_000)

        // ByteRate = SampleRate * Channels * BytesPerSample = 16000 * 1 * 2.
        #expect(readU32(data, 28) == 32_000)

        // BlockAlign = Channels * BytesPerSample = 2.
        #expect(readU16(data, 32) == 2)

        // BitsPerSample = 16.
        #expect(readU16(data, 34) == 16)

        // Subchunk2Size = dataBytes.
        #expect(readU32(data, 40) == UInt32(samples.count * 2))
    }

    @Test func sampleDataIsLittleEndianAndInOrder() throws {
        let samples: [Int16] = [0, 1, -1, 32767, -32768]
        let data = try WavEncoder.encode(samples: samples)

        for (index, sample) in samples.enumerated() {
            let offset = 44 + index * 2
            let decoded = Int16(bitPattern: readU16(data, offset))
            #expect(decoded == sample)
        }
    }

    @Test func customSampleRateIsHonored() throws {
        let data = try WavEncoder.encode(samples: [1, 2, 3], sampleRate: 48_000)
        #expect(readU32(data, 24) == 48_000)
        #expect(readU32(data, 28) == 96_000) // 48000 * 1 * 2
    }

    @Test func emptySamplesProduceHeaderOnly() throws {
        let data = try WavEncoder.encode(samples: [])
        #expect(data.count == 44)
        #expect(readU32(data, 40) == 0)
    }
}
