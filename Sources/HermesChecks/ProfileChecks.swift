import Foundation
import HermesKit

/// Profile routing (URL building, @mention parsing) plus live checks against the dev server.
func runProfileChecks() {
    let base = HermesClient(api: Endpoint(baseURL: URL(string: "http://h:8642")!, token: "main-key", headerName: "Authorization"),
                            dashboard: Endpoint(baseURL: URL(string: "http://h:9119/")!, token: "t", headerName: "X-Hermes-Session-Token"))
    check("profile routing: unscoped client is unchanged") {
        expect(base.profile == nil)
        expect(base.api.url("/api/sessions", query: ["limit": "1"]).absoluteString == "http://h:8642/api/sessions?limit=1")
        expect(base.dash!.url("/api/skills").absoluteString == "http://h:9119/api/skills")
    }
    check("profile routing: scoped client prefixes /p/<name> and adds ?profile=") {
        let w = base.scoped(to: "Work", apiKey: "work-key")
        expect(w.profile == "work", "normalized lowercase")
        let u = w.api.url("/api/sessions/\(HermesClient.path("a/b"))/chat/stream").absoluteString
        expect(u == "http://h:8642/p/work/api/sessions/a%2Fb/chat/stream", u)
        expect(w.api.endpoint.token == "work-key", "profile key replaces the main key")
        let d = w.dash!.url("/api/skills/content", query: ["name": "x"]).absoluteString
        expect(d == "http://h:9119/api/skills/content?name=x&profile=work", d)
        // An explicit query value wins over the scope (never double-sent).
        expect(w.dash!.url("/api/x", query: ["profile": "other"]).absoluteString == "http://h:9119/api/x?profile=other")
    }
    check("profile routing: re-scoping starts from the root, nil goes back") {
        let w = base.scoped(to: "work", apiKey: "work-key")
        let o = w.scoped(to: "ops")
        expect(o.api.url("/health").absoluteString == "http://h:8642/p/ops/health", "no /p/work/p/ops")
        expect(o.api.endpoint.token == "main-key", "no key given = the main key, not work's")
        let back = o.scoped(to: nil)
        expect(back.profile == nil && back.api.url("/health").absoluteString == "http://h:8642/health")
        expect(back.dash!.url("/api/skills").absoluteString == "http://h:9119/api/skills")
        expect(base.scoped(to: "  ").profile == nil, "blank = unscoped")
    }
    check("profile names") {
        expect(HermesProfile.isValidNewName("work-2_x"))
        expect(!HermesProfile.isValidNewName("Work"), "uppercase")
        expect(!HermesProfile.isValidNewName("-x"))
        expect(!HermesProfile.isValidNewName("default") && !HermesProfile.isValidNewName("hermes"), "reserved")
        expect(!HermesProfile.isValidNewName(String(repeating: "a", count: 65)))
        expect(HermesProfile.routePrefix("A b") == "/p/a%20b")
    }
    check("mentions: find") {
        let names = ["default", "work", "work-2"]
        expect(ProfileMention.find(in: "@work summarize this", profiles: names)?.profile == "work")
        expect(ProfileMention.find(in: "ask @Work-2, then stop", profiles: names)?.profile == "work-2", "case + trailing comma")
        expect(ProfileMention.find(in: "mail me at jr@work today", profiles: names) == nil, "email is not a mention")
        expect(ProfileMention.find(in: "@nobody hi", profiles: names) == nil, "unknown names don't route")
        expect(ProfileMention.find(in: "@workshop hi", profiles: names) == nil, "no prefix match")
        expect(ProfileMention.find(in: "@nobody then @work", profiles: names)?.profile == "work", "first KNOWN mention")
        let t = "hi @work"
        if let m = ProfileMention.find(in: t, profiles: names) { expect(t[m.range] == "@work") } else { expect(false, "no match") }
    }
    check("mentions: completion") {
        expect(ProfileMention.completionQuery(in: "@") == "")
        expect(ProfileMention.completionQuery(in: "hello @wo") == "wo")
        expect(ProfileMention.completionQuery(in: "hello @work ") == nil, "finished token")
        expect(ProfileMention.completionQuery(in: "a@b") == nil, "email")
        expect(ProfileMention.completionQuery(in: "no mention") == nil)
        expect(ProfileMention.complete("hello @wo", with: "work") == "hello @work ")
        let ps = [HermesProfile(name: "default"), HermesProfile(name: "work"), HermesProfile(name: "homework")]
        expect(ProfileMention.suggestions("wo", in: ps).map(\.name) == ["work", "homework"], "prefix first")
        expect(ProfileMention.suggestions("", in: ps).count == 3)
    }
    check("profile labels capitalize for display only (talaria-ios-i0j)") {
        expect(HermesProfile(name: "default").label == "Default")
        expect(HermesProfile(name: "work").label == "Work")
        expect(HermesProfile(name: "my-team").label == "My-team")
        expect(HermesProfile(name: "work").name == "work", "routing name unchanged")
    }
    check("profile error codes") {
        let e = HermesError.from(status: 404, data: Data(#"{"error":"Unknown or unconfigured profile","code":"profile_unknown"}"#.utf8))
        expect(e.isProfileNotServed && e.code == "profile_unknown")
        expect(HermesError(status: 401, message: "x").isAuthFailure)
    }

    guard let client = devClient() else { return }
    var done = false
    Task { await liveProfileChecks(client); done = true }
    waitPumpingRunLoop { done }
}

func liveProfileChecks(_ c: HermesClient) async {
    await asyncCheck("live profiles list + active + served set") {
        let ps = try await c.profiles()
        expect(ps.contains { $0.name == "default" && $0.isDefault == true }, "\(ps.map(\.name))")
        let a = try await c.activeProfile()
        expect(a.current != nil)
        let served = try await c.servedProfiles()
        expect(served != nil, "gateway_shared_with missing")
    }
    await asyncCheck("live /p/<profile>/ routing") {
        // The launch profile answers under its own name too, with the main key.
        let d = c.scoped(to: "default")
        _ = try await d.sessions(limit: 1)
        _ = try await d.skills() // dashboard ?profile=default
        // An unknown prefix is a typed 404, never silently the default profile.
        do { _ = try await c.scoped(to: "zz-no-such-profile").sessions(limit: 1); expect(false, "no throw") }
        catch let e as HermesError { expect(e.isProfileNotServed, "\(e.status) \(e.code ?? "")") }
        // A served named profile refuses the main key unless it has its own (fail closed).
        if let other = try await c.servedProfiles()?.first(where: { $0 != "default" }) {
            do { _ = try await c.scoped(to: other).sessions(limit: 1) }
            catch let e as HermesError { expect(e.isAuthFailure, "\(other): \(e.status)") }
        }
    }
}
