import Foundation
import HermesKit

/// "/" command parsing and per-chat model choice logic (bead hermes-mac-ptp), plus a live model-lock roundtrip.
func runSlashChecks() {
    check("slash input parsing") {
        expect(SlashInput.parse("/") == SlashInput(name: "", args: "", editingName: true))
        expect(SlashInput.parse("/Mo") == SlashInput(name: "mo", args: "", editingName: true), "lowercased")
        expect(SlashInput.parse("/model ") == SlashInput(name: "model", args: "", editingName: false), "space ends the name")
        expect(SlashInput.parse("/title  My Trip ") == SlashInput(name: "title", args: "My Trip", editingName: false))
        expect(SlashInput.parse("hi /model") == nil, "only at the start")
        expect(SlashInput.parse("/usr/bin/env") == nil, "a path is not a command")
        expect(SlashInput.parse("//x") == nil)
        expect(SlashInput.parse("/model\nmore") == nil, "multi-line drafts are messages")
    }
    check("slash Return: known commands run, unknown text is sent") {
        guard case .run(let c, let a) = SlashCatalog.action(for: "/model gemma") else { expect(false, "model"); return }
        expect(c.name == "model" && a == "gemma")
        guard case .run(let r, _) = SlashCatalog.action(for: "/rename Trip") else { expect(false, "alias"); return }
        expect(r.name == "title", "alias resolves to its command")
        guard case .needsArg(let t) = SlashCatalog.action(for: "/title") else { expect(false, "needsArg"); return }
        expect(t.name == "title")
        expect(SlashCatalog.action(for: "/frobnicate now") == .sendText, "unknown command is a message")
        expect(SlashCatalog.action(for: "/new york trip ideas") == .sendText, "args on a no-arg command = a message")
        expect(SlashCatalog.action(for: "hello") == .sendText)
        expect(SlashCatalog.action(for: "  /stop  ") == .run(SlashCatalog.command(named: "stop")!, args: ""), "trimmed")
    }
    check("slash suggestions") {
        expect(SlashCatalog.suggestions("").count == SlashCatalog.all.count)
        expect(SlashCatalog.suggestions("mo").first?.name == "model")
        expect(SlashCatalog.suggestions("re").map(\.name).prefix(3) == ["reasoning", "retry", "title"], "\(SlashCatalog.suggestions("re").map(\.name))") // title via /rename
        expect(SlashCatalog.suggestions("zzz").isEmpty)
        expect(SlashCatalog.filter(["low", "medium", "minimal"], by: "m") == ["medium", "minimal"])
        expect(SlashCatalog.filter(["xhigh", "high"], by: "hi") == ["high", "xhigh"], "prefix before substring")
        for u in SlashCatalog.unsupported { expect(SlashCatalog.command(named: u) == nil, "\(u) is listed both ways") }
    }
    check("model choice -> lock body") {
        let plain = ModelChoice(provider: "lmstudio", model: "google/gemma")
        expect(plain.modelOptions == nil, "defaults send no model_options")
        expect(plain.body["provider"] as? String == "lmstudio" && plain.body["model"] as? String == "google/gemma")
        let off = ModelChoice(provider: nil, model: "m", reasoningEffort: "none", fast: true)
        expect((off.modelOptions?["reasoning"] as? [String: Bool])?["enabled"] == false, "none = reasoning off")
        expect(off.modelOptions?["service_tier"] as? String == "priority")
        expect(off.body["provider"].flatMap { $0 } == nil, "no provider = omitted")
        let hi = ModelChoice(provider: "p", model: "m", reasoningEffort: "high")
        let r = hi.modelOptions?["reasoning"] as? [String: Any]
        expect(r?["enabled"] as? Bool == true && r?["effort"] as? String == "high")
        expect(hi.label == "m · high")
        expect(ModelChoice.shortName("google/gemma-4-12b-qat") == "gemma-4-12b-qat")
    }
    check("model catalog resolves typed names") {
        let json = #"{"model":"qwen3","provider":"lmstudio","providers":[{"slug":"lmstudio","is_current":true,"models":["google/gemma-4-12b-qat","qwen3",{"id":"meta/muse"}]},{"slug":"openrouter","models":["qwen3","openai/gpt-5"]},{"slug":"nous","models":[]}]}"#
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        guard let cat = try? d.decode(ModelCatalog.self, from: Data(json.utf8)) else { expect(false, "decode"); return }
        expect(cat.model == "qwen3" && cat.usable.map(\.slug) == ["lmstudio", "openrouter"], "empty providers hidden")
        expect(cat.provider(for: "qwen3") == "lmstudio", "current provider preferred")
        expect(cat.provider(for: "openai/gpt-5") == "openrouter")
        expect(cat.resolve("openrouter::qwen3")! == ("openrouter", "qwen3"), "explicit provider::model")
        expect(cat.resolve("gemma-4-12b-qat")! == ("lmstudio", "google/gemma-4-12b-qat"), "short name")
        expect(cat.resolve("MUSE")! == ("lmstudio", "meta/muse"), "unique substring, any case")
        expect(cat.resolve("e") == nil, "ambiguous")
        expect(cat.resolve("") == nil)
    }
    check("model choices persist") {
        let c = ModelChoice(provider: "p", model: "m", reasoningEffort: "low", fast: true)
        let back = try JSONDecoder().decode([String: ModelChoice].self, from: try JSONEncoder().encode(["s": c]))
        expect(back["s"] == c)
    }

    guard let c = devClient() else { return }
    var done = false
    Task { await liveModelLock(c); done = true }
    waitPumpingRunLoop { done }
}

private func liveModelLock(_ c: HermesClient) async {
    await asyncCheck("live session model lock") {
        let cat = try await c.modelCatalog()
        guard let p = cat.usable.first, let m = p.modelIDs.first else { print("(skipping model lock: no usable models)"); return }
        let s = try await c.createSession(title: "agent test: checks model lock")
        var created = [s.id]
        do {
            let rt = try await c.lockSessionModel(s.id, ModelChoice(provider: p.slug, model: m, reasoningEffort: "low"))
            expect(rt.model == m && rt.provider == p.slug && rt.modelLock == "accepted", "\(rt)")
            let back = try await c.session(s.id)
            expect(back.model == m, "session row carries the locked model: \(back.model ?? "nil")")
            let locked = try await c.createSession(title: "agent test: checks created locked", model: ModelChoice(provider: p.slug, model: m))
            created.append(locked.id)
            expect(locked.model == m, "created locked")
        } catch { failures.append("live session model lock: \(error)") }
        for id in created { try await c.deleteSession(id) }
    }
}
