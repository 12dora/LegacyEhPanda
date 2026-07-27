//
//  GalleryComment.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/01.
//

import Foundation

struct GalleryComment: Identifiable, Equatable, Codable {
    var id: String { commentID }

    var votedUp: Bool
    var votedDown: Bool
    let votable: Bool
    let editable: Bool

    let score: String?
    let author: String
    let contents: [CommentContent]
    let commentID: String
    let commentDate: Date

    /// Lossy, display-only summary of the comment.
    ///
    /// Images are dropped, linked text keeps only its display text and segments are joined
    /// without separators, so this must never be submitted back to the server as a replacement
    /// body. Use `editingSource` for that.
    var plainTextContent: String {
        contents
            .filter { [.plainText, .linkedText, .singleLink].contains($0.type) }
            .compactMap { $0.type == .singleLink ? $0.link?.absoluteString : $0.text }.joined()
    }

    /// The comment body exactly as it would have to be typed to reproduce this comment,
    /// or `nil` when the parsed representation cannot be rebuilt losslessly.
    ///
    /// Editing replaces the *whole* comment on the server, so anything the parser cannot
    /// reconstruct — images, `[url=…]` link targets, the whitespace it trimmed between
    /// segments, unknown HTML entities — must not be offered for native editing: resubmitting
    /// it would silently delete content. Only a comment that survives as a single, fully
    /// reconstructible segment qualifies.
    var editingSource: String? {
        guard contents.count == 1, let content = contents.first else { return nil }
        switch content.type {
        case .plainText:
            return content.text.flatMap(Self.decodedHTMLEntities)
        case .linkedText:
            // Only auto-linked bare URLs round-trip; `[url=…]display[/url]` loses its target.
            guard let text = content.text, let link = content.link,
                  text == link.absoluteString
            else { return nil }
            return text
        case .singleLink:
            return content.link?.absoluteString
        case .singleImg, .doubleImg, .linkedImg, .doubleLinkedImg:
            return nil
        }
    }

    /// Whether the comment can be edited in the app without losing content on the server.
    var isNativelyEditable: Bool {
        editable && editingSource != nil
    }

    /// Plain text segments are captured as raw inner HTML, so they arrive entity-escaped.
    /// Returns `nil` for anything this table does not cover, which disables native editing
    /// instead of round-tripping a body we cannot decode with certainty.
    private static let knownHTMLEntities = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&apos;": "'", "&#39;": "'"
    ]

    private static func decodedHTMLEntities(_ text: String) -> String? {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            result.append(contentsOf: text[index..<ampersand])
            guard let semicolon = text[ampersand...].firstIndex(of: ";"),
                  text.distance(from: ampersand, to: semicolon) <= 8,
                  let replacement = knownHTMLEntities[String(text[ampersand...semicolon])]
            else { return nil }
            result.append(replacement)
            index = text.index(after: semicolon)
        }
        result.append(contentsOf: text[index...])
        return result
    }
}

extension GalleryComment: DateFormattable {
    var originalDate: Date {
        commentDate
    }
}

struct CommentContent: Identifiable, Equatable, Codable {
    var id: UUID = .init()
    let type: CommentContentType
    var text: String?
    var link: URL?
    var imgURL: URL?

    var secondLink: URL?
    var secondImgURL: URL?
}

enum CommentContentType: Int, Codable {
    case singleImg
    case doubleImg
    case linkedImg
    case doubleLinkedImg

    case plainText
    case linkedText

    case singleLink
}
