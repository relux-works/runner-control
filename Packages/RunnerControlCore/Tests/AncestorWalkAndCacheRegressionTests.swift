import Darwin
import Foundation
import Testing
@testable import RunnerControlCore

// MARK: - Release blockers: CI ancestor-walk spin + stale API readback
//
// Focused behavioral regressions for TASK-260916-1x6xnq. Both drive the
// production entry point; see the task outcome artifact for mutant evidence.

// MARK: - Cache readback: localhost rig

enum CacheRegressionError: Error {
    case serverStartup(String)
}

/// Minimal HTTP/1.1 server for cache-behavior tests. Serves queued bodies,
/// every response cacheable (`Cache-Control: max-age=60`, mirroring the
/// GitHub responses in the live stale-read incident). Binds 127.0.0.1 on an
/// ephemeral port; counts accepted requests so tests can distinguish a
/// network readback from a cache hit.
///
/// A custom URLProtocol stub cannot exercise this path: on this Foundation
/// the loading system never consults URLCache for custom protocols, so such
/// a harness passes vacuously with or without the fix (verified by probe).
/// Only a real HTTP exchange through a real URLCache reproduces the
/// incident (default policy serves stale) and the fix (bypass reads fresh).
///
/// Single-owner sockets: the serve worker exclusively owns every socket
/// close. `stop()` performs no `shutdown`/`close` or any other operation on
/// FD integers — it only sets `running=false` under the shared condition and
/// waits for `workerExited` with a deadline. Accept, recv, and send are all
/// poll-bounded at 50ms and observe `running`, so no wakeup syscall is
/// needed. Concurrent, repeated, and timeout stops only observe state and
/// wait; the worker's `defer` closes the owned listener once, then signals
/// `workerExited` and broadcasts so every waiter observes exit.
/// `listenerNumber` remembers the listener integer for test observation
/// only (descriptor-reuse regression); `stop()` never operates on it.
final class CacheRegressionServer: @unchecked Sendable {
    private let condition = NSCondition()
    private var _hits = 0
    private var _running = true
    private var _workerExited = false
    private var _hasActiveClient = false
    private var _accepted = 0
    let bodies: [String]
    let port: UInt16
    let listenerNumber: Int32

    var hits: Int {
        condition.lock()
        defer { condition.unlock() }
        return _hits
    }
    var acceptedCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return _accepted
    }
    var hasActiveClient: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _hasActiveClient
    }

    init(bodies: [String]) throws {
        self.bodies = bodies
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw CacheRegressionError.serverStartup("socket failed") }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(sock, 16) == 0 else {
            // Pre-transfer failure: the worker does not exist yet, so init
            // must release the socket to avoid a leak. After the transfer
            // below, only the worker closes.
            close(sock)
            throw CacheRegressionError.serverStartup("bind/listen failed")
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        self.port = UInt16(bigEndian: out.sin_port)
        self.listenerNumber = sock
        // Transfer FD ownership to the worker. `listenerNumber` retains the
        // integer for observation only (reuse regression); stop() only flips
        // running and waits on the condition, never operating on it. The
        // detached thread holds a strong self until serve returns, so
        // deallocation follows exit and no deinit close exists.
        Thread.detachNewThread { [self, sock] in
            self.serve(listener: sock)
        }
    }

    /// Bounded shutdown. Sets running=false under the condition and waits
    /// until workerExited with a deadline. Performs no shutdown/close or any
    /// other operation on FD integers. Returns true when the worker exited
    /// within the bound. Idempotent: concurrent, repeated, and timeout
    /// callers only observe state and wait; the worker alone closes sockets.
    @discardableResult
    func stop(timeout: TimeInterval = 5) -> Bool {
        condition.lock()
        _running = false
        let deadline = Date().addingTimeInterval(timeout)
        while !_workerExited {
            if Date() >= deadline { break }
            condition.wait(until: deadline)
        }
        let exited = _workerExited
        condition.unlock()
        return exited
    }

    private func isRunning() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return _running
    }

    private func serve(listener: Int32) {
        defer {
            close(listener)
            condition.lock()
            _workerExited = true
            condition.broadcast()
            condition.unlock()
        }
        while true {
            if !isRunning() { return }
            // Bounded accept: poll observes running every 50ms, so stop()
            // needs no wakeup shutdown syscall to unblock a parked accept.
            var listenPoll = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let listenReady = poll(&listenPoll, 1, 50)
            if !isRunning() { return }
            if listenReady <= 0 { continue }
            guard (listenPoll.revents & Int16(POLLIN)) != 0 else { continue }
            let clientFD = accept(listener, nil, nil)
            if clientFD < 0 {
                if !isRunning() { return }
                continue
            }
            // Suppress SIGPIPE so an early client disconnect fails via
            // expectations, never a signal.
            var nosig: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            condition.lock()
            _accepted += 1
            _hasActiveClient = true
            condition.unlock()
            var request = Data()
            let complete = recvCompleteHeaders(clientFD: clientFD, request: &request)
            condition.lock()
            _hasActiveClient = false
            condition.unlock()
            guard complete else {
                // Incomplete headers: a stop-cancelled stall, or a client
                // that disconnected early. Never counted as served.
                close(clientFD)
                if !isRunning() { return }
                continue
            }
            condition.lock()
            let index = _hits
            _hits += 1
            condition.unlock()
            let body = bodies[min(index, bodies.count - 1)]
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                "Content-Length: \(body.utf8.count)\r\nCache-Control: max-age=60\r\n" +
                "Connection: close\r\n\r\n\(body)"
            _ = sendBounded(clientFD: clientFD, bytes: Array(response.utf8))
            close(clientFD)
        }
    }

    /// Reads until the end of HTTP headers, observing running every 50ms so
    /// a stalled incomplete-header client is cancelled promptly on stop()
    /// without any cross-thread FD operation. Returns true only when
    /// complete headers arrived. Never closes: the caller owns the FD.
    private func recvCompleteHeaders(clientFD: Int32, request: inout Data) -> Bool {
        let terminator = Data("\r\n\r\n".utf8)
        var buf = [UInt8](repeating: 0, count: 4096)
        while isRunning() {
            var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 50)
            if !isRunning() { return false }
            if ready < 0 {
                if errno == EINTR { continue }
                return request.range(of: terminator) != nil
            }
            if ready == 0 { continue }
            guard (pfd.revents & Int16(POLLIN)) != 0 else {
                return request.range(of: terminator) != nil
            }
            let count = recv(clientFD, &buf, buf.count, 0)
            if count <= 0 { return request.range(of: terminator) != nil }
            request.append(contentsOf: buf[..<count])
            if request.range(of: terminator) != nil { return true }
        }
        return false
    }

    /// Bounded send for the tiny test payload. Polls for writability every
    /// 50ms and observes running, so stop() cancels a blocked send without
    /// any cross-thread FD operation. Never closes: the caller owns the FD.
    private func sendBounded(clientFD: Int32, bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            if !isRunning() { return false }
            var pfd = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, 50)
            if !isRunning() { return false }
            if ready <= 0 { continue }
            if (pfd.revents & (Int16(POLLOUT) | Int16(POLLERR) | Int16(POLLHUP))) == 0 { continue }
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(clientFD, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent <= 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += sent
        }
        return true
    }
}

/// Records the outgoing URLRequest built by the production transport and
/// answers a canned body. Used only to pin request construction (cache
/// policy, method, auth passthrough), never to model cache behavior.
final class RecordingCacheStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var _seen: [URLRequest] = []

    static var seen: [URLRequest] { lock.withLock { _seen } }

    static func reset() { lock.withLock { _seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._seen.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Cache readback regressions

/// Live-incident shape (TASK7cxfal): a PUT persisted new repository IDs but
/// the product GET seconds later returned the old list — the default
/// URLRequest policy served GitHub's max-age=60 response from URLCache.
/// Production call site: `URLSessionGitHubTransport.send`.
@Test func authenticatedReadbackSeesNewServerStateDespiteCacheableResponse() async throws {
    let server = try CacheRegressionServer(bodies: [#"{"repositories":[]}"#, #"{"repositories":[{"id":1}]}"#])
    defer { server.stop() }
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
    config.requestCachePolicy = .useProtocolCachePolicy
    let transport = URLSessionGitHubTransport(session: URLSession(configuration: config))
    let url = URL(string: "http://127.0.0.1:\(server.port)/repos")!
    let headers = ["Authorization": "Bearer [REDACTED]"]
    let first = try await transport.send(GitHubHTTPRequest(method: "GET", url: url, headers: headers))
    #expect(String(decoding: first.body, as: UTF8.self) == #"{"repositories":[]}"#)
    // Server state changed between the reads; the previously cacheable OLD
    // response must not be served.
    let second = try await transport.send(GitHubHTTPRequest(method: "GET", url: url, headers: headers))
    #expect(String(decoding: second.body, as: UTF8.self) == #"{"repositories":[{"id":1}]}"#)
    #expect(server.hits == 2)
    // Happy-path worker cleanup is asserted, not ignored in defer: stop
    // must report worker exit within the bound after served requests.
    #expect(server.stop(timeout: 5))
}

/// Pins the mechanism behind the readback test: every request the
/// production transport builds bypasses the local cache, while method and
/// Authorization passthrough are preserved. Production call site:
/// `URLSessionGitHubTransport.send`.
@Test func transportSendsCurrentStateCachePolicyAndPreservesAuth() async throws {
    RecordingCacheStub.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RecordingCacheStub.self]
    let transport = URLSessionGitHubTransport(session: URLSession(configuration: config))
    let url = URL(string: "https://api.github.com/orgs/acme/actions/runner-groups/1/repositories?per_page=100")!
    let response = try await transport.send(GitHubHTTPRequest(
        method: "GET", url: url,
        headers: ["Accept": "application/vnd.github+json", "Authorization": "Bearer [REDACTED]"]
    ))
    #expect(response.status == 200)
    let seen = RecordingCacheStub.seen
    #expect(seen.count == 1)
    #expect(seen.first?.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(seen.first?.httpMethod == "GET")
    #expect(seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer [REDACTED]")
    #expect(seen.first?.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(seen.first?.url == url)
}

/// F1: stopping with a stalled incomplete-header client still connected
/// must cancel worker I/O and exit bounded without requiring the client
/// to close first. The client socket stays open across stop(); cleanup is
/// proved by the worker-exit signal, not by client teardown. Entry point:
/// `CacheRegressionServer.stop(timeout:)`.
@Test func stalledClientStopCompletesBoundedWithoutClientClose() throws {
    let server = try CacheRegressionServer(bodies: ["{}"])
    defer { server.stop() }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #expect(fd >= 0)
    guard fd >= 0 else { return }
    defer {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = server.port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    #expect(connected == 0)
    _ = "GET / HTTP/1.1\r\n".withCString { send(fd, $0, strlen($0), 0) }
    // Deterministic gate: only call stop once the server is provably
    // blocked in the stalled read; otherwise the test could pass without
    // exercising the cancellation path.
    let acceptDeadline = Date().addingTimeInterval(2)
    while !server.hasActiveClient, Date() < acceptDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    #expect(server.hasActiveClient)
    #expect(server.acceptedCount == 1)
    let start = Date()
    let stopped = server.stop(timeout: 5)
    let elapsed = Date().timeIntervalSince(start)
    #expect(stopped)
    #expect(elapsed < 4)
    #expect(server.hits == 0)
}

/// Thread-safe collector for concurrent stop outcomes. Swift Testing
/// expectations are asserted after the fan-out, never inside it.
private final class LockedStopResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { values.append(value) } }
    var snapshot: [Bool] { lock.withLock { values } }
}

/// F1 single-owner (rev4): concurrent and repeated stops only observe worker
/// exit and never touch FD integers. Eight parallel stop() callers plus
/// repeated stops after exit must all report true, while a positively owned
/// unrelated socketpair (no dup2 onto freed integers in the shared parallel
/// process) stays healthy throughout. A broadcast weakened to signal leaves
/// all but one waiter timed out. Entry point:
/// `CacheRegressionServer.stop(timeout:)`.
@Test func concurrentAndRepeatedStopLeavesUnrelatedSocketsUntouched() throws {
    let server = try CacheRegressionServer(bodies: ["{}"])
    defer { server.stop() }
    // Positively owned unrelated sockets; never a dup2 onto a freed number.
    var pair: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    guard pair[0] >= 0, pair[1] >= 0 else { return }
    // Suppress SIGPIPE so an FD-touching mutant fails via expectations.
    var nosig: Int32 = 1
    setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    defer {
        close(pair[0])
        close(pair[1])
    }
    var value: UInt8 = 42
    #expect(send(pair[0], &value, 1, 0) == 1)
    #expect(recv(pair[1], &value, 1, 0) == 1)
    // Concurrent fan-out: every waiter must observe the single worker exit,
    // promptly via broadcast (a signal wakes only one; the rest time out).
    let results = LockedStopResults()
    let stopCount = 8
    let fanOutStart = Date()
    DispatchQueue.concurrentPerform(iterations: stopCount) { _ in
        results.append(server.stop(timeout: 5))
    }
    let fanOutElapsed = Date().timeIntervalSince(fanOutStart)
    let snapshot = results.snapshot
    #expect(snapshot.count == stopCount)
    #expect(snapshot.allSatisfy { $0 })
    #expect(fanOutElapsed < 4)
    // Repeated stops after exit are idempotent and touch nothing.
    #expect(server.stop(timeout: 5))
    #expect(server.stop(timeout: 5))
    // Unrelated pair untouched: no EOF, still healthy.
    let probe = recv(pair[1], &value, 1, MSG_DONTWAIT)
    let probeErrno = errno
    #expect(probe == -1)
    #expect(probeErrno == EAGAIN)
    #expect(send(pair[0], &value, 1, 0) == 1)
    #expect(recv(pair[1], &value, 1, 0) == 1)
}

/// F1 single-owner timeout (rev4): a stop with an expired deadline reports
/// false without touching FDs, and a later stop still observes the bounded
/// worker exit. The zero timeout is deterministic: the worker needs up to
/// 50ms of poll to observe running=false, while the first stop holds the
/// condition across its immediate deadline check. Entry point:
/// `CacheRegressionServer.stop(timeout:)`.
@Test func stopTimeoutReportsFalseThenLaterStopSucceeds() throws {
    let server = try CacheRegressionServer(bodies: ["{}"])
    defer { server.stop() }
    #expect(server.stop(timeout: 0) == false)
    #expect(server.stop(timeout: 5))
    #expect(server.stop(timeout: 5))
}

/// F1 descriptor-reuse (rev5): after the worker exits and releases the
/// listener, repeated and concurrent stops must not touch the relinquished
/// descriptor number — even when the kernel has naturally reused it for an
/// unrelated, positively owned socket. The test observes the listener
/// number, stops the server, then holds fresh socketpairs until one reuses
/// that number (bounded 10s search over 16-pair rounds, tolerating
/// parallel-process FD churn without dup2 onto freed integers), verifies
/// health, issues repeated plus concurrent stops, and asserts the reused
/// socket stays healthy (no EOF). A stop that shuts down the remembered
/// listener (the rev2–rev4 F1 class) EOFs the peer. Entry point:
/// `CacheRegressionServer.stop(timeout:)`.
@Test func repeatedStopAfterOwnershipReleaseLeavesReusedDescriptorHealthy() throws {
    let server = try CacheRegressionServer(bodies: ["{}"])
    defer { server.stop() }
    let oldFD = server.listenerNumber
    #expect(oldFD >= 0)
    #expect(server.stop(timeout: 5))
    var target: Int32 = -1
    var peer: Int32 = -1
    var spare: [Int32] = []
    let deadline = Date().addingTimeInterval(10)
    search: while Date() < deadline {
        var round: [Int32] = []
        for _ in 0..<16 {
            var candidate: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &candidate) == 0 else { break }
            if candidate.contains(oldFD) {
                if candidate[0] == oldFD {
                    target = candidate[0]
                    peer = candidate[1]
                } else {
                    target = candidate[1]
                    peer = candidate[0]
                }
                spare = round
                break search
            }
            round.append(contentsOf: candidate)
        }
        for fd in round { close(fd) }
        Thread.sleep(forTimeInterval: 0.01)
    }
    for fd in spare { close(fd) }
    guard target >= 0, peer >= 0 else {
        Issue.record("Could not observe natural reuse of released listener FD \(oldFD) within 10s")
        return
    }
    defer {
        close(target)
        close(peer)
    }
    // Suppress SIGPIPE so an FD-touching mutant fails via expectations.
    var nosig: Int32 = 1
    setsockopt(target, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    var byte: UInt8 = 7
    #expect(send(target, &byte, 1, 0) == 1)
    #expect(recv(peer, &byte, 1, 0) == 1)
    // Repeated stops after exit plus a concurrent fan-out: all idempotent,
    // none touching the reused descriptor.
    #expect(server.stop(timeout: 5))
    #expect(server.stop(timeout: 5))
    let results = LockedStopResults()
    DispatchQueue.concurrentPerform(iterations: 4) { _ in
        results.append(server.stop(timeout: 5))
    }
    let snapshot = results.snapshot
    #expect(snapshot.count == 4)
    #expect(snapshot.allSatisfy { $0 })
    // Reused descriptor untouched: no EOF, still healthy.
    let probe = recv(peer, &byte, 1, MSG_DONTWAIT)
    let probeErrno = errno
    #expect(probe == -1)
    #expect(probeErrno == EAGAIN)
    #expect(send(target, &byte, 1, 0) == 1)
    #expect(recv(peer, &byte, 1, 0) == 1)
}

// MARK: - Ancestor-walk regressions

private func makeAliasFixture() throws -> (root: URL, alias: URL) {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("AliasWalk-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target")
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("aliasdir")
    let data = try target.bookmarkData(
        options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil
    )
    try URL.writeBookmarkData(data, to: alias)
    return (root, alias)
}

private func lexicalChain(_ start: String) -> [String] {
    var chain = [start]
    var current: String? = start
    while let parent = RunnerInstallerService.lexicalParent(of: current!) {
        chain.append(parent)
        current = parent
    }
    return chain
}

/// Models the hosted-CI Foundation behavior class behind the release
/// blocker: at the filesystem root the legacy `deletingLastPathComponent`
/// step never reaches the `parent.path == current.path` fixpoint the old
/// `while true` loop required (both unregister tests CPU-spun at
/// `ensureNoAlias` line 94 on macOS 15.7/Xcode 26.3). The exact CI
/// spelling is unobservable from here; this is the minimal member of that
/// class — root oscillation between two spellings — against which the old
/// equality-only rule provably never terminates.
private func ciLikeLegacyStep(_ path: String) -> String? {
    if path == "/" { return "" }
    if path.isEmpty { return "/" }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    return parent == path ? nil : parent
}

/// Hosted CI proved the old root walk spins; the lexical walk must
/// terminate across absolute root, missing, and relative path forms.
/// Production call site: `RunnerInstallerService.ensureNoAlias(at:)`.
@Test func aliasWalkTerminatesAcrossRootAndRelativeForms() throws {
    try RunnerInstallerService.ensureNoAlias(at: URL(fileURLWithPath: "/"))
    try RunnerInstallerService.ensureNoAlias(at: URL(fileURLWithPath: "/",
                                                     isDirectory: true))
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("definitely-missing-\(UUID().uuidString)")
        .appendingPathComponent("child")
    try RunnerInstallerService.ensureNoAlias(at: missing)
    try RunnerInstallerService.ensureNoAlias(
        at: URL(fileURLWithPath: "relative-\(UUID().uuidString)/child")
    )
    #expect(lexicalChain("/") == ["/"])
    #expect(lexicalChain("/a") == ["/a", "/"])
    #expect(lexicalChain("/a/b") == ["/a/b", "/a", "/"])
    #expect(lexicalChain("/a/") == ["/a/", "/"])
    #expect(lexicalChain("a/b/c") == ["a/b/c", "a/b", "a", "."])
    #expect(lexicalChain("a") == ["a", "."])
}

/// Finder-alias refusal is preserved for both the leaf and ancestors —
/// including ancestors of a not-yet-created install dir. Production call
/// site: `RunnerInstallerService.ensureNoAlias(at:)`.
@Test func aliasWalkRefusesFinderAliasLeafAndAncestors() throws {
    let (root, alias) = try makeAliasFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for probe in [alias, alias.appendingPathComponent("not-yet-created")] {
        do {
            try RunnerInstallerService.ensureNoAlias(at: probe)
            Issue.record("ensureNoAlias admitted alias path '\(probe.path)'")
        } catch let error as RunnerRegistration.RegistrationError {
            guard case .invalidDraft(let text) = error else {
                Issue.record("Wrong refusal for '\(probe.path)': \(error)")
                continue
            }
            #expect(text.contains(alias.path))
        }
    }
}

/// Symlinks keep their existing supported behavior: `isAliasFileKey` is
/// also true for symlinks, so without the explicit exclusion every path
/// through the system `/var`/`/tmp` links would be refused. Production
/// call site: `RunnerInstallerService.ensureNoAlias(at:)`.
@Test func aliasWalkAdmitsSymlinkedPaths() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("AliasWalkLink-\(UUID().uuidString)")
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try files.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("linkdir")
    try files.createSymbolicLink(at: link, withDestinationURL: target)
    // Pin why the exclusion matters: the fixture really is alias-shaped.
    #expect(try link.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true)
    try RunnerInstallerService.ensureNoAlias(at: link)
    try RunnerInstallerService.ensureNoAlias(at: link.appendingPathComponent("child"))
    try RunnerInstallerService.ensureNoAlias(at: files.temporaryDirectory)
}

/// A parent step that never reaches a root — the CI behavior class —
/// terminates by refusing fail-closed instead of spinning. Production
/// call site: `RunnerInstallerService.ensureNoAlias(at:parentStep:)`.
@Test func aliasWalkBoundRefusesNonTerminatingStep() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AliasWalkBound-\(UUID().uuidString)")
    do {
        try RunnerInstallerService.ensureNoAlias(at: dir, parentStep: ciLikeLegacyStep)
        Issue.record("Bounded walk admitted a non-terminating parent step")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .invalidDraft(let text) = error else {
            Issue.record("Wrong bound refusal: \(error)")
            return
        }
        #expect(text.contains("could not be verified"))
        #expect(text.contains(dir.path))
    }
}

/// The alias gate is reachable — and terminating — through a real
/// production mutation, not only through the helper. `setupService`
/// checks the walk before touching the service manifest. Production call
/// site: `RunnerInstallerService.requireIdleInstaller` via `setupService`.
@Test func aliasRefusalSurfacesThroughProductionServiceSetup() async throws {
    let (root, alias) = try makeAliasFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = RunnerInstallerService(installRoot: root)
    do {
        try await service.setupService(directory: alias, label: "works.relux.test.alias")
        Issue.record("setupService admitted an alias directory")
    } catch let error as RunnerRegistration.RegistrationError {
        guard case .invalidDraft(let text) = error else {
            Issue.record("Wrong setupService refusal: \(error)")
            return
        }
        #expect(text.contains(alias.path))
    }
    let dir = root.appendingPathComponent("normal")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("runsvc.sh"))
    let plist = try await service.setupService(directory: dir, label: "works.relux.test.normal")
    #expect(FileManager.default.fileExists(atPath: plist.path))
}
