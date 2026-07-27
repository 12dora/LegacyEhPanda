//
//  DFExtensions.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/13.
//

import Foundation

// MARK: URL
extension URL {
    func modifyComponent(for url: URL, commitChanges: (inout URLComponents) -> Void) -> URL? {
        guard var components = URLComponents(
            url: self, resolvingAgainstBaseURL: false
        )
        else { return nil }
        commitChanges(&components)
        return components.url
    }
    func replaceHost(to newHost: String?) -> URL? {
        modifyComponent(for: self) { components in
            components.host = newHost
        }
    }
    func replaceScheme(to newScheme: String?) -> URL? {
        modifyComponent(for: self) { components in
            components.scheme = newScheme
        }
    }
}

// MARK: URLRequest
extension URLRequest {
    var urlContainsImageURL: Bool {
        var containsTarget = false
        ["jpg", "jpeg", "png", "gif", "bmp"].forEach { type in
            if url?.absoluteString.contains(type) == true {
                containsTarget = true
            }
        }
        return containsTarget
    }
}

// MARK: URLSessionConfiguration
extension URLSessionConfiguration {
    static var domainFronting: URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [DFURLProtocol.self]
        return config
    }
}

// MARK: URLRequest
extension URLRequest {
    func HTTPBody() -> Data? {
        if let httpBody = httpBody { return httpBody }

        guard let stream = httpBodyStream
        else { return nil }

        stream.open()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>
            .allocate(capacity: bufferSize)
        defer {
            stream.close()
            buffer.deallocate()
        }

        var body = Data()
        var readSize = 0
        repeat {
            if stream.hasBytesAvailable == false { break }

            readSize = stream.read(buffer, maxLength: bufferSize)
            if readSize > 0 {
                body.append(buffer, count: readSize)
            } else if readSize == 0 {
                Logger.verbose("HTTPBodyStream read EOF.")
            } else {
                if let error = stream.streamError as Error? {
                    Logger.error("HTTPBodyStream read Error: \(error).")
                }
            }
        } while readSize > 0

        return body
    }

    /// Serializes the request as an HTTP/1.1 message for a raw byte transport.
    ///
    /// `host` carries the real hostname, which the transport keeps out of the
    /// endpoint it connects to.
    func serializedHTTPMessage(host: String, body: Data?) -> Data? {
        guard let url = url, let components = URLComponents(
            url: url, resolvingAgainstBaseURL: false
        )
        else { return nil }

        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?" + query }

        let method = (httpMethod ?? "GET").uppercased()
        var fields = allHTTPHeaderFields ?? .init()

        func setField(_ name: String, to value: String?) {
            for key in fields.keys where key.caseInsensitiveCompare(name) == .orderedSame {
                fields.removeValue(forKey: key)
            }
            if let value = value { fields[name] = value }
        }

        // One connection is opened per request and no response decoder is
        // wired up, so the exchange stays uncompressed and close delimited.
        setField("Host", to: nil)
        setField("Connection", to: "close")
        setField("Accept-Encoding", to: "identity")

        let length = body?.count ?? 0
        if length > 0 || ["POST", "PUT", "PATCH"].contains(method) {
            setField("Content-Length", to: String(length))
        } else {
            setField("Content-Length", to: nil)
        }

        // A hand-built message must not let a stray line break inside a field
        // smuggle extra request lines onto the wire.
        func sanitized(_ text: String) -> String {
            text.components(separatedBy: CharacterSet(charactersIn: "\r\n")).joined()
        }

        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(sanitized(host))"]
        for (field, value) in fields {
            let name = sanitized(field)
            guard !name.isEmpty else { continue }
            lines.append("\(name): \(sanitized(value))")
        }

        var message = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        if let body = body { message.append(body) }

        return message
    }
}
