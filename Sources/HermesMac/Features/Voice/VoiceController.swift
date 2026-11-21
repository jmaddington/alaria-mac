@preconcurrency import AVFAudio
import AVFoundation
import Foundation
import HermesKit
import Observation
import os

private let vlog = Logger(subsystem: "net.jmaddington.hermes", category: "voice")

enum VoiceSTT: String, CaseIterable, Identifiable { case apple, openai; var id: String { rawValue }
    var label: String { self == .apple ? "On-device (Apple)" : "OpenAI" } }
enum VoiceTTS: String, CaseIterable, Identifiable { case system, openai; var id: String { rawValue }
    var label: String { self == .system ? "System voice" : "OpenAI" } }

/// Voice preferences; secrets in the Keychain.
struct VoicePrefs {
    @MainActor static var stt: VoiceSTT { VoiceSTT(rawValue: UserDefaults.standard.string(forKey: "voice.stt") ?? "") ?? .apple }
    @MainActor static var tts: VoiceTTS { VoiceTTS(rawValue: UserDefaults.standard.string(forKey: "voice.tts") ?? "") ?? .system }
    @MainActor static var bargeIn: Bool { UserDefaults.standard.object(forKey: "voice.bargeIn") as? Bool ?? true }
    @MainActor static var systemVoice: String? { UserDefaults.standard.string(forKey: "voice.systemVoice") }
    @MainActor static var openAIVoice: String { UserDefaults.standard.string(forKey: "voice.openaiVoice") ?? "onyx" }
    @MainActor static var sttModel: String { UserDefaults.standard.string(forKey: "voice.sttModel") ?? "gpt-transcribe" }
    @MainActor static var sttPrompt: String { UserDefaults.standard.string(forKey: "voice.sttPrompt") ?? "" }
    @MainActor static var rate: Float { UserDefaults.standard.object(forKey: "voice.rate") as? Float ?? 0.52 }
    static var openAIKey: String? { Keychain.get("openaiKey") }
}

/// Audio-thread side: VAD + utterance capture with 1 s pre-roll (drive mode keeps 1 s before detection).
// AIDEV-NOTE: runs on the AVAudioEngine tap thread; everything here is lock-protected and hops to main via `emit`.
final class FrameProcessor: @unchecked Sendable {
    enum Out { case level(Double), start, end([Float]), discard }
    var emit: ((Out) -> Void)?
    private let lock = NSLock()
    private var vad = VAD()
    private var preroll: [[Float]] = []
    private var utterance: [Float] = []
    private var listening = true
    private var levelTick = 0

    func setListening(_ on: Bool) {
        lock.withLock { listening = on; if !on { vad.reset(); utterance.removeAll() } }
    }

    /// "Send now": ends the current utterance immediately instead of waiting for 1.1 s of silence.
    func forceEnd() {
        let out: [Float]? = lock.withLock {
            guard vad.active, !utterance.isEmpty else { return nil }
            defer { vad.reset(); utterance.removeAll() }
            return utterance
        }
        if let out { emit?(.end(out)) }
    }

    func process(rms: Double, frame: [Float]) {
        var outs: [Out] = []
        lock.withLock {
            levelTick += 1
            if levelTick % 2 == 0 { outs.append(.level(rms)) } // 25 Hz is plenty for the orb
            guard listening else { return }
            preroll.append(frame); if preroll.count > 50 { preroll.removeFirst() }
            let wasActive = vad.active
            let ev = vad.frame(rms: rms)
            if wasActive || ev == .start { utterance.append(contentsOf: frame) }
            switch ev {
            case .start:
                utterance = preroll.flatMap { $0 } // includes this frame
                outs.append(.start)
            case .end: outs.append(.end(utterance)); utterance.removeAll()
            case .discard: outs.append(.discard); utterance.removeAll()
            case nil: break
            }
        }
        for o in outs { emit?(o) }
    }
}

@MainActor @Observable
final class VoiceController {
    enum Phase: Equatable { case off, starting, listening, hearing, transcribing, thinking, speaking, error(String) }

    weak var app: AppModel?
    var phase: Phase = .off
    var muted = false
    var level: Double = 0          // 0...1 smoothed mic level for the orb
    var outputLevel: Double = 0    // pulses while speaking
    var heard = ""                 // last thing the user said
    var saying = ""                // sentence being spoken
    var isActive: Bool { phase != .off }

    private var audio: VoiceAudio?
    private let frames = FrameProcessor()
    private var splitter = SentenceSplitter()
    private var queue: [String] = []
    private var pumping = false
    private var generation = 0
    private var tickTask: Task<Void, Never>?
    private var stt: SpeechToText?
    private var tts: TextToSpeech?

    // MARK: lifecycle

    func start() {
        guard phase == .off else { return }
        phase = .starting
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                phase = .error("Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone.")
                return
            }
            do {
                try configureEngines()
                let a = VoiceAudio()
                a.onFrame = { [frames] rms, f in frames.process(rms: rms, frame: f) }
                a.onFailure = { [weak self] msg in Task { @MainActor in self?.fail(msg) } }
                frames.emit = { [weak self] o in Task { @MainActor in self?.handle(o) } }
                try a.start(voiceProcessing: VoicePrefs.bargeIn)
                audio = a
                muted = false
                frames.setListening(true)
                phase = .listening
                Earcon.ready.play(on: a)
                vlog.info("voice started aec=\(a.echoCancelling) [VOX-START]")
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        generation += 1
        tickTask?.cancel(); tickTask = nil
        audio?.stopPlayback()
        audio?.stop()
        audio = nil
        queue.removeAll(); pumping = false
        splitter = SentenceSplitter()
        phase = .off
        level = 0; outputLevel = 0; saying = ""
        vlog.info("voice stopped [VOX-STOP]")
    }

    private func fail(_ msg: String) {
        vlog.error("voice failed: \(msg, privacy: .public) [VOX-FAIL]")
        stop()
        phase = .error(msg)
    }

    func dismissError() { if case .error = phase { phase = .off } }

    private func configureEngines() throws {
        switch VoicePrefs.stt {
        case .apple: stt = AppleTranscriber()
        case .openai:
            guard let k = VoicePrefs.openAIKey, !k.isEmpty else { throw STTError(message: "Add an OpenAI key in Settings › Voice, or switch to on-device transcription.") }
            stt = OpenAITranscriber(apiKey: k, model: VoicePrefs.sttModel, prompt: VoicePrefs.sttPrompt)
        }
        switch VoicePrefs.tts {
        case .system: tts = SystemVoice(voiceIdentifier: VoicePrefs.systemVoice, rate: VoicePrefs.rate)
        case .openai:
            guard let k = VoicePrefs.openAIKey, !k.isEmpty else { throw STTError(message: "Add an OpenAI key in Settings › Voice, or use a system voice.") }
            tts = OpenAIVoice(apiKey: k, voice: VoicePrefs.openAIVoice)
        }
    }

    // MARK: controls (drive-mode vocabulary)

    /// Tap: mute/unmute. While hearing: send now.
    func toggleMute() {
        guard let audio else { return }
        if phase == .hearing { frames.forceEnd(); return }
        muted.toggle()
        frames.setListening(!muted && canListen)
        (muted ? Earcon.muted : Earcon.unmuted).play(on: audio)
    }

    /// Hold / Esc: stop the reply that's playing.
    func stopSpeaking() {
        guard let audio, phase == .speaking || !queue.isEmpty else { return }
        generation += 1
        queue.removeAll()
        audio.stopPlayback()
        pumping = false
        saying = ""
        Earcon.stopped.play(on: audio)
        settle()
    }

    /// Without echo cancellation the mic must stay closed while speaking, or it hears itself.
    private var canListen: Bool { !(phase == .speaking && !(audio?.echoCancelling ?? false)) }

    // MARK: pipeline

    private func handle(_ o: FrameProcessor.Out) {
        switch o {
        case .level(let rms):
            let db = 20 * log10(max(rms, 1e-7))
            let target = min(max((db + 60) / 45, 0), 1)
            level += (target - level) * 0.35
        case .start:
            guard !muted else { return }
            if phase == .speaking { stopSpeaking() } // barge-in (only reachable with AEC on)
            phase = .hearing
        case .discard:
            if phase == .hearing { settle() }
        case .end(let samples):
            guard !muted, let audio else { return }
            Earcon.heard.play(on: audio)
            phase = .transcribing
            Task { await transcribeAndSend(samples) }
        }
    }

    private func transcribeAndSend(_ samples: [Float]) async {
        guard let stt, let audio else { return }
        let gen = generation
        do {
            let text = try await stt.transcribe(samples)
            guard gen == generation else { return }
            if isNoiseTranscript(text, prompt: VoicePrefs.sttPrompt) {
                Earcon.nothingUsable.play(on: audio)
                settle(); return
            }
            heard = text
            vlog.info("heard words=\(text.split(separator: " ").count) [VOX-HEARD]")
            guard let chats = app?.chats else { return }
            if chats.isStreaming, let run = chats.runId, let client = app?.client {
                // Hermes is still working: fold the words into the running turn instead of dropping them.
                try await client.steer(run, text: text)
                phase = .thinking
                return
            }
            phase = .thinking
            startTicking()
            splitter = SentenceSplitter()
            let myGen = generation
            chats.send(text, onEvent: { [weak self] e in
                guard let self, self.generation == myGen else { return }
                if case .delta(let d) = e { self.enqueue(self.splitter.feed(d)) }
            }, onFinish: { [weak self] err in
                guard let self else { return }
                // A reply stopped or barged into mid-stream bumps `generation`; still leave THINKING when the turn ends.
                guard self.generation == myGen else { if !self.pumping { self.settle() }; return }
                self.enqueue(self.splitter.flush())
                if let err { self.enqueue(["Sorry, that failed. \(err.localizedDescription)"]) }
                if self.queue.isEmpty && !self.pumping { self.settle() }
            })
        } catch {
            vlog.error("stt failed: \(error.localizedDescription, privacy: .public) [VOX-STT-ERR]")
            Earcon.nothingUsable.play(on: audio)
            settle()
        }
    }

    private func enqueue(_ sentences: [String]) {
        guard !sentences.isEmpty else { return }
        queue.append(contentsOf: sentences)
        if !pumping { Task { await pump() } }
    }

    /// Plays sentences strictly one at a time, rendering the next while the current one plays.
    private func pump() async {
        guard let tts, let audio else { return }
        pumping = true
        let gen = generation
        typealias Clip = (text: String, buffer: Task<AVAudioPCMBuffer?, Never>)
        func render(_ s: String) -> Clip { (s, Task.detached { try? await tts.render(s) }) }
        var prefetched: Clip?
        while gen == generation {
            let clip: Clip
            if let p = prefetched { clip = p; prefetched = nil }
            else if !queue.isEmpty { clip = render(queue.removeFirst()) }
            else { break }
            if !queue.isEmpty { prefetched = render(queue.removeFirst()) } // one ahead, like drive mode
            let buf = await clip.buffer.value
            guard gen == generation else { break }
            guard let buf else {
                vlog.error("tts render failed for one sentence [VOX-TTS-LOST]")
                Earcon.sentenceLost.play(on: audio) // two low blips: a piece was skipped, ask it to repeat
                continue
            }
            tickTask?.cancel()
            saying = clip.text
            phase = .speaking
            frames.setListening(!muted && canListen)
            outputLevel = 1
            await audio.play(buf)
            outputLevel = 0
        }
        if gen == generation { pumping = false; saying = ""; settle() }
    }

    /// Returns to listening (or thinking, if the turn is still streaming).
    private func settle() {
        guard audio != nil else { return }
        if app?.chats.isStreaming == true { phase = .thinking; startTicking() } else { phase = .listening; tickTask?.cancel() }
        frames.setListening(!muted)
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self, !Task.isCancelled, self.phase == .thinking, let a = self.audio else { continue }
                Earcon.thinkingTick.play(on: a)
            }
        }
    }
}
