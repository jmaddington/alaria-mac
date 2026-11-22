import Foundation
import HermesKit
import Network
import os

private let log = Logger(subsystem: "net.jmaddington.hermes", category: "mcp")

/// Loopback-only HTTP/1.1 listener feeding MCPHTTPRouter. One request per connection (`Connection: close`).
// AIDEV-NOTE: security; bound to 127.0.0.1 with acceptLocalOnly. Do not widen to other interfaces without TLS:
// the bearer token would cross the LAN in clear. Remote Hermes hosts are out of scope (docs/agents/browser-tool.md).
public final class MCPHTTPListener: @unchecked Sendable {
    public enum ListenError: LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case .failed(let s) = self { return s }; return nil }
    }

    private let router: MCPHTTPRouter
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "net.jmaddington.hermes.mcp-listener")
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0

    /// Idle time allowed for the request bytes to arrive. Tool calls themselves may take longer.
    public var readTimeout: TimeInterval = 30

    public init(port: UInt16, router: MCPHTTPRouter) {
        self.requestedPort = port
        self.router = router
    }

    /// Starts listening; returns the bound port (useful with port 0 in checks).
    @discardableResult
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else { throw ListenError.failed("Bad port \(requestedPort)") }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let l: NWListener
        do { l = try NWListener(using: params) } catch {
            log.error("listener create failed: \(error.localizedDescription, privacy: .public) [MCP-LISTEN-CREATE-ERR]")
            throw ListenError.failed(error.localizedDescription)
        }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let bound: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ r: Result<UInt16, Error>) {
                if once.withLock({ done in defer { done = true }; return done }) { return }
                cont.resume(with: r)
            }
            l.stateUpdateHandler = { [weak l] state in
                switch state {
                case .ready: finish(.success(l?.port?.rawValue ?? 0))
                case .failed(let e):
                    log.error("listener failed: \(e.localizedDescription, privacy: .public) [MCP-LISTEN-ERR]")
                    finish(.failure(ListenError.failed(Self.describe(e, port: self.requestedPort))))
                case .waiting(let e):
                    // Port already in use shows up as waiting(EADDRINUSE); don't hang the caller.
                    log.error("listener waiting: \(e.localizedDescription, privacy: .public) [MCP-LISTEN-WAIT]")
                    l?.cancel()
                    finish(.failure(ListenError.failed(Self.describe(e, port: self.requestedPort))))
                case .cancelled: finish(.failure(ListenError.failed("Listener cancelled")))
                default: break
                }
            }
            l.start(queue: queue)
        }
        port = bound
        log.info("MCP listener ready on 127.0.0.1:\(bound) [MCP-LISTEN-OK]")
        return bound
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        log.info("MCP listener stopped [MCP-LISTEN-STOP]")
    }

    static func describe(_ e: NWError, port: UInt16) -> String {
        if case .posix(let code) = e, code == .EADDRINUSE { return "Port \(port) is already in use. Pick another port." }
        return e.localizedDescription
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        let deadline = DispatchWorkItem { [weak c] in
            log.info("closing idle MCP connection [MCP-CONN-TIMEOUT]")
            c?.cancel()
        }
        queue.asyncAfter(deadline: .now() + readTimeout, execute: deadline)
        receive(c, buffer: Data(), deadline: deadline)
    }

    private func receive(_ c: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { c.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let error {
                log.error("MCP connection receive error: \(error.localizedDescription, privacy: .public) [MCP-CONN-RECV-ERR]")
                deadline.cancel(); c.cancel(); return
            }
            switch HTTPParser.parse(buf) {
            case .incomplete:
                if isComplete { deadline.cancel(); c.cancel(); return }
                self.receive(c, buffer: buf, deadline: deadline)
            case .invalid(let status, let msg):
                deadline.cancel()
                log.error("bad MCP HTTP request: \(msg, privacy: .public) [MCP-HTTP-BAD]")
                self.send(c, HTTPResponse(status: status, headers: [("Content-Type", "text/plain")], body: Data(msg.utf8)))
            case .complete(let req):
                deadline.cancel()
                let router = self.router
                Task {
                    let resp = await router.respond(to: req)
                    if resp.status >= 400 { log.error("MCP \(req.method, privacy: .public) -> \(resp.status) [MCP-HTTP-REJECT]") }
                    self.send(c, resp)
                }
            }
        }
    }

    private func send(_ c: NWConnection, _ r: HTTPResponse) {
        c.send(content: r.serialized(), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
            if let error { log.error("MCP send failed: \(error.localizedDescription, privacy: .public) [MCP-CONN-SEND-ERR]") }
            c.cancel()
        })
    }
}
