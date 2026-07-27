//
//  DFRequest.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/13.
//

import Network
import Foundation

/// A single HTTP/1.1 exchange carried over Network.framework.
///
/// The transport exists so SNI bypass can reach a host by address while still
/// proving that the peer owns the real hostname. Trust is evaluated inside the
/// TLS handshake, which means the request line, headers, cookies and body are
/// only written after the peer has been accepted.
final class DFRequest {
    /// Time allowed to connect and complete the handshake.
    private static let handshakeTimeout: TimeInterval = 10
    private static let receiveChunkSize = 64 * 1024
    private static let idempotentMethods = ["GET", "HEAD"]
    /// Trust evaluation may hit the network, so it never runs on the queue
    /// that also carries the request's own timeout and delivery work.
    private static let verifyQueue = DispatchQueue(
        label: "app.EhPanda.DFRequest.verify",
        qos: .userInitiated, attributes: .concurrent
    )

    let request: URLRequest
    private(set) weak var delegate: DFRequestDelegate?

    private let url: URL
    /// The hostname the peer has to prove ownership of.
    private let host: String
    private let port: NWEndpoint.Port
    private let usesTLS: Bool

    private let queue = DispatchQueue(label: "app.EhPanda.DFRequest", qos: .userInitiated)
    private let lock = NSLock()
    private var isStopped = false

    private var connection: NWConnection?
    private var parser: DFResponseParser?
    private var deadline: DispatchWorkItem?
    /// Bounds the whole attempt chain, however many addresses it walks.
    private var expiration = Date.distantFuture
    private var addresses = [String]()
    private var addressIndex = 0
    private var sendsServerName = false
    private var lastError: Error?

    private var didSendRequest = false
    private var didDeliverResponse = false
    private var isCompleted = false

    // The body stream can only be drained once, so both are resolved lazily
    // and then reused by every attempt.
    private lazy var body: Data? = request.HTTPBody()
    private lazy var payload: Data? = request.serializedHTTPMessage(host: host, body: body)

    init?(
        _ req: URLRequest,
        delegate: DFRequestDelegate? = nil
    ) {
        self.delegate = delegate
        var preparedRequest = req

        if let url = req.url,
            let cookies = HTTPCookieStorage
            .shared.cookies(for: url) {
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                preparedRequest.setValue(value, forHTTPHeaderField: field)
            }
        }
        request = preparedRequest

        // The hostname is taken from the URL alone, never from a `Host` header:
        // it has to be the very origin the injected cookies are scoped to, or
        // trust could be proven for one host while another host's credentials
        // travel with the request.
        guard let url = preparedRequest.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty
        else {
            Logger.error("Unsupported request: \(req.url?.absoluteString ?? "nil").")
            delegate?.dfRequest(req, didFailWithError: URLError(.badURL))
            return nil
        }
        self.url = url
        self.host = host
        usesTLS = scheme == "https"
        port = url.port.flatMap { UInt16(exactly: $0) }
            .flatMap(NWEndpoint.Port.init(rawValue:))
            ?? (usesTLS ? .https : .http)
    }

    deinit {
        // A connection is only released once it has been cancelled.
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }

    func resume() {
        if !request.urlContainsImageURL {
            Logger.verbose("Request from: \(request.url?.absoluteString ?? "")")
        }

        queue.async { [weak self] in self?.start() }
    }

    func stop() {
        lock.lock()
        let wasStopped = isStopped
        isStopped = true
        lock.unlock()

        guard !wasStopped else { return }
        delegate = nil
        queue.async { [weak self] in self?.teardown() }
    }
}

// MARK: Connecting
private extension DFRequest {
    var isStoppedSafely: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    func start() {
        // However many addresses the chain walks, it may not outlive the
        // request's own timeout.
        expiration = Date().addingTimeInterval(max(request.timeoutInterval, Self.handshakeTimeout))

        switch DomainResolver.resolve(domain: host) {
        case .bypass(let resolved):
            // Reaching the host by address keeps its name off the wire; SNI is
            // only disclosed once a peer rejects the anonymous handshake.
            addresses = resolved
            sendsServerName = false
        case .system:
            addresses = [host]
            sendsServerName = true
        case .unresolved:
            fail(with: URLError(.cannotFindHost))
            return
        }
        connectNext()
    }

    func connectNext() {
        guard !isCompleted, !isStoppedSafely else { return }
        guard Date() < expiration else {
            fail(with: lastError ?? URLError(.timedOut))
            return
        }
        guard addressIndex < addresses.count else {
            fail(with: lastError ?? URLError(.cannotConnectToHost))
            return
        }

        let connection = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(addresses[addressIndex]), port: port),
            using: parameters()
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state, of: connection)
        }
        armDeadline(after: Self.handshakeTimeout, for: connection)
        connection.start(queue: queue)
    }

    func parameters() -> NWParameters {
        guard usesTLS else { return .tcp }

        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions

        if sendsServerName {
            sec_protocol_options_set_tls_server_name(security, host)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_peer_authentication_required(security, true)

        let expectedHost = host
        sec_protocol_options_set_verify_block(
            security,
            { _, trust, complete in
                // Runs inside the handshake, before a single application byte
                // is written, and always checks the real hostname even when
                // SNI was withheld.
                let peerTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let policies = [SecPolicyCreateSSL(true, expectedHost as CFString)] as CFArray

                guard SecTrustSetPolicies(peerTrust, policies) == errSecSuccess else {
                    complete(false)
                    return
                }
                var error: CFError?
                let isTrusted = SecTrustEvaluateWithError(peerTrust, &error)
                if !isTrusted {
                    Logger.error("Trust evaluation failed for \(expectedHost): \(error as Any).")
                }
                complete(isTrusted)
            },
            Self.verifyQueue
        )
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }

    func handle(state: NWConnection.State, of connection: NWConnection) {
        guard !isStoppedSafely, self.connection === connection else { return }

        switch state {
        case .ready:
            armDeadline(after: request.timeoutInterval, for: connection)
            send(over: connection)
        case .waiting(let error):
            // The path is unusable for now, the deadline decides when to move on.
            if !request.urlContainsImageURL {
                Logger.verbose("Connection waiting for \(host): \(error).")
            }
        case .failed(let error):
            attemptDidFail(error)
        case .cancelled:
            attemptDidFail(lastError ?? URLError(.networkConnectionLost))
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    func armDeadline(after interval: TimeInterval, for connection: NWConnection) {
        deadline?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.connection === connection else { return }
            Logger.warning("Connection timed out for: \(self.host).")
            self.attemptDidFail(URLError(.timedOut))
        }
        deadline = item
        queue.asyncAfter(deadline: .now() + max(interval, 1), execute: item)
    }

    func teardown() {
        deadline?.cancel()
        deadline = nil
        teardownConnection()
    }

    func teardownConnection() {
        let connection = self.connection
        self.connection = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
    }
}

// MARK: Transferring
private extension DFRequest {
    func send(over connection: NWConnection) {
        guard !didSendRequest else { return }
        guard let payload = payload else {
            fail(with: URLError(.badURL))
            return
        }
        didSendRequest = true
        parser = DFResponseParser(url: url, method: request.httpMethod ?? "GET")

        connection.send(
            content: payload, isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self = self else { return }
                guard !self.isStoppedSafely, self.connection === connection else { return }

                if let error = error {
                    self.attemptDidFail(error)
                } else {
                    self.receive(over: connection)
                }
            }
        )
    }

    func receive(over connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: Self.receiveChunkSize
        ) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }
            guard !self.isStoppedSafely, self.connection === connection else { return }

            if let error = error {
                self.attemptDidFail(error)
                return
            }
            self.armDeadline(after: self.request.timeoutInterval, for: connection)

            do {
                if let content = content, !content.isEmpty, let parser = self.parser {
                    self.emit(try parser.consume(content))
                }
                if isComplete, !self.isCompleted, let parser = self.parser {
                    self.emit(try parser.finish())
                }
            } catch {
                self.fail(with: error)
                return
            }

            guard !self.isCompleted, !isComplete else { return }
            self.receive(over: connection)
        }
    }

    func emit(_ events: [DFResponseEvent]) {
        for event in events {
            guard !isCompleted, !isStoppedSafely else { return }

            switch event {
            case .response(let response):
                // The redirect is recognised as soon as the head is complete,
                // so it replaces the response instead of following it.
                if let redirect = redirectRequest(for: response) {
                    Logger.warning("Request redirected to: \(redirect.url?.absoluteString ?? "").")
                    isCompleted = true
                    delegate?.dfRequest(
                        self, wasRedirectedTo: redirect,
                        redirectResponse: response
                    )
                    teardown()
                    return
                }
                didDeliverResponse = true
                delegate?.dfRequest(
                    self, didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
            case .data(let data):
                delegate?.dfRequest(self, didLoad: data)
            case .finished:
                isCompleted = true
                if !request.urlContainsImageURL {
                    Logger.verbose("Request loading finished for: \(url.absoluteString).")
                }
                delegate?.dfRequestDidFinishLoading(self)
                teardown()
                return
            }
        }
    }

    /// A retry may only happen while the client has observed nothing yet, and
    /// only when replaying the request cannot duplicate a mutation.
    var isRetryable: Bool {
        guard !didDeliverResponse else { return false }
        guard didSendRequest else { return true }
        return Self.idempotentMethods.contains(request.httpMethod?.uppercased() ?? "GET")
    }

    func attemptDidFail(_ error: Error) {
        guard !isCompleted, !isStoppedSafely else { return }
        lastError = error

        guard isRetryable else {
            fail(with: error)
            return
        }
        if !request.urlContainsImageURL {
            Logger.warning("Connection attempt failed for \(host): \(error).")
        }
        teardownConnection()
        didSendRequest = false
        parser = nil

        // A rejected handshake means the peer answered but would not present a
        // certificate for the host while SNI was withheld, so the same address
        // is retried disclosing it. Anything else moves on to the next address,
        // and once they are all spent the chain is replayed disclosing SNI.
        // Either way the flag only ever flips once, so the chain terminates.
        if usesTLS, !sendsServerName, Self.isHandshakeFailure(error) {
            sendsServerName = true
        } else {
            addressIndex += 1

            if usesTLS, !sendsServerName, addressIndex >= addresses.count {
                sendsServerName = true
                addressIndex = 0
            }
        }
        connectNext()
    }

    static func isHandshakeFailure(_ error: Error) -> Bool {
        guard let error = error as? NWError else { return false }
        if case .tls = error { return true }
        return false
    }

    func fail(with error: Error) {
        guard !isCompleted, !isStoppedSafely else { return }
        isCompleted = true

        if !request.urlContainsImageURL {
            Logger.error("Request failed for \(url.absoluteString): \(error).")
        }
        delegate?.dfRequest(request, didFailWithError: error)
        teardown()
    }
}

// MARK: Redirects
private extension DFRequest {
    static let redirectStatusCodes = [301, 302, 303, 307, 308]
    /// Fields that describe the previous hop rather than the request itself.
    static let strippedRedirectFields = [
        "host", "cookie", "content-length", "connection", "accept-encoding"
    ]

    /// Scheme, hostname and effective port, i.e. everything a credential is
    /// scoped to. A downgrade to `http` or a different port is a different
    /// origin, not the same one.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }

        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    func redirectRequest(for response: HTTPURLResponse) -> URLRequest? {
        let statusCode = response.statusCode
        guard Self.redirectStatusCodes.contains(statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)?.absoluteURL,
              let scheme = target.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return nil }

        let method = (request.httpMethod ?? "GET").uppercased()
        // 307 and 308 have to replay the original method and body, the older
        // codes degrade everything but HEAD to a bodyless GET.
        let preservesMethod = statusCode == 307 || statusCode == 308
        let sourceOrigin = Self.origin(of: url)
        let changesOrigin = sourceOrigin == nil || sourceOrigin != Self.origin(of: target)

        var redirect = URLRequest(
            url: target, cachePolicy: request.cachePolicy,
            timeoutInterval: request.timeoutInterval
        )
        redirect.httpMethod = preservesMethod ? method : (method == "HEAD" ? "HEAD" : "GET")
        redirect.httpShouldHandleCookies = request.httpShouldHandleCookies
        redirect.allowsCellularAccess = request.allowsCellularAccess
        redirect.networkServiceType = request.networkServiceType

        for (field, value) in request.allHTTPHeaderFields ?? .init() {
            let name = field.lowercased()
            guard !Self.strippedRedirectFields.contains(name) else { continue }
            // Payload description only survives together with the payload.
            guard preservesMethod || name != "content-type" else { continue }
            guard !changesOrigin || name != "authorization" else { continue }

            redirect.setValue(value, forHTTPHeaderField: field)
        }
        if preservesMethod { redirect.httpBody = body }

        return redirect
    }
}

// MARK: DFRequestDelegate
protocol DFRequestDelegate: AnyObject {
    func dfRequestDidFinishLoading(_ request: DFRequest)
    func dfRequest(_ request: DFRequest, didLoad data: Data)
    func dfRequest(_ request: URLRequest, didFailWithError error: Error)
    func dfRequest(
        _ request: DFRequest, wasRedirectedTo urlRequest: URLRequest,
        redirectResponse: URLResponse
    )
    func dfRequest(
        _ request: DFRequest, didReceive response: URLResponse,
        cacheStoragePolicy policy: URLCache.StoragePolicy
    )
}
