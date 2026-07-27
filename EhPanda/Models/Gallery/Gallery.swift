//
//  Gallery.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/02/01.
//

import SwiftUI

struct Gallery: Identifiable, Codable, Equatable, Hashable {
    // A gallery is an identity value: everywhere galleries are collected, deduplicated or diffed
    // they stand for one gallery on the site, which the GID identifies. Equality and hashing have
    // to agree on that, otherwise the synthesized hash (which mixes in every field) would break the
    // "equal values hash equally" requirement that Set, Dictionary and SwiftUI's identity map rely
    // on. Note that this deliberately makes two payloads of the same gallery interchangeable, so
    // refreshed metadata has to be applied by replacing the element, not by comparing it.
    static func == (lhs: Gallery, rhs: Gallery) -> Bool {
        lhs.gid == rhs.gid
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(gid)
    }

    static func mockGalleries(count: Int, randomID: Bool = true) -> [Gallery] {
        guard randomID, count > 0 else {
            return Array(repeating: .empty, count: count)
        }
        return (0...count).map { _ in .empty }
    }
    static var empty: Gallery {
        .init(
            gid: UUID().uuidString,
            token: "",
            title: "",
            rating: 0.0,
            tags: [],
            category: .doujinshi,
            uploader: "",
            pageCount: 1,
            postedDate: .now,
            coverURL: nil,
            galleryURL: nil
        )
    }
    static let preview = Gallery(
        gid: UUID().uuidString,
        token: "",
        title: "Preview",
        rating: 3.5,
        tags: [],
        category: .doujinshi,
        uploader: "Anonymous",
        pageCount: 1,
        postedDate: .now,
        coverURL: URL(
            string: "https://github.com/"
            + "EhPanda-Team/Imageset/blob/"
            + "main/JPGs/2.jpg?raw=true"
        ),
        galleryURL: nil
    )

    var trimmedTitle: String {
        var title = title
        if let range = title.range(of: "|") {
            title = String(title[..<range.lowerBound])
        }
        title = title.barcesAndSpacesRemoved
        return title
    }
    var language: Language? {
        let rawValue = tags
            .first(where: { $0.namespace == .language })?.contents
            .first(where: { Language(rawValue: $0.firstLetterCapitalizedText) != nil })
            .map(\.firstLetterCapitalizedText) ?? ""
        return .init(rawValue: rawValue)
    }
    func tagContents(maximum: Int) -> [GalleryTag.Content] {
        let tagContents = tags.flatMap(\.contents)
        guard maximum > 0 else { return tagContents }
        return .init(tagContents.prefix(min(tagContents.count, maximum)))
    }

    var id: String { gid }
    let gid: String
    let token: String

    var title: String
    var rating: Float
    var tags: [GalleryTag]
    let category: Category
    var uploader: String?
    var pageCount: Int
    let postedDate: Date
    let coverURL: URL?
    let galleryURL: URL?
    var lastOpenDate: Date?

    // Every gallery has at least one page. A zero or negative count coming from unrecognized
    // markup, a legacy database row or a decoded payload would reach the reader, which builds
    // closed ranges from it, so it is normalized once here at the model boundary.
    private static func validated(pageCount: Int) -> Int {
        max(1, pageCount)
    }

    init(
        gid: String, token: String, title: String, rating: Float, tags: [GalleryTag],
        category: Category, uploader: String? = nil, pageCount: Int, postedDate: Date,
        coverURL: URL?, galleryURL: URL?, lastOpenDate: Date? = nil
    ) {
        self.gid = gid
        self.token = token
        self.title = title
        self.rating = rating
        self.tags = tags
        self.category = category
        self.uploader = uploader
        self.pageCount = Self.validated(pageCount: pageCount)
        self.postedDate = postedDate
        self.coverURL = coverURL
        self.galleryURL = galleryURL
        self.lastOpenDate = lastOpenDate
    }

    private enum CodingKeys: String, CodingKey {
        case gid, token, title, rating, tags, category, uploader
        case pageCount, postedDate, coverURL, galleryURL, lastOpenDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gid = try container.decode(String.self, forKey: .gid)
        token = try container.decode(String.self, forKey: .token)
        title = try container.decode(String.self, forKey: .title)
        rating = try container.decode(Float.self, forKey: .rating)
        tags = try container.decode([GalleryTag].self, forKey: .tags)
        category = try container.decode(Category.self, forKey: .category)
        uploader = try container.decodeIfPresent(String.self, forKey: .uploader)
        let decodedPageCount = try container.decode(Int.self, forKey: .pageCount)
        pageCount = Self.validated(pageCount: decodedPageCount)
        postedDate = try container.decode(Date.self, forKey: .postedDate)
        coverURL = try container.decodeIfPresent(URL.self, forKey: .coverURL)
        galleryURL = try container.decodeIfPresent(URL.self, forKey: .galleryURL)
        lastOpenDate = try container.decodeIfPresent(Date.self, forKey: .lastOpenDate)
    }
}

extension Gallery: DateFormattable, CustomStringConvertible {
    var description: String {
        "Gallery(\(gid))"
    }

    var filledCount: Int { Int(rating) }
    var halfFilledCount: Int { Int(rating - 0.5) == filledCount ? 1 : 0 }
    var notFilledCount: Int { 5 - filledCount - halfFilledCount }

    var color: Color {
        category.color
    }
    var originalDate: Date {
        postedDate
    }
}
