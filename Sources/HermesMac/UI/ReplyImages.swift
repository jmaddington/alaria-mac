import AppKit
import HermesKit
import os
import SwiftUI
import UniformTypeIdentifiers

private let imgLog = Logger(subsystem: "net.jmaddington.hermes", category: "images")

/// A decoded picture plus its original bytes (kept for Save / Quick Look so nothing is re-encoded).
struct LoadedImage: @unchecked Sendable {
    let image: NSImage
    let data: Data
    let mime: String
    var pixelSize: CGSize {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
    var fileExtension: String {
        UTType(mimeType: mime)?.preferredFilenameExtension ?? "png"
    }
}

/// Loads reply images by source. Remote: plain ephemeral session, no cookies, no credentials. Server paths: the
/// dashboard's authenticated /api/media (HermesClient.media). Data URLs: decoded locally. Never file://.
// AIDEV-NOTE: security. The only request that carries a token is HermesClient.media (configured dashboard host).
// Remote fetches must never reuse HTTPCore's sessions or add auth headers: a reply can name any URL.
/// Refuses redirects that leave the consented URL's host (or downgrade from https).
final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let from = task.originalRequest?.url, to = request.url
        let sameHost = from?.host()?.lowercased() == to?.host()?.lowercased()
        let downgrade = from?.scheme?.lowercased() == "https" && to?.scheme?.lowercased() != "https"
        guard sameHost, !downgrade else {
            imgLog.error("remote image redirect to another host refused [ALR-IMG-REDIRECT]")
            return nil
        }
        return request
    }
}

enum ReplyImageLoader {
    static let maxBytes = 25_000_000
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.totalCostLimit = 200_000_000
        return c
    }()
    final class Box { let value: LoadedImage; init(_ v: LoadedImage) { value = v } }

    private static let remoteSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCredentialStorage = nil
        cfg.urlCache = URLCache(memoryCapacity: 20_000_000, diskCapacity: 0)
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 90
        return URLSession(configuration: cfg)
    }()

    static func cacheKey(_ ref: ImageRef, client: HermesClient?) -> String {
        switch ref {
        case .remote(let u): return "r:" + u.absoluteString
        case .data(let s): return "d:\(s.utf8.count):\(s.hashValue)"
        case .server(let p):
            // Same path on another server/profile is another file.
            return "s:" + (client?.dash?.url("/api/media").absoluteString ?? "-") + "|" + p
        case .blocked: return "b"
        }
    }

    static func cached(_ ref: ImageRef, client: HermesClient?) -> LoadedImage? {
        cache.object(forKey: cacheKey(ref, client: client) as NSString)?.value
    }

    static func load(_ ref: ImageRef, client: HermesClient?) async throws -> LoadedImage {
        let key = cacheKey(ref, client: client) as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let (mime, data): (String, Data)
        switch ref {
        case .blocked(let why): throw AttachmentError(message: why)
        case .data(let s):
            guard let d = await Task.detached(priority: .userInitiated, operation: { ChatContent.decodeDataURL(s) }).value else {
                throw AttachmentError(message: "The image data is damaged.")
            }
            (mime, data) = d
        case .server(let path):
            guard let client else { throw AttachmentError(message: "Not connected to Hermes.") }
            guard client.hasDashboard else {
                throw AttachmentError(message: "Connect the Hermes dashboard in Settings to see images saved on the Hermes host.")
            }
            (mime, data) = try await client.media(path: path)
        case .remote(let url):
            var req = URLRequest(url: url)
            req.setValue("image/*", forHTTPHeaderField: "Accept")
            // AIDEV-NOTE: security. Consent is per URL, so redirects to another host are refused (SameHostRedirects),
            // and the size cap is enforced while streaming, not after buffering (security review 2026-11-22).
            let (bytes, resp) = try await remoteSession.bytes(for: req, delegate: SameHostRedirects())
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                imgLog.error("remote image \(url.host() ?? "?", privacy: .public) -> HTTP \(code) [ALR-IMG-REMOTE-HTTP]")
                throw AttachmentError(message: "The image couldn't be downloaded (HTTP \(code)).")
            }
            guard (http.mimeType ?? "").lowercased().hasPrefix("image/") else {
                throw AttachmentError(message: "That link isn't an image.")
            }
            guard http.expectedContentLength <= Int64(maxBytes) else { throw AttachmentError(message: "The image is too large to show.") }
            var d = Data()
            if http.expectedContentLength > 0 { d.reserveCapacity(Int(http.expectedContentLength)) }
            for try await b in bytes {
                d.append(b)
                if d.count > maxBytes { throw AttachmentError(message: "The image is too large to show.") }
            }
            (mime, data) = (http.mimeType ?? "image/png", d)
        }
        let image = try await Task.detached(priority: .userInitiated) { () throws -> NSImage in
            guard let img = NSImage(data: data), img.isValid else { throw AttachmentError(message: "That isn't an image this Mac can show.") }
            return img
        }.value
        let loaded = LoadedImage(image: image, data: data, mime: mime.hasPrefix("image/") ? mime : "image/png")
        cache.setObject(Box(loaded), forKey: key, cost: data.count)
        imgLog.debug("loaded \(String(describing: ref).prefix(40), privacy: .public) \(data.count) bytes [ALR-IMG-LOAD]")
        return loaded
    }

    /// A temp file for Quick Look (it needs a file URL).
    static func previewFile(_ img: LoadedImage, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HermesImages/\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent(name + "." + img.fileExtension)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try img.data.write(to: url)
            return url
        } catch {
            imgLog.error("preview write failed: \(error.localizedDescription, privacy: .public) [ALR-IMG-PREVIEW-ERR]")
            return nil
        }
    }

    @MainActor static func copy(_ img: LoadedImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img.image])
    }

    @MainActor static func save(_ img: LoadedImage, name: String, app: AppModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + "." + img.fileExtension
        if let t = UTType(mimeType: img.mime) { panel.allowedContentTypes = [t] }
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try img.data.write(to: url, options: .atomic) } catch {
                imgLog.error("save failed: \(error.localizedDescription, privacy: .public) [ALR-IMG-SAVE-ERR]")
                app.flash("Couldn't save the image: \(error.localizedDescription)")
            }
        }
    }
}

/// An image inside an assistant reply: sized to fit the column, loads asynchronously with a placeholder and an
/// error state, click to Quick Look, context menu Copy / Save.
struct ReplyImageView: View {
    var alt: String
    var ref: ImageRef
    /// Remote images from model output can be tracking pixels or exfiltration links (`![](https://x/?q=secret)`),
    /// so they wait for a click unless the user opted in.
    // AIDEV-NOTE: security default; data: and server images load on their own, remote ones don't (bead hermes-mac-p81).
    @AppStorage("chat.loadRemoteImages") private var alwaysLoadRemote = false
    @Environment(AppModel.self) private var model
    @ViewState private var phase: Phase = .idle
    @ViewState private var allowOnce = false
    @ViewState private var preview: URL?

    enum Phase { case idle, loading, loaded(LoadedImage), failed(String) }
    static let maxSize = CGSize(width: 440, height: 380)

    private var needsConsent: Bool {
        if case .remote = ref { return !(alwaysLoadRemote || allowOnce) }
        return false
    }
    private var name: String {
        let a = alt.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty && a.lowercased() != "image" { return String(a.prefix(60)).replacingOccurrences(of: "/", with: "-") }
        if case .remote(let u) = ref, !u.deletingPathExtension().lastPathComponent.isEmpty {
            return u.deletingPathExtension().lastPathComponent
        }
        if case .server(let p) = ref { return ((p as NSString).lastPathComponent as NSString).deletingPathExtension }
        return "Image"
    }
    private var taskKey: String { ReplyImageLoader.cacheKey(ref, client: model.client) + (needsConsent ? "?" : "") }

    var body: some View {
        content
            .task(id: taskKey) { await load() }
            .accessibilityLabel(alt.isEmpty ? "Image" : alt)
    }

    @ViewBuilder private var content: some View {
        if case .blocked(let why) = ref {
            notice(icon: "photo.badge.exclamationmark", title: alt.isEmpty ? "Image not shown" : alt, detail: why)
        } else if needsConsent, case .remote(let u) = ref {
            consentCard(host: u.host() ?? "the web")
        } else {
            switch phase {
            case .idle, .loading:
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.4))
                    .frame(width: 240, height: 160)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel("Loading image")
            case .failed(let msg):
                notice(icon: "exclamationmark.triangle", title: "Couldn't load image", detail: msg, retry: true)
            case .loaded(let img):
                loadedView(img)
            }
        }
    }

    private func loadedView(_ img: LoadedImage) -> some View {
        let s = fitted(img.image.size)
        return Image(nsImage: img.image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .frame(width: s.width, height: s.height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { preview = ReplyImageLoader.previewFile(img, name: name) }
            .quickLookPreview($preview)
            .contextMenu {
                Button("Copy Image") { ReplyImageLoader.copy(img) }
                Button("Save Image…") { ReplyImageLoader.save(img, name: name, app: model) }
                if case .remote(let u) = ref {
                    Button("Copy Image Address") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string)
                    }
                }
            }
            .help(alt.isEmpty ? "Click to enlarge" : "\(alt) - click to enlarge")
            .accessibilityAddTraits(.isButton)
    }

    /// Fit inside maxSize without upscaling small images past 2x (a 64 px icon stays small).
    private func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 240, height: 160) }
        let scale = min(Self.maxSize.width / size.width, Self.maxSize.height / size.height, 2)
        return CGSize(width: max(24, size.width * scale), height: max(24, size.height * scale))
    }

    private func consentCard(host: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(alt.isEmpty || alt.lowercased() == "image" ? "Image from \(host)" : "\(alt) (\(host))")
                    .font(.callout.weight(.medium)).lineLimit(2)
                Text("Loading it tells \(host) you viewed this reply.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Load Image") { allowOnce = true }
                    Button("Always Load Remote Images") { alwaysLoadRemote = true }
                }
                .controlSize(.small).padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    private func notice(icon: String, title: String, detail: String, retry: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if retry { Button("Try Again") { Task { await load(force: true) } }.controlSize(.small).padding(.top, 2) }
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
    }

    private func load(force: Bool = false) async {
        if case .blocked = ref { return }
        if needsConsent { return }
        if let hit = ReplyImageLoader.cached(ref, client: model.client) { phase = .loaded(hit); return }
        // A streamed `MEDIA:` path turns into a data URL at completion: keep showing the old pixels meanwhile.
        if case .loaded = phase, !force {} else { phase = .loading }
        do {
            let img = try await ReplyImageLoader.load(ref, client: model.client)
            if !Task.isCancelled { phase = .loaded(img) }
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            imgLog.error("image load failed: \(error.localizedDescription, privacy: .public) [ALR-IMG-LOAD-ERR]")
            phase = .failed(error.localizedDescription)
        }
    }
}

/// A user-sent image reloaded from history: Hermes stores only its server path, so the pixels come from the
/// dashboard's /api/media. Falls back to the plain "Stored on Hermes" chip when that fails (no dashboard, file
/// swept from the cache, outside the media roots).
struct StoredImageThumb: View {
    @Environment(AppModel.self) private var model
    var attachment: Attachment
    var path: String
    @ViewState private var loaded: LoadedImage?
    @ViewState private var failed = false
    @ViewState private var preview: URL?

    var body: some View {
        Group {
            if let img = loaded {
                let aspect = max(0.4, min(2.5, img.image.size.width / max(img.image.size.height, 1)))
                Image(nsImage: img.image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 150 * aspect, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { preview = ReplyImageLoader.previewFile(img, name: attachment.name) }
                    .quickLookPreview($preview)
                    .contextMenu {
                        Button("Copy Image") { ReplyImageLoader.copy(img) }
                        Button("Save Image…") { ReplyImageLoader.save(img, name: attachment.name, app: model) }
                    }
                    .help("\(attachment.name) - click to preview")
                    .accessibilityLabel("Image \(attachment.name)")
                    .accessibilityAddTraits(.isButton)
            } else if failed {
                AttachmentChip(attachment: attachment)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.4))
                    .frame(width: 150, height: 150)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel("Loading \(attachment.name)")
            }
        }
        .task(id: path) {
            guard model.client?.hasDashboard == true else { failed = true; return }
            do { loaded = try await ReplyImageLoader.load(.server(path), client: model.client) } catch {
                if Task.isCancelled { return }
                // Expected once Hermes sweeps settled media; the chip explains the image stays on the server.
                imgLog.info("history image unavailable: \(error.localizedDescription, privacy: .public) [ALR-IMG-HIST]")
                failed = true
            }
        }
    }
}
