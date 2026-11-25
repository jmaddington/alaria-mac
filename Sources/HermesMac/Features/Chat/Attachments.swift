import AppKit
import HermesKit
import ImageIO
import Observation
import OSLog
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// AIDEV-NOTE: chat attachments (beads hermes-mac-ard / -6uj). Wire format + server limits live in HermesKit
// ContentParts.swift; this file is the Mac side: loading/downscaling, the composer tray, paste/drop, transcript chips.
// Hermes accepts images only; text-like files are inlined as fenced blocks. Everything else is refused with a toast.

private let attachLog = Logger(subsystem: "net.jmaddington.hermes", category: "attachments")

/// One attachment, in the composer tray or on a sent / reloaded user message.
struct Attachment: Identifiable, Equatable {
    enum Kind: Equatable { case image(mime: String), text }
    let id = UUID()
    var name: String
    var kind: Kind
    /// Encoded image bytes or UTF-8 text. nil for an image reloaded from history: Hermes keeps only a server path.
    var data: Data?
    var thumbnail: NSImage?
    /// For a history image: where Hermes stored it, fetched lazily through the dashboard (ReplyImages.swift).
    var serverPath: String? = nil

    var isImage: Bool { if case .image = kind { return true }; return false }
    var text: String? { kind == .text ? data.flatMap { String(data: $0, encoding: .utf8) } : nil }
    var sizeLabel: String? { data.map { ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) } }
    var dataURL: String? {
        guard case .image(let mime) = kind, let data else { return nil }
        return ChatContent.dataURL(mime: mime, data: data)
    }

    /// The content parts for a turn: typed text + inlined text files in one text part, then the images.
    static func parts(text: String, _ items: [Attachment]) -> [ContentPart] {
        ChatContent.parts(text: text,
                          files: items.compactMap { a in a.text.map { InlineFile(name: a.name, text: $0) } },
                          imageURLs: items.compactMap(\.dataURL))
    }

    /// A stored user row back into display text + attachments (inlined files, and image placeholders or, if the
    /// server ever returns part lists, the real images).
    static func fromStored(_ m: HermesMessage) -> (text: String, attachments: [Attachment]) {
        if let parts = m.contentParts {
            let split = ChatContent.split(parts)
            let stored = ChatContent.parseStored(split.text)
            let images = split.imageURLs.enumerated().map { i, url in
                let decoded = ChatContent.decodeDataURL(url)
                return Attachment(name: "Image \(i + 1)", kind: .image(mime: decoded?.mime ?? "image/png"), data: decoded?.data,
                                  thumbnail: decoded.flatMap { AttachmentLoader.thumbnail(of: $0.data) })
            }
            return (stored.text, images + stored.files.map(file))
        }
        let stored = ChatContent.parseStored(m.content ?? "")
        let images = (0..<stored.imageCount).map { i in
            Attachment(name: stored.imageCount == 1 ? "Image" : "Image \(i + 1)", kind: .image(mime: "image/png"), data: nil,
                       serverPath: i < stored.imagePaths.count ? stored.imagePaths[i] : nil)
        }
        return (stored.text, images + stored.files.map(file))
    }

    private static func file(_ f: InlineFile) -> Attachment { Attachment(name: f.name, kind: .text, data: Data(f.text.utf8)) }
}

struct AttachmentError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

// MARK: - Loading and downscaling

enum AttachmentLoader {
    static let maxImageSide = 2048
    static let maxSourceImageBytes = 60_000_000
    static let maxTextFileBytes = 1_000_000
    /// Lossless sources stay PNG unless the PNG would be bigger than this; then JPEG (flattened on white).
    static let pngBudget = 2_000_000

    static func load(_ url: URL) throws -> Attachment {
        let v = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey, .localizedNameKey])
        let name = url.lastPathComponent
        if v.isDirectory == true { throw AttachmentError(message: "“\(name)” is a folder; attach the files inside it instead.") }
        let size = v.fileSize ?? 0
        let type = v.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) && !type.conforms(to: .svg) {
            guard size <= maxSourceImageBytes else { throw AttachmentError(message: "“\(name)” is too large to attach (\(bytes(size))).") }
            return try image(from: try Data(contentsOf: url), name: name)
        }
        guard size <= maxTextFileBytes else {
            throw AttachmentError(message: "“\(name)” is \(bytes(size)); text files up to \(bytes(maxTextFileBytes)) can be attached.")
        }
        let data = try Data(contentsOf: url)
        guard let text = decodeText(data, type: type) else {
            throw AttachmentError(message: "“\(name)” can't be attached: Hermes reads images and text files only.")
        }
        guard text.count <= ChatContent.maxTextCharacters else {
            throw AttachmentError(message: "“\(name)” has \(text.count.formatted()) characters; Hermes reads at most \(ChatContent.maxTextCharacters.formatted()) per message.")
        }
        return Attachment(name: name, kind: .text, data: Data(text.utf8))
    }

    /// Text if the bytes look like text: no NULs, valid UTF-8 (or a declared text type in a legacy encoding).
    static func decodeText(_ data: Data, type: UTType) -> String? {
        if data.prefix(8192).contains(0) { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        let declaredText = [UTType.text, .sourceCode, .json, .xml, .yaml, .commaSeparatedText, .propertyList].contains { type.conforms(to: $0) }
        return declaredText ? String(data: data, encoding: .windowsCP1252) : nil
    }

    /// Decodes any ImageIO image, downscales to `maxImageSide`, and re-encodes (which also drops EXIF/GPS metadata).
    static func image(from data: Data, name: String) throws -> Attachment {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
              let typeID = CGImageSourceGetType(src) as String? else {
            throw AttachmentError(message: "“\(name)” isn't an image macOS can read.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? maxImageSide
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? maxImageSide
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxImageSide, max(w, h, 1)),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw AttachmentError(message: "“\(name)” couldn't be decoded.")
        }
        let source = UTType(typeID) ?? .image
        let lossless = [UTType.png, .tiff, .gif, .bmp].contains { source.conforms(to: $0) }
        var mime = "image/jpeg", out: Data?
        if lossless, let png = encode(cg, as: .png), png.count <= pngBudget { mime = "image/png"; out = png }
        if out == nil { out = encode(flattened(cg) ?? cg, as: .jpeg, quality: 0.85) }
        guard let out else { throw AttachmentError(message: "“\(name)” couldn't be prepared for upload.") }
        attachLog.debug("image \(w)x\(h) -> \(cg.width)x\(cg.height) \(mime, privacy: .public) \(out.count) bytes [CHAT-ATTACH-IMG]")
        return Attachment(name: name, kind: .image(mime: mime), data: out, thumbnail: thumbnail(of: out))
    }

    static func thumbnail(of data: Data, side: Int = 320) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: side]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func encode(_ cg: CGImage, as type: UTType, quality: Double = 1) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// JPEG has no alpha; without this, transparent pixels (screenshot window shadows) turn black.
    private static func flattened(_ cg: CGImage) -> CGImage? {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    static func bytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    static func pastedImageName() -> String {
        let f = DateFormatter(); f.dateFormat = "HH.mm.ss"
        return "Pasted Image \(f.string(from: .now))"
    }
}

// MARK: - Composer tray

/// Attachments waiting in the composer. Global like `ChatStore.draft` (not per chat); cleared on send / New Chat.
@MainActor @Observable
final class AttachmentTray {
    private(set) var items: [Attachment] = []
    /// Files still being read/downscaled; the composer shows a spinner and holds Send.
    private(set) var loading = 0

    var isEmpty: Bool { items.isEmpty }

    func remove(_ a: Attachment) { items.removeAll { $0.id == a.id } }
    func clear() { items = [] }
    func replace(_ new: [Attachment]) { items = new }

    func add(urls: [URL], app: AppModel?) {
        guard !urls.isEmpty else { return }
        load(app) { try urls.map(AttachmentLoader.load) }
    }

    func add(imageData: Data, name: String, app: AppModel?) {
        load(app) { [try AttachmentLoader.image(from: imageData, name: name)] }
    }

    /// Loads off the main actor; each failure is reported, the rest still attach. Refuses additions that would
    /// push the message past Hermes' image count / size limits, so the problem shows up when attaching, not on Send.
    private func load(_ app: AppModel?, _ work: @escaping @Sendable () throws -> [Attachment]) {
        loading += 1
        Task.detached(priority: .userInitiated) {
            let result = Result { try work() }
            await MainActor.run {
                self.loading -= 1
                switch result {
                case .success(let new):
                    for a in new {
                        let next = self.items + [a]
                        if let problem = ChatContent.problem(with: Attachment.parts(text: "", next)) {
                            attachLog.info("attachment refused: \(problem, privacy: .public) [CHAT-ATTACH-LIMIT]")
                            app?.flash("Couldn't attach “\(a.name)”. \(problem)")
                            continue
                        }
                        self.items = next
                    }
                case .failure(let error):
                    attachLog.error("attachment failed: \(error.localizedDescription, privacy: .public) [CHAT-ATTACH-ERR]")
                    app?.flash(error.localizedDescription)
                }
            }
        }
    }

    /// Cmd-V: file URLs (Finder copy) or image data (screenshots via Cmd-Shift-Ctrl-4). Returns false to let the text
    /// field paste normally, e.g. when the clipboard's preferred flavor is text.
    func paste(from pb: NSPasteboard, app: AppModel?) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls: urls, app: app)
            return true
        }
        let types = pb.types ?? []
        let imageIndex = types.firstIndex { [.png, .tiff].contains($0) || (UTType($0.rawValue)?.conforms(to: .image) ?? false) }
        let textIndex = types.firstIndex { $0 == .string || $0 == .rtf || $0 == .html }
        guard let imageIndex, textIndex.map({ imageIndex < $0 }) ?? true else { return false }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) ?? pb.data(forType: types[imageIndex]) else { return false }
        add(imageData: data, name: AttachmentLoader.pastedImageName(), app: app)
        return true
    }

    func openPanel(app: AppModel?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Attach images or text files"
        panel.prompt = "Attach"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self.add(urls: urls, app: app) }
        }
    }

    /// Drag and drop: Finder files, or image data (e.g. dragged out of a browser or Photos).
    func drop(_ providers: [NSItemProvider], app: AppModel?) -> Bool {
        var handled = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                _ = p.loadObject(ofClass: NSURL.self) { obj, error in
                    let url = (obj as? NSURL) as URL?
                    Task { @MainActor in
                        if let url { self.add(urls: [url], app: app) }
                        else { self.reportDrop(error, app: app) }
                    }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                let name = p.suggestedName ?? AttachmentLoader.pastedImageName()
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    Task { @MainActor in
                        if let data { self.add(imageData: data, name: name, app: app) }
                        else { self.reportDrop(error, app: app) }
                    }
                }
            }
        }
        return handled
    }

    private func reportDrop(_ error: Error?, app: AppModel?) {
        attachLog.error("drop failed: \(error?.localizedDescription ?? "no data", privacy: .public) [CHAT-ATTACH-DROP-ERR]")
        app?.flash("Couldn't attach the dropped item\(error.map { ": \($0.localizedDescription)" } ?? ".")")
    }
}

// MARK: - Paste interception

/// The composer's TextField is backed by an NSTextView field editor that swallows Cmd-V; images never reach a
/// SwiftUI paste handler. A local key monitor sees Cmd-V first and hands it to the tray when it holds files/images.
// AIDEV-NOTE: only Cmd-V is intercepted; Edit > Paste from the menu bar still goes to the field editor (text only).
private final class PasteMonitor {
    var enabled = false
    var handle: ((NSPasteboard) -> Bool)?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.enabled,
                  e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "v",
                  self.handle?(.general) == true else { return e }
            return nil
        }
    }

    func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
}

private struct AttachmentPaste: ViewModifier {
    @Environment(AppModel.self) private var model
    var enabled: Bool
    @ViewState private var monitor = PasteMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor.enabled = enabled
                let app = model
                monitor.handle = { [weak app] pb in
                    MainActor.assumeIsolated { app.map { $0.chats.attachments.paste(from: pb, app: $0) } ?? false }
                }
                monitor.start()
            }
            .onDisappear { monitor.stop() }
            .onChange(of: enabled) { monitor.enabled = enabled }
    }
}

private struct AttachmentDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    @ViewState private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                model.chats.attachments.drop(providers, app: model)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accentSoft))
                        .overlay {
                            Label("Drop to attach", systemImage: "paperclip")
                                .font(.headline).padding(.horizontal, 16).padding(.vertical, 10)
                                .glassEffect(.regular, in: .capsule)
                        }
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.15), value: targeted)
    }
}

extension View {
    /// Cmd-V of images / file URLs into the composer tray while `enabled` (the composer has focus).
    func attachmentPaste(enabled: Bool) -> some View { modifier(AttachmentPaste(enabled: enabled)) }
    /// Files and images dropped anywhere on this view go to the composer tray.
    func attachmentDropTarget() -> some View { modifier(AttachmentDropTarget()) }
}

// MARK: - Views

/// The paperclip in the composer.
struct AttachButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button { model.chats.attachments.openPanel(app: model) } label: {
            Image(systemName: "paperclip").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Attach images or text files (or paste / drop them)")
        .accessibilityLabel("Attach files")
    }
}

/// Chips above the composer's text field.
struct AttachmentTrayView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let tray = model.chats.attachments
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(tray.items) { a in
                    AttachmentChip(attachment: a) { withAnimation(.smooth(duration: 0.2)) { tray.remove(a) } }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                if tray.loading > 0 { ProgressView().controlSize(.small).padding(.horizontal, 8).accessibilityLabel("Preparing attachment") }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}

/// Image thumbnail or file icon + name + size; an x when removable. Click previews with Quick Look.
struct AttachmentChip: View {
    @Environment(AppModel.self) private var model
    var attachment: Attachment
    var onRemove: (() -> Void)?
    @ViewState private var preview: URL?
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(attachment.sizeLabel ?? (attachment.isImage ? "Stored on Hermes" : "")).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 150, alignment: .leading)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Remove").accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(.leading, 5).padding(.trailing, onRemove == nil ? 10 : 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(hovering ? 0.8 : 0.55)))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { preview = AttachmentPreview.open(attachment, app: model) }
        .quickLookPreview($preview)
        .help(attachment.data == nil ? "Hermes keeps this image on the server; it can't be previewed here." : "Click to preview")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var icon: some View {
        if let t = attachment.thumbnail {
            Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc.text").font(.system(size: 16)).foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background.opacity(0.6)))
        }
    }
}

/// Attachments on a user message in the transcript: images as thumbnails, files as chips.
struct MessageAttachmentsView: View {
    var attachments: [Attachment]
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(attachments) { a in
                if a.isImage, a.thumbnail != nil { ImageThumb(attachment: a) }
                else if a.isImage, let p = a.serverPath, ImageRef.hasImageExtension(p) { StoredImageThumb(attachment: a, path: p) }
                else { AttachmentChip(attachment: a) }
            }
        }
    }
}

private struct ImageThumb: View {
    @Environment(AppModel.self) private var model
    var attachment: Attachment
    @ViewState private var preview: URL?
    var body: some View {
        if let t = attachment.thumbnail {
            let aspect = max(0.4, min(2.5, t.size.width / max(t.size.height, 1)))
            Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 150 * aspect, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { preview = AttachmentPreview.open(attachment, app: model) }
                .quickLookPreview($preview)
                .help("\(attachment.name) - click to preview")
                .accessibilityLabel("Image \(attachment.name)")
                .accessibilityAddTraits(.isButton)
        }
    }
}

/// Quick Look needs a file; attachments are written to a per-launch temp folder on first preview.
enum AttachmentPreview {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HermesAttachments", isDirectory: true)

    /// The file to preview, or nil (with a toast when it should have worked).
    @MainActor static func open(_ a: Attachment, app: AppModel) -> URL? {
        guard a.data != nil else { return nil } // history image: pixels stay on the server (chip help says so)
        guard let url = file(for: a) else { app.flash("Couldn't preview “\(a.name)”."); return nil }
        return url
    }

    @MainActor static func file(for a: Attachment) -> URL? {
        guard let data = a.data else { return nil }
        var name = a.name.replacingOccurrences(of: "/", with: "-")
        if case .image(let mime) = a.kind {
            let ext = mime == "image/png" ? "png" : "jpg"
            if (name as NSString).pathExtension.lowercased() != ext { name = (name as NSString).deletingPathExtension + "." + ext }
        }
        let dir = folder.appendingPathComponent(a.id.uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url) }
            return url
        } catch {
            attachLog.error("preview write failed: \(error.localizedDescription, privacy: .public) [CHAT-ATTACH-PREVIEW-ERR]")
            return nil
        }
    }
}
