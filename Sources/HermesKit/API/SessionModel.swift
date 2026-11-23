import Foundation

// Per-chat model switching over the API server (bead hermes-mac-ptp).
//
// `POST /api/sessions/{id}/model {provider, model, model_options}` persists a confirmed "session model lock"
// (model_config.browser_model_lock) that every later turn in that session runs on, and sets the session row's
// `model`. `POST /api/sessions` takes the same fields (+ `require_model_lock`) so a new chat starts locked.
// AIDEV-NOTE: the lock REPLACES model_options wholesale and the server never returns them (model_config is hidden
// from the client API), so the client must resend reasoning/fast with every model change (see ModelChoice).
// There is no unlock endpoint: "back to default" = lock to the global default model.

/// What a chat runs on: provider + model + the per-session runtime options Hermes accepts in `model_options`.
public struct ModelChoice: Codable, Hashable, Sendable {
    public var provider: String?
    public var model: String
    /// nil = provider default; "none" turns reasoning off; otherwise minimal/low/medium/high/xhigh.
    public var reasoningEffort: String?
    /// OpenAI Priority Processing / Anthropic fast mode (`service_tier: priority`).
    public var fast: Bool

    public init(provider: String?, model: String, reasoningEffort: String? = nil, fast: Bool = false) {
        self.provider = provider; self.model = model; self.reasoningEffort = reasoningEffort; self.fast = fast
    }

    public static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh"]

    /// `model_options` as `_runtime_options_from_model_options` (api_server.py) reads it; nil when all default.
    public var modelOptions: [String: Any]? {
        var o: [String: Any] = [:]
        if let e = reasoningEffort {
            o["reasoning"] = e == "none" ? ["enabled": false] : ["enabled": true, "effort": e]
        }
        if fast { o["service_tier"] = "priority" }
        return o.isEmpty ? nil : o
    }

    /// Request body for the lock endpoint (and the model fields of a session create).
    public var body: [String: Any?] {
        ["provider": provider?.isEmpty == false ? provider : nil, "model": model, "model_options": modelOptions]
    }

    /// Short label for menus: "gemma-4-12b · high · fast".
    public var label: String {
        var parts = [ModelChoice.shortName(model)]
        if let e = reasoningEffort { parts.append(e == "none" ? "no reasoning" : e) }
        if fast { parts.append("fast") }
        return parts.joined(separator: " · ")
    }

    /// "google/gemma-4-12b-qat" -> "gemma-4-12b-qat" (vendor prefixes only crowd the toolbar).
    public static func shortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }
}

/// The `runtime` block of run.started / assistant.completed / run.completed and the lock response.
public struct SessionRuntime: Codable, Hashable, Sendable {
    public var provider: String?
    public var model: String?
    public var routeSource: String?
    public var modelLock: String?
    public init(provider: String?, model: String?, routeSource: String? = nil, modelLock: String? = nil) {
        self.provider = provider; self.model = model; self.routeSource = routeSource; self.modelLock = modelLock
    }
    init?(_ o: Any?) {
        guard let o = o as? [String: Any] else { return nil }
        let model = (o["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let model else { return nil }
        self.init(provider: (o["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 }, model: model,
                  routeSource: o["route_source"] as? String, modelLock: o["model_lock"] as? String)
    }
}
struct ModelLockEnvelope: Decodable { let runtime: SessionRuntime }

/// `GET /api/model/options`: the picker inventory plus the gateway's global default model.
public struct ModelCatalog: Decodable, Hashable, Sendable {
    public var providers: [ProviderOption]
    /// The global default (`model.default` in config.yaml) a chat without a lock runs on.
    public var model: String?
    public var provider: String?

    public init(providers: [ProviderOption], model: String?, provider: String?) {
        self.providers = providers; self.model = model; self.provider = provider
    }

    /// Providers worth offering: ones with models listed (unauthenticated ones come back empty).
    public var usable: [ProviderOption] { providers.filter { !$0.modelIDs.isEmpty } }

    /// The provider listing `model`, preferring the current/default provider when several do.
    public func provider(for model: String) -> String? {
        let owners = usable.filter { $0.modelIDs.contains(model) }
        return (owners.first { $0.slug == provider } ?? owners.first)?.slug
    }

    /// Resolves what a user typed after `/model`: "provider::model" (Hermes' own prefix form), an exact model id,
    /// a unique short name ("gemma-4-12b-qat"), or else a unique case-insensitive substring. nil = no match.
    public func resolve(_ typed: String) -> (provider: String?, model: String)? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if let r = t.range(of: "::") {
            let p = String(t[..<r.lowerBound]), m = String(t[r.upperBound...])
            return m.isEmpty ? nil : (p.isEmpty ? nil : p, m)
        }
        let all = usable.flatMap { p in p.modelIDs.map { (p.slug, $0) } }
        if let hit = all.first(where: { $0.1 == t }) { return (provider(for: hit.1) ?? hit.0, hit.1) }
        let lower = t.lowercased()
        let short = all.filter { ModelChoice.shortName($0.1).lowercased() == lower }
        if short.count == 1 { return (short[0].0, short[0].1) }
        let sub = all.filter { $0.1.lowercased().contains(lower) }
        if Set(sub.map(\.1)).count == 1 { return (sub[0].0, sub[0].1) }
        return nil
    }
}
