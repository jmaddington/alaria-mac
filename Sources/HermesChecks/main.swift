import Foundation
@testable import HermesKit

// Minimal check runner (see Package.swift note). Each check is a named closure; failures are collected.
nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var current = ""
func expect(_ ok: @autoclosure () -> Bool, _ msg: String = "", line: Int = #line) {
    if !ok() { failures.append("\(current) line \(line) \(msg)") }
}
func check(_ name: String, _ body: () throws -> Void) {
    current = name
    do { try body() } catch { failures.append("\(name): threw \(error)") }
}

private func rms(db: Double) -> Double { pow(10, db / 20) }
private func run(_ v: inout VAD, _ segments: [(db: Double, frames: Int)]) -> [VAD.Event] {
    var out: [VAD.Event] = []
    for s in segments { for _ in 0..<s.frames { if let e = v.frame(rms: rms(db: s.db)) { out.append(e) } } }
    return out
}

check("vad speech over road noise") { var v = VAD(); expect(run(&v, [(-55, 100), (-25, 75), (-55, 100)]) == [.start, .end]) }
check("vad short blip discarded") { var v = VAD(); expect(run(&v, [(-55, 100), (-25, 10), (-55, 100)]) == [.start, .discard]) }
check("vad steady noise never opens") { var v = VAD(); for i in 0..<500 { expect(v.frame(rms: rms(db: -40 + Double(i % 3))) == nil) } }
check("noise filter") {
    let prompt = "A user talking to their assistant Hermes about skills and cron jobs"
    expect(isNoiseTranscript("", prompt: prompt))
    expect(isNoiseTranscript("talking to their assistant Hermes about skills", prompt: prompt))
    expect(!isNoiseTranscript("what's on my calendar today", prompt: prompt))
}
check("sentence splitter") {
    var s = SentenceSplitter()
    expect(s.feed("Hello **there**. It is 3") == ["Hello there."])
    expect(s.feed(".5 degrees! Next") == ["It is 3.5 degrees!"])
    expect(s.feed(" line\n- see [docs](http://x)") == ["Next line"])
    expect(s.flush() == ["see docs"])
}

runAPIChecks()

if failures.isEmpty { print("All checks passed") } else { failures.forEach { print("FAIL", $0) }; exit(1) }
