import Foundation

private struct MediaEnvelope: Decodable { let dataUrl: String }

extension HermesClient {
    /// Bytes + mime of an image file on the Hermes host, via the dashboard's `GET /api/media?path=` (hermes_cli
    /// web_routers/files.py). The server only serves image extensions under `<HERMES_HOME>/{images,screenshots,cache}`
    /// (403 elsewhere, 415 non-image, 404 gone, 413 > 25 MB) and answers `{data_url}`.
    // AIDEV-NOTE: goes through `dash`, so the session token is only ever sent to the configured dashboard host and
    // carries ?profile= for a scoped client. No API-server route serves files (checked @52b5271).
    public func media(path: String) async throws -> (mime: String, data: Data) {
        let r: MediaEnvelope = try await requireDash().get("/api/media", query: ["path": path])
        guard let decoded = ChatContent.decodeDataURL(r.dataUrl) else {
            throw HermesError(status: 0, message: "The server sent an unreadable image.")
        }
        return decoded
    }
}
