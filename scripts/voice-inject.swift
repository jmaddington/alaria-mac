// Feeds an audio file into a running Hermes voice mode in place of the microphone (test harness).
// The app must be launched with HERMES_VOICE_TEST=1 and be in voice mode:
//   open --env HERMES_VOICE_TEST=1 build/Talaria.app
//   say -o /tmp/q.aiff "What is the capital of France?"
//   swift scripts/voice-inject.swift /tmp/q.aiff
import Foundation
guard CommandLine.arguments.count == 2 else { print("usage: voice-inject.swift <audio file>"); exit(2) }
let path = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
guard FileManager.default.fileExists(atPath: path) else { print("no such file: \(path)"); exit(1) }
DistributedNotificationCenter.default().postNotificationName(
    .init("net.jmaddington.hermes.test.injectVoice"), object: path, userInfo: nil, deliverImmediately: true)
print("injected \(path)")
