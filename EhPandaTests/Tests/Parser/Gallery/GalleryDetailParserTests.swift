//
//  GalleryDetailParserTests.swift
//  EhPandaTests
//
//  Created by 荒木辰造 on R 4/02/11.
//

import Kanna
import XCTest
@testable import EhPanda

class GalleryDetailParserTests: XCTestCase, TestHelper {
    func testExample() throws {
        let document = try htmlDocument(filename: .galleryDetail)
        let (detail, state) = try Parser.parseGalleryDetail(doc: document, gid: "2725078")
        XCTAssertEqual(detail.gid, "2725078")
        XCTAssertEqual(detail.title, "[Artist] mks")
        XCTAssertEqual(detail.jpnTitle, "[アーティスト] mks")
        XCTAssertFalse(detail.isFavorited)
        XCTAssertEqual(detail.visibility, .yes)
        XCTAssertEqual(detail.rating, 4.5)
        XCTAssertEqual(detail.userRating, 0)
        XCTAssertEqual(detail.ratingCount, 110)
        XCTAssertEqual(detail.category, .nonH)
        XCTAssertEqual(detail.language, .japanese)
        XCTAssertEqual(detail.uploader, "Pokom")
        XCTAssertEqual(detail.coverURL?.absoluteString, "https://ehgt.org/03/08/0308268821e99628b05a19fa54e2fc0fa9ad8f4b-1705560-1012-1470-png_250.jpg")
        XCTAssertEqual(detail.archiveURL?.absoluteString, "https://e-hentai.org/archiver.php?gid=3103480&token=0000000000")
        XCTAssertEqual(detail.parentURL?.absoluteString, "https://e-hentai.org/g/2930572/daf4b9880d/")
        XCTAssertEqual(detail.favoritedCount, 591)
        XCTAssertEqual(detail.pageCount, 156)
        XCTAssertEqual(detail.sizeCount, 314.3)
        XCTAssertEqual(detail.sizeType, "MiB")
        XCTAssertEqual(detail.torrentCount, 1)
        XCTAssertEqual(state.tags.count, 1)
        XCTAssertEqual(state.previewURLs.count, 40)
        XCTAssertEqual(state.previewConfig, .normal(rows: 4))
        XCTAssertEqual(state.comments.count, 10)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expectedPostedDate = try XCTUnwrap(formatter.date(from: "2024-10-27 06:20"))
        XCTAssertEqual(detail.postedDate, expectedPostedDate)
    }

    // The tag panel used to be asserted only by count, so a namespace/content mix-up stayed green.
    func testTagsCarryNamespaceAndContent() throws {
        let document = try htmlDocument(filename: .galleryDetail)
        let (_, state) = try Parser.parseGalleryDetail(doc: document, gid: "2725078")

        let tag = try XCTUnwrap(state.tags.first)
        XCTAssertEqual(tag.rawNamespace, "other")
        XCTAssertEqual(tag.namespace, .other)
        XCTAssertEqual(tag.contents.map(\.text), ["non-h imageset"])
        XCTAssertEqual(tag.contents.map(\.isVotedUp), [false])
        XCTAssertEqual(tag.contents.map(\.isVotedDown), [false])
    }

    // Preview page mapping is the part a same-count regression hides best: the dictionary can keep
    // 40 entries while every page points at the wrong sprite offset.
    func testPreviewURLsCoverEveryPageWithCorrectSpriteGeometry() throws {
        let document = try htmlDocument(filename: .galleryDetail)
        let (_, state) = try Parser.parseGalleryDetail(doc: document, gid: "2725078")

        XCTAssertEqual(Set(state.previewURLs.keys), Set(1...40))

        func components(_ index: Int) throws -> URLComponents {
            let url = try XCTUnwrap(state.previewURLs[index])
            return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        }
        func queryValue(_ components: URLComponents, _ name: String) throws -> String {
            try XCTUnwrap(components.queryItems?.first { $0.name == name }?.value)
        }

        let first = try components(1)
        XCTAssertEqual(first.host, "sunvxqrqcj.hath.network")
        XCTAssertEqual(first.path, "/cm/azlrrht402sk9g3kpk/3103480-0.jpg")
        XCTAssertEqual(try queryValue(first, "ehpandaWidth"), "100")
        XCTAssertEqual(try queryValue(first, "ehpandaHeight"), "145")
        XCTAssertEqual(try queryValue(first, "ehpandaOffset"), "0")

        let second = try components(2)
        XCTAssertEqual(second.path, "/cm/azlrrht402sk9g3kpk/3103480-0.jpg")
        XCTAssertEqual(try queryValue(second, "ehpandaOffset"), "100")

        // Page 40 lives on the second sprite sheet and is the short trailing tile.
        let last = try components(40)
        XCTAssertEqual(last.path, "/cm/azlrrht402sk9g3kpk/3103480-1.jpg")
        XCTAssertEqual(try queryValue(last, "ehpandaWidth"), "100")
        XCTAssertEqual(try queryValue(last, "ehpandaHeight"), "51")
        XCTAssertEqual(try queryValue(last, "ehpandaOffset"), "1900")
    }

    func testThumbnailURLsMapEveryPageToItsMPVAnchor() throws {
        let document = try htmlDocument(filename: .galleryDetail)
        let thumbnailURLs = try Parser.parseThumbnailURLs(doc: document)

        XCTAssertEqual(Set(thumbnailURLs.keys), Set(1...40))
        XCTAssertEqual(
            thumbnailURLs[1]?.absoluteString,
            "https://e-hentai.org/mpv/3103480/0000000000/#page1"
        )
        XCTAssertEqual(
            thumbnailURLs[40]?.absoluteString,
            "https://e-hentai.org/mpv/3103480/0000000000/#page40"
        )
    }

    // Comments were asserted by count only, so author/score/body corruption stayed green.
    func testCommentsPreserveIdentityOrderAndContent() throws {
        let document = try htmlDocument(filename: .galleryDetail)
        let (_, state) = try Parser.parseGalleryDetail(doc: document, gid: "2725078")
        let comments = state.comments

        XCTAssertEqual(
            comments.map(\.commentID),
            ["0", "5143504", "5322704", "5358306", "5429602",
             "5430274", "5799665", "5800244", "6265291", "6894060"]
        )
        XCTAssertEqual(
            comments.map { $0.author.trimmingCharacters(in: .whitespaces) },
            ["Pokom", "Roobubba", "囧斯诺", "siyuaner", "曾俊华",
             "ddddecade123", "Akrbear", "犯罪高手", "HQH1301376128", "黑锋血色"]
        )
        XCTAssertEqual(
            comments.map(\.score),
            [nil, "+113", "+5", "+27", "+19", "+9", "+7", "+12", "+21", "+7"]
        )

        // The uploader comment is not votable; every other comment is.
        XCTAssertFalse(comments[0].votable)
        XCTAssertTrue(comments.dropFirst().allSatisfy(\.votable))
        XCTAssertTrue(comments.allSatisfy { !$0.votedUp && !$0.votedDown })

        XCTAssertTrue(comments[0].plainTextContent.contains("https://www.pixiv.net/users/750220"))
        XCTAssertTrue(comments[0].plainTextContent.contains("https://mks.booth.pm/"))
        XCTAssertEqual(
            comments[1].plainTextContent,
            "Some gorgeous scenery there. Makes a refreshing change to see some good, clean stuff."
        )
        XCTAssertEqual(comments[9].plainTextContent, "赛博亚历山大图书馆")

        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMMM yyyy, HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let firstCommentDate = try XCTUnwrap(formatter.date(from: "27 October 2024, 06:20"))
        let secondCommentDate = try XCTUnwrap(formatter.date(from: "28 August 2022, 07:32"))
        XCTAssertEqual(comments[0].commentDate, firstCommentDate)
        XCTAssertEqual(comments[1].commentDate, secondCommentDate)
    }

    // A gallery page whose detail panel cannot be recognised must be reported as a parse failure,
    // never as an empty-but-successful gallery.
    func testUnrecognisedDocumentThrowsInsteadOfReturningEmptyDetail() throws {
        let document = try Kanna.HTML(html: "<html><body><div id=\"gd3\"></div></body></html>", encoding: .utf8)
        XCTAssertThrowsError(try Parser.parseGalleryDetail(doc: document, gid: "2725078")) { error in
            XCTAssertEqual(error as? AppError, .parseFailed)
        }
    }
}
