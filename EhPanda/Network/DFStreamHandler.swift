//
//  DFStreamHandler.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/07/13.
//

import Foundation

/// The protocol events an HTTP/1.1 response produces, in the order they must
/// be forwarded to `URLProtocolClient`.
enum DFResponseEvent {
    case response(HTTPURLResponse)
    case data(Data)
    case finished
}

enum DFResponseError: Error {
    case malformedHead
    case malformedChunk
    case headTooLarge
    case incompleteResponse
}

/// Incrementally parses an HTTP/1.1 response off a raw byte stream.
///
/// The parser is deliberately transport agnostic: it is fed whatever bytes
/// arrive and answers with the protocol events they complete, so a response
/// head is always reported exactly once, before and independently of any body.
final class DFResponseParser {
    /// The framing that determines where the body ends.
    private enum Framing {
        case empty
        case length(Int)
        case chunked
        case untilClose
    }

    private enum ChunkPhase {
        case size
        case data(remaining: Int)
        case dataEnd
        case trailer
    }

    private static let maxHeadBytes = 256 * 1024
    /// Bounds a single chunk size or trailer line, and the trailer as a whole,
    /// so an unterminated line cannot grow the buffer without limit.
    private static let maxLineBytes = 8 * 1024
    private static let maxTrailerBytes = 8 * 1024
    private static let separator = Data("\r\n\r\n".utf8)
    private static let lineBreak = Data("\r\n".utf8)

    private let url: URL
    private let method: String

    private var buffer = Data()
    private var framing: Framing = .untilClose
    private var chunkPhase: ChunkPhase = .size
    private var trailerBytes = 0
    private var response: HTTPURLResponse?
    private var isFinished = false

    init(url: URL, method: String) {
        self.url = url
        self.method = method.uppercased()
    }

    /// Feeds newly received bytes and returns the events they complete.
    func consume(_ data: Data) throws -> [DFResponseEvent] {
        guard !isFinished else { return [] }
        buffer.append(data)
        return try drain()
    }

    /// Reports that the peer closed the connection.
    func finish() throws -> [DFResponseEvent] {
        guard !isFinished else { return [] }

        guard response != nil else { throw DFResponseError.incompleteResponse }

        switch framing {
        case .untilClose:
            var events = [DFResponseEvent]()
            if !buffer.isEmpty { events.append(.data(takeBytes(buffer.count))) }
            events.append(.finished)
            isFinished = true
            return events
        default:
            throw DFResponseError.incompleteResponse
        }
    }
}

// MARK: Parsing
private extension DFResponseParser {
    func drain() throws -> [DFResponseEvent] {
        var events = [DFResponseEvent]()

        if response == nil {
            guard let head = try takeHead() else { return events }
            response = head
            framing = Self.framing(for: head, method: method)
            events.append(.response(head))
        }

        switch framing {
        case .empty:
            events.append(.finished)
            isFinished = true
        case .length(let remaining):
            let count = min(remaining, buffer.count)
            if count > 0 { events.append(.data(takeBytes(count))) }

            let left = remaining - count
            framing = .length(left)
            if left == 0 {
                events.append(.finished)
                isFinished = true
            }
        case .chunked:
            events.append(contentsOf: try drainChunked())
        case .untilClose:
            if !buffer.isEmpty { events.append(.data(takeBytes(buffer.count))) }
        }
        return events
    }

    /// Parses the response head, skipping any informational (1xx) heads that
    /// precede it. Returns `nil` while the head is still incomplete.
    func takeHead() throws -> HTTPURLResponse? {
        while true {
            guard let range = buffer.range(of: Self.separator) else {
                guard buffer.count <= Self.maxHeadBytes else { throw DFResponseError.headTooLarge }
                return nil
            }
            let headData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)

            let head = try parseHead(headData)
            if (100..<200).contains(head.statusCode) { continue }
            return head
        }
    }

    func parseHead(_ data: Data) throws -> HTTPURLResponse {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else { throw DFResponseError.malformedHead }

        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw DFResponseError.malformedHead }

        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"),
              let statusCode = Int(parts[1])
        else { throw DFResponseError.malformedHead }

        var fields = [String: String]()
        var lastKey: String?

        for line in lines where !line.isEmpty {
            // Obsolete line folding: the value continues the previous field.
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let key = lastKey, let existing = fields[key] else { continue }
                fields[key] = existing + " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let separator = line.firstIndex(of: ":") else { continue }

            let name = String(line[line.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            // Repeated fields are joined the same way `HTTPURLResponse` does.
            if let key = fields.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                fields[key] = (fields[key].map { $0 + ", " } ?? "") + value
                lastKey = key
            } else {
                fields[name] = value
                lastKey = name
            }
        }

        guard let response = HTTPURLResponse(
            url: url, statusCode: statusCode,
            httpVersion: String(parts[0]), headerFields: fields
        ) else { throw DFResponseError.malformedHead }

        return response
    }

    func drainChunked() throws -> [DFResponseEvent] {
        var events = [DFResponseEvent]()

        while true {
            switch chunkPhase {
            case .size:
                guard let line = try takeLine() else { return events }

                let size = line.split(separator: ";", maxSplits: 1).first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard let count = Int(size, radix: 16), count >= 0
                else { throw DFResponseError.malformedChunk }

                chunkPhase = count > 0 ? .data(remaining: count) : .trailer
            case .data(let remaining):
                guard !buffer.isEmpty else { return events }

                let count = min(remaining, buffer.count)
                events.append(.data(takeBytes(count)))

                let left = remaining - count
                chunkPhase = left > 0 ? .data(remaining: left) : .dataEnd
            case .dataEnd:
                guard let line = try takeLine() else { return events }
                guard line.isEmpty else { throw DFResponseError.malformedChunk }

                chunkPhase = .size
            case .trailer:
                guard let line = try takeLine() else { return events }
                guard line.isEmpty else {
                    // Trailers are discarded, but an endless stream of them is
                    // still an attempt to make the buffer grow forever.
                    trailerBytes += line.count + Self.lineBreak.count
                    guard trailerBytes <= Self.maxTrailerBytes
                    else { throw DFResponseError.malformedChunk }
                    continue
                }

                events.append(.finished)
                isFinished = true
                return events
            }
        }
    }

    func takeBytes(_ count: Int) -> Data {
        let end = buffer.index(buffer.startIndex, offsetBy: count)
        let data = buffer.subdata(in: buffer.startIndex..<end)
        buffer.removeSubrange(buffer.startIndex..<end)
        return data
    }

    /// Removes and returns the next CRLF terminated line, if it has arrived.
    ///
    /// Only the first `maxLineBytes` are ever searched: past that the peer is
    /// streaming an unterminated line rather than sending a slow one.
    func takeLine() throws -> String? {
        let limit = Self.maxLineBytes + Self.lineBreak.count

        let window = buffer.prefix(limit)
        guard let range = window.range(of: Self.lineBreak) else {
            guard window.count < limit else { throw DFResponseError.malformedChunk }
            return nil
        }

        let data = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func framing(for response: HTTPURLResponse, method: String) -> Framing {
        let statusCode = response.statusCode
        if method == "HEAD" || statusCode == 204 || statusCode == 304 { return .empty }

        if let encoding = response.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased(),
           encoding.contains("chunked") {
            return .chunked
        }
        if let field = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(field.trimmingCharacters(in: .whitespaces)), length >= 0 {
            return length > 0 ? .length(length) : .empty
        }
        return .untilClose
    }
}
