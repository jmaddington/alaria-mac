@preconcurrency import AVFAudio
import Foundation
import Speech
import os

private let log = Logger(subsystem: "net.jmaddington.hermes", category: "voice-speech")

// MARK: - Speech to text

public protocol SpeechToText: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

public struct STTError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// OpenAI-compatible /v1/audio/transcriptions (drive mode's default path: model gpt-transcribe, language en, prompt).
public struct OpenAITranscriber: SpeechToText {
    public var apiKey: String
    public var model: String
    public var prompt: String
    public var url: URL

    public init(apiKey: String, model: String = "gpt-transcribe", prompt: String = "",
                url: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!) {
        self.apiKey = apiKey; self.model = model; self.prompt = prompt; self.url = url
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        let boundary = UUID().uuidString
        var body = Data()
        for (k, v) in [("model", model), ("language", "en"), ("prompt", prompt)] where !v.isEmpty {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"u.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData(samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            // The status alone said nothing in drive mode (#20); the provider body says why. Never log the key.
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            log.error("stt http \(code) body=\(detail, privacy: .public) [VOX-STT-HTTP]")
            throw STTError(message: "Transcription failed (\(code))")
        }
        struct R: Decodable { let text: String? }
        return (try JSONDecoder().decode(R.self, from: data).text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Apple on-device SpeechTranscriber (macOS 26+). Same engine Murmur uses; no audio leaves the Mac.
public struct AppleTranscriber: SpeechToText {
    public var locale: Locale
    public init(locale: Locale = .current) { self.locale = locale }

    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw STTError(message: "\(locale.identifier) isn't supported for on-device speech")
        }
        let module = SpeechTranscriber(locale: loc, preset: .transcription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await req.downloadAndInstall()
        }
        guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: speechFormat) else {
            throw STTError(message: "No audio format for the speech model")
        }
        guard let src = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw STTError(message: "Audio buffer allocation failed")
        }
        src.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in src.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
        let input: AVAudioPCMBuffer
        if fmt == speechFormat { input = src } else {
            guard let conv = AVAudioConverter(from: speechFormat, to: fmt),
                  let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(samples.count) * fmt.sampleRate / 16_000) + 64)
            else { throw STTError(message: "Audio conversion unavailable") }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, st in
                if fed { st.pointee = .endOfStream; return nil }
                fed = true; st.pointee = .haveData; return src
            }
            if let err { throw err }
            input = out
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { () -> String in
            var parts: [String] = []
            for try await r in module.results where r.isFinal { parts.append(String(r.text.characters)) }
            return parts.joined(separator: " ")
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        cont.yield(AnalyzerInput(buffer: input))
        cont.finish()
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await results.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Text to speech

public protocol TextToSpeech: Sendable {
    /// Renders one sentence to PCM. Rendering is separate from playback so the next sentence can be prefetched
    /// while the current one plays (drive-mode lesson: sequential fetch-then-play left audible gaps).
    func render(_ sentence: String) async throws -> AVAudioPCMBuffer
}

/// Native voices, including Premium/Enhanced ones the user downloaded in System Settings > Accessibility.
public final class SystemVoice: TextToSpeech, @unchecked Sendable {
    private let voiceID: String?
    private let rate: Float
    public init(voiceIdentifier: String?, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
        self.voiceID = voiceIdentifier; self.rate = rate
    }

    public static func voices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(Locale.current.language.languageCode?.identifier ?? "en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    public func render(_ sentence: String) async throws -> AVAudioPCMBuffer {
        let synth = AVSpeechSynthesizer()
        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? SystemVoice.voices().first
        utt.rate = rate
        return try await withCheckedThrowingContinuation { c in
            var chunks: [AVAudioPCMBuffer] = []
            var done = false
            synth.write(utt) { buf in
                guard !done, let pcm = buf as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { // end marker
                    done = true
                    if let joined = Self.concat(chunks) { c.resume(returning: joined) }
                    else { c.resume(throwing: STTError(message: "Voice produced no audio")) }
                    _ = synth // keep the synthesizer alive until the callback finishes
                    return
                }
                chunks.append(pcm)
            }
        }
    }

    static func concat(_ bufs: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = bufs.first else { return nil }
        let total = bufs.reduce(0) { $0 + $1.frameLength }
        guard let out = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: total) else { return nil }
        for b in bufs {
            let ch = Int(first.format.channelCount)
            for c in 0..<ch {
                if let src = b.floatChannelData?[c], let dst = out.floatChannelData?[c] {
                    (dst + Int(out.frameLength)).update(from: src, count: Int(b.frameLength))
                } else if let src = b.int16ChannelData?[c], let dst = out.int16ChannelData?[c] {
                    (dst + Int(out.frameLength)).update(from: src, count: Int(b.frameLength))
                }
            }
            out.frameLength += b.frameLength
        }
        return out
    }
}

/// OpenAI-compatible /v1/audio/speech.
public struct OpenAIVoice: TextToSpeech {
    public var apiKey: String, model: String, voice: String, instructions: String
    public var url: URL
    public init(apiKey: String, model: String = "gpt-4o-mini-tts", voice: String = "onyx", instructions: String = "",
                url: URL = URL(string: "https://api.openai.com/v1/audio/speech")!) {
        self.apiKey = apiKey; self.model = model; self.voice = voice; self.instructions = instructions; self.url = url
    }

    public func render(_ sentence: String) async throws -> AVAudioPCMBuffer {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["model": model, "voice": voice, "input": sentence, "response_format": "wav"]
        if !instructions.isEmpty { body["instructions"] = instructions }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            log.error("tts http \(code) body=\(String(data: data.prefix(300), encoding: .utf8) ?? "", privacy: .public) [VOX-TTS-HTTP]")
            throw STTError(message: "Speech synthesis failed (\(code))")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-tts-\(UUID().uuidString).wav")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forReading: tmp)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw STTError(message: "Audio buffer allocation failed")
        }
        try file.read(into: buf)
        return buf
    }
}
