import Foundation

public enum ConnectionSecurity {
    /// Plain http to a host that isn't this Mac, the LAN, or a tailnet sends the key readable on the wire.
    // AIDEV-NOTE: security (hermes-mac-fkh). ATS stays permissive so http to tailnet/LAN hosts works; this is the guard.
    public static func sendsKeyInClear(_ s: String) -> Bool {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespaces)), u.scheme?.lowercased() == "http",
              var host = u.host()?.lowercased() else { return false }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.contains(":") { // IPv6 literal: loopback, link-local fe80::/10, unique-local fc00::/7 are private
            let first = host.split(separator: ":").first.map(String.init) ?? ""
            if host == "::1" { return false }
            if let w = UInt16(first, radix: 16), (w & 0xffc0) == 0xfe80 || (w & 0xfe00) == 0xfc00 { return false }
            return true
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = labels.compactMap { UInt8($0) }
        if labels.count == 4 && octets.count == 4 { // a real IPv4 literal: every label numeric (hermes-mac-zli)
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return false
            case (172, 16...31): return false
            case (100, 64...127): return false // Tailscale CGNAT range
            default: return true
            }
        }
        // Names: only these suffixes are trusted as private; "10.0.0.1.evil.com" is a public name.
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".ts.net") || host.hasSuffix(".lan") || !host.contains(".") { return false }
        return true
    }
}
