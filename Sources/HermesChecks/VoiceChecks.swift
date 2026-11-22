@preconcurrency import AVFAudio
import Foundation
import HermesKit

/// TTS -> 16 kHz -> VAD + on-device STT round trip. No mic, speakers or screen needed. HERMES_CHECK_VOICE=1.
func runVoiceChecks() {
    guard ProcessInfo.processInfo.environment["HERMES_CHECK_VOICE"] == "1" else { return }
    var done = false
    Task {
        await asyncCheck("voice tts->vad->stt round trip") {
            let sentence = "Schedule a weekly review every Friday at four."
            let buf = try await SystemVoice(voiceIdentifier: nil).render(sentence)
            let samples = try to16k(buf)
            expect(samples.count > 16_000, "tts too short: \(samples.count)")
            // Pad with quiet noise so the VAD sees a floor, a start and an end.
            var noise: [Float] = (0..<24_000).map { _ in Float.random(in: -0.002...0.002) }
            let padded = noise + samples + noise
            var vad = VAD(); var hp = 0
            var events: [VAD.Event] = []
            for i in stride(from: 0, to: padded.count - 320, by: 320) {
                let f = padded[i..<(i + 320)]
                let rms = sqrt(f.reduce(0) { $0 + Double($1 * $1) } / 320)
                if let e = vad.frame(rms: rms) { events.append(e) }
                hp += 1
            }
            noise.removeAll()
            expect(events.first == .start && events.contains(.end), "vad events \(events)")
            let text = try await AppleTranscriber(locale: Locale(identifier: "en_US")).transcribe(samples)
            print("  stt heard: \(text)")
            let lower = text.lowercased()
            expect(lower.contains("friday") && lower.contains("review"), "stt: \(text)")
        }
        done = true
    }
    waitPumpingRunLoop { done }
}

func to16k(_ buf: AVAudioPCMBuffer) throws -> [Float] {
    guard let conv = AVAudioConverter(from: buf.format, to: speechFormat),
          let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16_000 / buf.format.sampleRate) + 1024)
    else { throw STTError(message: "converter") }
    var fed = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, st in
        if fed { st.pointee = .endOfStream; return nil }
        fed = true; st.pointee = .haveData; return buf
    }
    if let err { throw err }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}
