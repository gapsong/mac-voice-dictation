import AVFoundation
import DictationCore

/// Captures microphone audio via `AVAudioEngine` and converts it to the mono,
/// 16-bit PCM, 16 kHz stream the whisper backend requires.
///
/// The engine's input tap delivers float samples at the hardware sample rate
/// (typically 44.1/48 kHz). An `AVAudioConverter` down-mixes and resamples each
/// tap buffer to 16 kHz mono Int16, accumulating the result so `stop()` can
/// hand back a finished WAV.
final class AudioCapture {

    enum CaptureError: Error {
        case converterUnavailable
        case engineStartFailed(String)
    }

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var accumulated: [Int16] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Begins capturing. Safe to call only after microphone permission is
    /// granted; otherwise the tap yields silence.
    func start() throws {
        lock.lock()
        accumulated.removeAll(keepingCapacity: true)
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)

        guard
            let outFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(WavEncoder.defaultSampleRate),
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outFormat)
        else {
            throw CaptureError.converterUnavailable
        }
        self.outputFormat = outFormat
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.appendConverted(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
        isRecording = true
    }

    /// Stops capture and returns the recorded utterance as a 16 kHz mono WAV,
    /// or `nil` if nothing usable was captured.
    func stop() -> Data? {
        guard isRecording else { return nil }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        let samples = accumulated
        accumulated.removeAll(keepingCapacity: false)
        lock.unlock()

        guard !samples.isEmpty else { return nil }
        return try? WavEncoder.encode(samples: samples)
    }

    // MARK: - Conversion

    private func appendConverted(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let outputFormat else { return }

        // Estimate output capacity from the sample-rate ratio.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
        else { return }

        var fed = false
        let inputBlock: AVAudioConverterInputBlock = { _, statusOut in
            if fed {
                statusOut.pointee = .noDataNow
                return nil
            }
            fed = true
            statusOut.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil,
              let channelData = outBuffer.int16ChannelData else { return }

        let frames = Int(outBuffer.frameLength)
        guard frames > 0 else { return }

        let pointer = channelData[0]
        let slice = Array(UnsafeBufferPointer(start: pointer, count: frames))

        lock.lock()
        accumulated.append(contentsOf: slice)
        lock.unlock()
    }
}
