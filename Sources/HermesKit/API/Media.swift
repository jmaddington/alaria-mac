import Foundation

private struct MediaEnvelope: Decodable { let dataUrl: String }
private struct FSDataURLEnvelope: Decodable { let dataUrl: String }

extension HermesClient {
    /// Bytes + mime of an image file on the Hermes host, via the dashboard's `GET /api/media?path=` (hermes_cli
    /// web_routers/files.py). The server only serves image extensions under `<HERMES_HOME>/{images,screenshots,cache}`
    /// (403 elsewhere, 415 non-image, 404 gone, 413 > 25 MB) and answers `{data_url}`.
    // AIDEV-NOTE: goes through `dash`, so the session token is only ever sent to the configured dashboard host and
    // carries ?profile= for a scoped client. No API-server route serves files (checked @52b5271).
    public func media(path: String) async throws -> (mime: String, data: Data) {
        let r: MediaEnvelope
        do {
            r = try await requireDash().get("/api/media", query: ["path": path])
        } catch let e as HermesError where e.status == 403 && profile != nil && ImageRef.hasImageExtension(path) {
            // AIDEV-NOTE: /api/media ignores ?profile= (roots are the dashboard's own HERMES_HOME), so a named
            // profile's images 403. /api/fs/read-data-url is profile-aware; used only as that fallback, images only.
            let f: FSDataURLEnvelope = try await requireDash().get("/api/fs/read-data-url", query: ["path": path])
            r = MediaEnvelope(dataUrl: f.dataUrl)
        }
        guard let decoded = ChatContent.decodeDataURL(r.dataUrl) else {
            throw HermesError(status: 0, message: "The server sent an unreadable image.")
        }
        return decoded
    }
}
