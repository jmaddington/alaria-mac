@preconcurrency import AVFAudio
import Foundation
import os

private let audioLog = Logger(subsystem: "net.jmaddington.hermes", category: "voice-audio")

/// 16 kHz mono Float32: what the VAD and every STT engine consume.
public let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

/// RBJ biquad. Only used to band-pass the VAD level (drive mode: highpass 300 Hz, lowpass 3400 Hz).
struct Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    init(highpass f: Double, sr: Double) { self.init(f: f, sr: sr, high: true) }
    init(lowpass f: Double, sr: Double) { self.init(f: f, sr: sr, high: false) }
    private init(f: Double, sr: Double, high: Bool) {
        let w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        if high { b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2 } else { b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2 }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 = -2 * c / a0; a2 = (1 - alpha) / a0
    }
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// One AVAudioEngine for mic AND playback. Playback must go through the same engine as the input so Apple's
/// voice processing (AEC) has the reference signal; that is what makes barge-in possible without hearing itself.
// AIDEV-NOTE: callbacks (`onFrame`) fire on the audio tap thread. All mutable state behind `lock`.
public final class VoiceAudio: @unchecked Sendable {
    /// 20 ms frame: (band-passed RMS, raw 16 kHz samples of that frame). Tap thread.
    public var onFrame: ((Double, [Float]) -> Void)?
    public var onFailure: ((String) -> Void)?
    public private(set) var echoCancelling = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let tonePlayer = AVAudioPlayerNode()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var pending: [Float] = []
    private var hp = Biquad(highpass: 300, sr: 16_000)
    private var lp = Biquad(lowpass: 3400, sr: 16_000)
    private var playbackFormat: AVAudioFormat { engine.mainMixerNode.outputFormat(forBus: 0) }
    private var configObserver: NSObjectProtocol?

    public init() {}

    public func start(voiceProcessing: Bool) throws {
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Ducking other apps (music) to near silence while listening is hostile on a desktop.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: true, duckingLevel: .min)
                echoCancelling = true
            } catch {
                audioLog.error("voice processing unavailable: \(error.localizedDescription, privacy: .public) [VOX-AEC-OFF]")
                echoCancelling = false
            }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "Hermes", code: 1, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input"])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: speechFormat) else {
            throw NSError(domain: "Hermes", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported mic format \(inFormat)"])
        }
        if inFormat.channelCount > 1 { conv.downmix = true }
        converter = conv

        engine.attach(player)
        engine.attach(tonePlayer)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.connect(tonePlayer, to: engine.mainMixerNode, format: playbackFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buf, _ in self?.ingest(buf) }
        engine.prepare()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, !self.engine.isRunning else { return }
            audioLog.error("audio engine stopped after config change [VOX-ENGINE-LOST]")
            self.onFailure?("Audio device changed")
        }
    }

    public func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop(); tonePlayer.stop()
        engine.stop()
        if echoCancelling { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let conv = converter; lock.unlock()
        guard let conv else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        var frames: [(Double, [Float])] = []
        lock.lock()
        pending.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        while pending.count >= 320 { // 20 ms at 16 kHz
            let f = Array(pending[0..<320]); pending.removeFirst(320)
            var sum = 0.0
            for s in f { let y = lp.process(hp.process(Double(s))); sum += y * y }
            frames.append((sqrt(sum / 320), f))
        }
        lock.unlock()
        for (r, f) in frames { onFrame?(r, f) }
    }

    // MARK: playback

    /// Plays a PCM buffer in any format; returns when it finishes or is stopped.
    public func play(_ buffer: AVAudioPCMBuffer) async {
        guard let pcm = convertForPlayback(buffer) else { return }
        if !player.isPlaying { player.play() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in c.resume() }
        }
    }

    /// Stops whatever is playing now (barge-in / hold-to-stop). Pending `play` calls return immediately.
    public func stopPlayback() {
        player.stop() // fires the pending completion callbacks, so awaiting `play` calls return
    }

    public var isPlaying: Bool { player.isPlaying }

    private func convertForPlayback(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = playbackFormat
        if buffer.format == target { return buffer }
        guard let conv = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        return err == nil ? out : nil
    }

    // MARK: earcons (drive mode's tone vocabulary)

    /// Sine with exponential decay, like the drive-mode page's `tone(f, ms, g, at)`.
    public func tone(_ freq: Double, ms: Double, gain: Float = 0.12, delayMs: Double = 0) {
        let fmt = playbackFormat
        let sr = fmt.sampleRate
        let lead = Int(sr * delayMs / 1000), n = Int(sr * ms / 1000)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(lead + n)) else { return }
        buf.frameLength = AVAudioFrameCount(lead + n)
        for c in 0..<Int(fmt.channelCount) {
            guard let p = buf.floatChannelData?[c] else { continue }
            for i in 0..<lead { p[i] = 0 }
            for i in 0..<n {
                let t = Double(i) / sr
                let env = Float(exp(log(0.0001 / Double(gain)) * Double(i) / Double(n))) * gain
                p[lead + i] = Float(sin(2 * .pi * freq * t)) * env
            }
        }
        if !tonePlayer.isPlaying { tonePlayer.play() }
        tonePlayer.scheduleBuffer(buf, completionHandler: nil)
    }
}

public enum Earcon {
    case heard, nothingUsable, thinkingTick, disconnected, reconnected, sentenceLost, muted, unmuted, stopped, ready
    public func play(on a: VoiceAudio) {
        switch self {
        case .heard: a.tone(660, ms: 90); a.tone(880, ms: 90, delayMs: 100) // "got it", before the round trip
        case .nothingUsable: a.tone(220, ms: 180)
        case .thinkingTick: a.tone(440, ms: 60, gain: 0.05)
        case .disconnected: a.tone(180, ms: 500)
        case .reconnected: a.tone(880, ms: 120)
        case .sentenceLost: a.tone(200, ms: 90, gain: 0.1); a.tone(200, ms: 90, gain: 0.1, delayMs: 150)
        case .muted: a.tone(300, ms: 120)
        case .unmuted: a.tone(600, ms: 120)
        case .stopped: a.tone(250, ms: 150)
        case .ready: a.tone(660, ms: 120)
        }
    }
}

/// Builds the 16 kHz mono 16-bit WAV the STT providers accept (same as the drive-mode page uploads).
public func wavData(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    return d
}
