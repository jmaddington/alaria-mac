import SwiftUI

/// Full-window voice mode. Same gesture vocabulary as drive mode, adapted to a desk:
///   click the orb      = mute / unmute (while HEARING: send now)
///   press and hold     = stop the reply that's playing
///   Space              = mute,  Esc = end voice mode
struct VoiceOverlay: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    private var voice: VoiceController { model.voice }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            // Deep night-indigo wash: the content behind should read as "far away", not as a grey film over it.
            LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.13).opacity(0.93),
                                    Color(red: 0.02, green: 0.02, blue: 0.05).opacity(0.97)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            if case .error(let msg) = voice.phase {
                VStack(spacing: 16) {
                    Image(systemName: "mic.slash").font(.system(size: 44, weight: .light)).foregroundStyle(.white.opacity(0.7))
                    Text("Voice mode couldn't start").font(.title2.weight(.semibold)).foregroundStyle(.white)
                    Text(msg).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("OK") { voice.dismissError() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(spacing: 0) {
                    Spacer()
                    Orb(phase: voice.phase, muted: voice.muted, level: voice.level, speaking: voice.outputLevel)
                        // Canvas is larger than the sphere so the blurred glow is never clipped to a square.
                        .frame(width: 460, height: 460)
                        .padding(.vertical, -90)
                        .contentShape(Circle().scale(0.55))
                        .onTapGesture { voice.toggleMute() }
                        .onLongPressGesture(minimumDuration: 0.6) { voice.stopSpeaking() }
                        .accessibilityLabel("Voice orb, \(label)")
                        .accessibilityAddTraits(.isButton)
                    Text(label)
                        .font(.system(size: 13, weight: .semibold)).tracking(2.5).textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.top, 34)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: label)
                    Caption(heard: voice.heard, saying: voice.saying)
                        .frame(maxWidth: 620, minHeight: 90, alignment: .top)
                        .padding(.top, 18)
                    Spacer()
                    controls.padding(.bottom, 40)
                }
                .padding(.horizontal, 40)
            }
        }
        .onKeyPress(.escape) { voice.stop(); return .handled }
        .onKeyPress(.space) { voice.toggleMute(); return .handled }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        // Take keyboard focus from the composer, or Esc/Space never reach the overlay (hermes-mac-6w3).
        .onAppear { focused = true }
        .background {
            // Esc ends voice mode even if focus is somewhere else.
            Button("End Voice Mode") { voice.stop() }.keyboardShortcut(.cancelAction).hidden()
        }
        .environment(\.colorScheme, .dark)
    }

    private var label: String {
        if voice.muted { return "Muted" }
        switch voice.phase {
        case .off, .starting: return "Starting"
        case .listening: return "Listening"
        case .hearing: return "Hearing"
        case .transcribing, .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .error: return ""
        }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            CircleButton(symbol: voice.muted ? "mic.slash.fill" : "mic.fill", tint: voice.muted ? .red : .white, help: "Mute (Space)") { voice.toggleMute() }
            CircleButton(symbol: "stop.fill", tint: .white, help: "Stop reply (hold the orb)") { voice.stopSpeaking() }
                .opacity(voice.phase == .speaking ? 1 : 0.35).disabled(voice.phase != .speaking)
            CircleButton(symbol: "xmark", tint: .white, help: "End voice mode (Esc)") { voice.stop() }
        }
    }
}

private struct CircleButton: View {
    var symbol: String
    var tint: Color
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

private struct Caption: View {
    var heard: String
    var saying: String
    var body: some View {
        VStack(spacing: 10) {
            if !saying.isEmpty {
                Text(saying).font(.system(size: 21, weight: .regular)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineSpacing(4).transition(.opacity)
            } else if !heard.isEmpty {
                Text("“\(heard)”").font(.system(size: 17)).foregroundStyle(.white.opacity(0.55)).italic()
                    .multilineTextAlignment(.center).lineLimit(3).transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: saying)
    }
}

/// The orb: three soft, slowly orbiting color fields inside a glass sphere.
/// Radius follows the mic while listening; a calm swirl while thinking; a pulse while speaking.
struct Orb: View {
    var phase: VoiceController.Phase
    var muted: Bool
    var level: Double
    var speaking: Double

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let base = min(size.width, size.height) / 2 * 0.47
                let energy: Double = {
                    if muted { return 0 }
                    switch phase {
                    case .hearing, .listening: return level
                    case .speaking: return 0.35 + 0.25 * (0.5 + 0.5 * sin(t * 7.5)) * speaking
                    case .thinking, .transcribing: return 0.18 + 0.08 * sin(t * 2.2)
                    default: return 0.05
                    }
                }()
                let r = base * (0.86 + 0.22 * energy)
                let speed = phase == .thinking || phase == .transcribing ? 1.6 : 0.5
                let colors = palette

                // Outer glow
                g.drawLayer { l in
                    l.addFilter(.blur(radius: 38))
                    l.fill(Circle().path(in: CGRect(x: c.x - r * 1.05, y: c.y - r * 1.05, width: r * 2.1, height: r * 2.1)),
                           with: .color(colors[0].opacity(muted ? 0.15 : 0.45 + 0.3 * energy)))
                }
                // Sphere body, clipped
                let sphere = Circle().path(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                g.drawLayer { l in
                    l.clip(to: sphere)
                    l.fill(sphere, with: .color(Color(red: 0.06, green: 0.06, blue: 0.14)))
                    l.addFilter(.blur(radius: r * 0.28))
                    for (i, col) in colors.enumerated() {
                        let a = t * speed * (0.6 + 0.25 * Double(i)) + Double(i) * 2.1
                        let d = r * (0.42 + 0.12 * sin(t * 0.7 + Double(i)))
                        let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a * 1.13) * d)
                        let br = r * (0.72 + 0.25 * energy)
                        l.fill(Circle().path(in: CGRect(x: p.x - br, y: p.y - br, width: br * 2, height: br * 2)),
                               with: .color(col.opacity(muted ? 0.25 : 0.95)))
                    }
                }
                // Glass highlight
                let hl = CGRect(x: c.x - r * 0.55, y: c.y - r * 0.82, width: r * 0.9, height: r * 0.5)
                g.fill(Ellipse().path(in: hl), with: .linearGradient(Gradient(colors: [.white.opacity(0.32), .white.opacity(0)]),
                                                                     startPoint: CGPoint(x: hl.midX, y: hl.minY), endPoint: CGPoint(x: hl.midX, y: hl.maxY)))
                g.stroke(sphere, with: .color(.white.opacity(0.14)), lineWidth: 1)
            }
        }
        .animation(.smooth(duration: 0.4), value: muted)
    }

    private var palette: [Color] {
        if muted { return [.gray, .gray.opacity(0.7), .gray.opacity(0.5)] }
        switch phase {
        case .speaking: return [Color(red: 0.45, green: 0.50, blue: 1.0), Color(red: 0.75, green: 0.45, blue: 1.0), Color(red: 0.30, green: 0.80, blue: 1.0)]
        case .thinking, .transcribing: return [Color(red: 0.55, green: 0.42, blue: 1.0), Color(red: 0.95, green: 0.50, blue: 0.80), Color(red: 0.40, green: 0.45, blue: 0.95)]
        default: return [Color(red: 0.30, green: 0.62, blue: 1.0), Color(red: 0.36, green: 0.39, blue: 0.96), Color(red: 0.30, green: 0.90, blue: 0.85)]
        }
    }
}
