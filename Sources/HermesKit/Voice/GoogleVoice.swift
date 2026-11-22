import AVFAudio
import Foundation
import os

private let glog = Logger(subsystem: "net.jmaddington.hermes", category: "voice-google")

/// Google Cloud Text-to-Speech (`text:synthesize`), defaulting to the Chirp 3 HD voices.
/// Auth is an API key restricted to the Text-to-Speech API. Returns LINEAR16 WAV at 24 kHz.
// AIDEV-NOTE: Foundation + AVFAudio only; HermesKit is also compiled for iOS by the hermes-ios project.
public struct GoogleVoice: TextToSpeech {
    public var apiKey: String
    /// Full voice name, e.g. "en-US-Chirp3-HD-Aoede". The language code is derived from it.
    public var voice: String
    /// 1.0 = normal (Cloud TTS accepts 0.25-2.0).
    public var speakingRate: Double
    public var endpoint: URL

    public init(apiKey: String, voice: String = "en-US-Chirp3-HD-Aoede", speakingRate: Double = 1.0,
                endpoint: URL = URL(string: "https://texttospeech.googleapis.com/v1")!) {
        self.apiKey = apiKey; self.voice = voice; self.speakingRate = speakingRate; self.endpoint = endpoint
    }

    /// "en-US-Chirp3-HD-Aoede" -> "en-US".
    public static func languageCode(of voice: String) -> String {
        let parts = voice.split(separator: "-")
        return parts.count >= 2 ? "\(parts[0])-\(parts[1])" : "en-US"
    }

    /// Request body for `text:synthesize` (public so hermes-checks can pin the wire format).
    public func requestBody(_ text: String) -> [String: Any] {
        var audio: [String: Any] = ["audioEncoding": "LINEAR16", "sampleRateHertz": 24_000]
        if abs(speakingRate - 1) > 0.01 { audio["speakingRate"] = speakingRate }
        return ["input": ["text": text],
                "voice": ["languageCode": Self.languageCode(of: voice), "name": voice],
                "audioConfig": audio]
    }

    public func render(_ sentence: String) async throws -> AVAudioPCMBuffer {
        var req = URLRequest(url: endpoint.appendingPathComponent("text:synthesize"), timeoutInterval: 30)
        req.httpMethod = "POST"
        // Key in a header, not the query string, so it never lands in URL logs.
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(sentence))
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = Self.errorMessage(data) ?? "HTTP \(code)"
            glog.error("google tts http \(code) \(msg, privacy: .public) [VOX-GTTS-HTTP]")
            throw STTError(message: "Google speech failed: \(msg)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = obj["audioContent"] as? String, let audio = Data(base64Encoded: b64), audio.count > 44 else {
            glog.error("google tts returned no audioContent [VOX-GTTS-EMPTY]")
            throw STTError(message: "Google speech returned no audio")
        }
        return try decodeAudio(audio, ext: "wav") // LINEAR16 responses carry a WAV header
    }

    /// Voices for a language, best (Chirp 3 HD) first. Used by Settings.
    public static func voices(apiKey: String, languageCode: String = "en-US",
                              endpoint: URL = URL(string: "https://texttospeech.googleapis.com/v1")!) async throws -> [String] {
        var comps = URLComponents(url: endpoint.appendingPathComponent("voices"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "languageCode", value: languageCode)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        req.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw STTError(message: "Google voices: \(errorMessage(data) ?? "request failed")")
        }
        let names = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["voices"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        func rank(_ n: String) -> Int { n.contains("Chirp3-HD") ? 0 : n.contains("Chirp") ? 1 : n.contains("Studio") ? 2 : n.contains("Neural2") ? 3 : 4 }
        return names.sorted { (rank($0), $0) < (rank($1), $1) }
    }

    static func errorMessage(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
    }
}
