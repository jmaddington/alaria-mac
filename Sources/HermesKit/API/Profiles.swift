import Foundation

// Hermes profiles: each is a separate HERMES_HOME (config.yaml + model, .env keys, skills, memory, SOUL.md, cron,
// and its own state.db, so sessions are per profile). See docs/agents/api-notes.md "Profiles".
//  - list / create / delete / describe: dashboard /api/profiles*  (unscoped)
//  - any dashboard call for a profile:  ?profile=<name>
//  - API server (chat, sessions, jobs):  /p/<name>/... on the same listener, ONLY when the gateway runs with
//    gateway.multiplex_profiles (dashboard /api/status gateway_shared_with lists the served set), and it
//    authenticates with THAT profile's API_SERVER_KEY (fail closed: no key in its .env = 401).
// AIDEV-NOTE: a session lives in one profile's state.db; there is no per-turn routing into another profile's session.

/// One installed profile (`GET /api/profiles`).
public struct HermesProfile: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var path: String?
    public var isDefault: Bool?
    public var model: String?
    public var provider: String?
    public var skillCount: Int?
    public var gatewayRunning: Bool?
    public var description: String?
    public var displayName: String?
    public var hasEnv: Bool?

    public var id: String { name }
    public init(name: String, model: String? = nil, description: String? = nil) { self.name = name; self.model = model; self.description = description }

    /// Display only: first letter capitalized ("work" -> "Work", talaria-ios-i0j); a user-set display name wins.
    public var label: String {
        if let d = displayName, !d.isEmpty { return d }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Profile ids are lowercase on disk; the server normalizes case the same way.
    public static func normalize(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// `/p/<name>`: the API-server mirror prefix for a multiplexed profile.
    public static func routePrefix(_ name: String) -> String { "/p/" + HermesClient.path(normalize(name)) }

    /// Server rule (hermes_constants.PROFILE_ID_RE + _RESERVED_NAMES): lowercase letters, digits, - and _,
    /// starting with a letter or digit, at most 64 chars.
    public static func isValidNewName(_ name: String) -> Bool {
        let reserved: Set = ["hermes", "default", "test", "tmp", "root", "sudo"]
        return name.range(of: #"^[a-z0-9][a-z0-9_-]{0,63}$"#, options: .regularExpression) != nil && !reserved.contains(name)
    }
}

/// `GET /api/profiles/active`: `active` = sticky default for new CLI runs; `current` = the dashboard's own profile.
public struct ActiveProfile: Codable, Hashable, Sendable {
    public var active: String?
    public var current: String?
}

struct ProfilesEnvelope: Decodable { let profiles: [HermesProfile] }

extension HermesError {
    /// 404 from a `/p/<name>/` prefix this gateway doesn't serve (unknown, parked, or multiplexing off).
    public var isProfileNotServed: Bool { status == 404 && (code == "profile_unknown" || code == "profile_not_served") }
    public var isAuthFailure: Bool { status == 401 || status == 403 }
}

// MARK: - API

extension HermesClient {
    func requireRootDash() throws -> HTTPCore {
        guard let rootDash else { throw HermesError(status: 0, message: "Connect the Hermes dashboard in Settings to manage profiles.") }
        return rootDash
    }

    public func profiles() async throws -> [HermesProfile] {
        let r: ProfilesEnvelope = try await requireRootDash().get("/api/profiles")
        return r.profiles
    }

    public func activeProfile() async throws -> ActiveProfile { try await requireRootDash().get("/api/profiles/active") }

    /// Profiles the API server answers for: its own plus `gateway_shared_with`. nil = server doesn't say.
    public func servedProfiles() async throws -> [String]? {
        let s: DashboardStatus = try await requireRootDash().get("/api/status")
        return s.gatewaySharedWith
    }

    /// Creates a profile. `cloneFrom` copies that profile's config, skills and SOUL.md; nil starts fresh.
    /// Hermes mirrors the launch profile's provider keys either way, but never API_SERVER_KEY (see setEnv).
    public func createProfile(_ name: String, description: String?, cloneFrom: String?) async throws {
        let _: JSONValue = try await requireRootDash().json("POST", "/api/profiles",
            ["name": name, "description": description, "clone_from": cloneFrom])
    }

    public func deleteProfile(_ name: String) async throws {
        try await requireRootDash().send(requireRootDash().request("DELETE", "/api/profiles/\(Self.path(name))"))
    }

    public func setProfileDescription(_ name: String, _ text: String) async throws {
        let _: JSONValue = try await requireRootDash().json("PUT", "/api/profiles/\(Self.path(name))/description", ["description": text])
    }

    /// Writes one .env variable in a profile's home (dashboard `PUT /api/env?profile=`). Used to give a profile an
    /// API_SERVER_KEY so `/p/<name>/` accepts this app; the gateway reads it per request, no restart.
    // AIDEV-NOTE: security; privileged write into another profile's secrets. Only on an explicit user action.
    public func setEnv(_ key: String, value: String, profile: String) async throws {
        let _: JSONValue = try await requireRootDash().json("PUT", "/api/env", ["key": key, "value": value],
                                                            query: ["profile": HermesProfile.normalize(profile)])
    }
}

// MARK: - @mentions

/// `@name` profile mentions in a chat message. Pure text logic so the app and checks share it.
public enum ProfileMention {
    static let namePattern = #"[A-Za-z0-9][A-Za-z0-9_-]{0,63}"#

    /// The first `@name` that names a known profile: at the start or after whitespace, ending at whitespace,
    /// punctuation or the end. Returns the canonical profile name and the token's range (including the `@`).
    public static func find(in text: String, profiles: [String]) -> (profile: String, range: Range<String.Index>)? {
        let known = Set(profiles.map(HermesProfile.normalize))
        guard let re = try? NSRegularExpression(pattern: #"(?:^|(?<=\s))@("# + namePattern + #")(?![A-Za-z0-9_-])"#) else { return nil }
        let ns = text as NSString
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = HermesProfile.normalize(ns.substring(with: m.range(at: 1)))
            if known.contains(name), let r = Range(m.range, in: text) { return (name, r) }
        }
        return nil
    }

    /// The partial name being typed when the draft ends in an `@token` (the composer only completes at the end,
    /// since a SwiftUI TextField doesn't expose its caret). "" right after a bare "@"; nil when not completing.
    public static func completionQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil } // an email, not a mention
        let tail = draft[draft.index(after: at)...]
        guard tail.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return String(tail)
    }

    /// Replaces the trailing `@partial` with `@name ` (completionQuery must be non-nil for `draft`).
    public static func complete(_ draft: String, with name: String) -> String {
        guard let at = draft.lastIndex(of: "@") else { return draft + "@\(name) " }
        return String(draft[..<at]) + "@\(name) "
    }

    /// Profiles matching a partial name: prefix matches first, then substring matches, each alphabetical.
    public static func suggestions(_ query: String, in profiles: [HermesProfile]) -> [HermesProfile] {
        let q = HermesProfile.normalize(query)
        guard !q.isEmpty else { return profiles.sorted { $0.name < $1.name } }
        let prefix = profiles.filter { $0.name.hasPrefix(q) || $0.label.lowercased().hasPrefix(q) }.sorted { $0.name < $1.name }
        let inner = profiles.filter { p in !prefix.contains(p) && p.name.contains(q) }.sorted { $0.name < $1.name }
        return prefix + inner
    }
}
