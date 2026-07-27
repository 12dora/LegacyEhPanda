//
//  GalleryState.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/01.
//

import SwiftUI
import Foundation

struct GalleryState: Codable {
    static let empty = GalleryState(gid: "")
    static let preview = GalleryState(gid: "")

    let gid: String
    var tags = [GalleryTag]()
    var readingProgress = 0
    var previewURLs = [Int: URL]()
    var previewConfig: PreviewConfig?
    var comments = [GalleryComment]()
    var imageURLs = [Int: URL]()
    var originalImageURLs = [Int: URL]()
    var thumbnailURLs = [Int: URL]()
}
extension GalleryState: CustomStringConvertible {
    var description: String {
        let params = String(
            describing: [
                "gid": gid,
                "tagsCount": tags.count,
                "readingProgress": readingProgress,
                "previewURLsCount": previewURLs.count,
                "previewConfig": String(describing: previewConfig),
                "commentsCount": comments.count,
                "imageURLsCount": imageURLs.count,
                "originalImageURLsCount": originalImageURLs.count,
                "thumbnailURLsCount": thumbnailURLs.count
            ]
            as [String: Any]
        )
        return "GalleryState(\(params))"
    }
}

struct GalleryTag: Codable, Equatable, Hashable, Identifiable {
    struct Content: Codable, Equatable, Hashable, Identifiable {
        var id: String { rawNamespace + text }
        var firstLetterCapitalizedText: String {
            text.firstLetterCapitalized
        }
        func voteKeyword(tag: GalleryTag) -> String {
            let namespace = tag.namespace?.abbreviation ?? tag.namespace?.rawValue ?? tag.rawNamespace.lowercased()
            return tag.namespace == .temp ? text : [namespace, text].joined(separator: ":")
        }
        func serachKeyword(tag: GalleryTag) -> String {
            let keyword = text.contains(" ") ? "\"\(text)$\"" : "\(text)$"
            let namespace = tag.namespace?.abbreviation ?? tag.namespace?.rawValue ?? tag.rawNamespace.lowercased()
            return tag.namespace == .temp ? keyword : [namespace, keyword].joined(separator: ":")
        }

        let rawNamespace: String
        let text: String
        let isVotedUp: Bool
        let isVotedDown: Bool
        let textColor: Color?
        let backgroundColor: Color?

        init(
            rawNamespace: String, text: String, isVotedUp: Bool, isVotedDown: Bool,
            textColor: Color?, backgroundColor: Color?
        ) {
            self.rawNamespace = rawNamespace
            self.text = text
            self.isVotedUp = isVotedUp
            self.isVotedDown = isVotedDown
            self.textColor = textColor
            self.backgroundColor = backgroundColor
        }

        // Colors travel through the project's own `CodableColor` instead of a retroactive
        // conformance on the imported `Color`. The encoded shape is unchanged.
        private enum CodingKeys: String, CodingKey {
            case rawNamespace, text, isVotedUp, isVotedDown, textColor, backgroundColor
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rawNamespace = try container.decode(String.self, forKey: .rawNamespace)
            text = try container.decode(String.self, forKey: .text)
            isVotedUp = try container.decode(Bool.self, forKey: .isVotedUp)
            isVotedDown = try container.decode(Bool.self, forKey: .isVotedDown)
            textColor = try container.decodeIfPresent(CodableColor.self, forKey: .textColor)?.color
            backgroundColor = try container
                .decodeIfPresent(CodableColor.self, forKey: .backgroundColor)?.color
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rawNamespace, forKey: .rawNamespace)
            try container.encode(text, forKey: .text)
            try container.encode(isVotedUp, forKey: .isVotedUp)
            try container.encode(isVotedDown, forKey: .isVotedDown)
            try container.encodeIfPresent(CodableColor(textColor), forKey: .textColor)
            try container.encodeIfPresent(CodableColor(backgroundColor), forKey: .backgroundColor)
        }
    }

    var id: String { rawNamespace }
    var namespace: TagNamespace? {
        .init(rawValue: rawNamespace)
    }

    let rawNamespace: String
    let contents: [Content]
}

enum PreviewConfig: Codable, Equatable {
    case normal(rows: Int)
    case large(rows: Int)
}

extension PreviewConfig {
    var batchSize: Int {
        switch self {
        case .normal(let rows):
            return 10 * rows
        case .large(let rows):
            return 5 * rows
        }
    }

    func pageNumber(index: Int) -> Int {
        max(0, (index - 1) / batchSize)
    }
    func batchRange(index: Int) -> ClosedRange<Int> {
        let lowerBound = pageNumber(index: index) * batchSize + 1
        let upperBound = lowerBound + batchSize - 1
        return lowerBound...upperBound
    }
}
