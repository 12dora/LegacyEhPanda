//
//  ListParserTests.swift
//  EhPandaTests
//
//  Created by 荒木辰造 on R 4/02/11.
//

import Kanna
import XCTest
@testable import EhPanda

class ListParserTests: XCTestCase, TestHelper {
    // MARK: - Shape

    func testExample() throws {
        let tuples: [(ListParserTestType, HTMLDocument)] = try ListParserTestType.allCases.compactMap { type in
            (type, try htmlDocument(filename: type.filename))
        }
        XCTAssertEqual(tuples.count, ListParserTestType.allCases.count)

        try tuples.forEach { type, document in
            let galleries = try Parser.parseGalleries(doc: document)
            let uploaders = galleries.compactMap(\.uploader).filter(\.notEmpty)
            XCTAssertEqual(galleries.count, type.assertCount, .init(describing: type))
            if type.hasUploader {
                XCTAssertEqual(uploaders.count, type.assertCount, .init(describing: type))
            }
        }
    }

    // MARK: - Identity and page mapping

    // Counts alone cannot catch a row-to-gallery mapping regression: every row resolving to the
    // same gallery, or rows shifted by one, still produces the expected count. Compare the parsed
    // identities against the gallery links that literally appear in each fixture instead.
    func testEveryFixtureKeepsRowIdentityAndOrder() throws {
        for type in ListParserTestType.allCases {
            let context = String(describing: type)
            let document = try htmlDocument(filename: type.filename)
            let galleries = try Parser.parseGalleries(doc: document)
            let expectedURLStrings = try fixtureGalleryURLStrings(filename: type.filename)

            XCTAssertEqual(expectedURLStrings.count, type.assertCount, context)
            let parsedURLStrings = galleries.compactMap { $0.galleryURL?.absoluteString }
            XCTAssertEqual(parsedURLStrings.count, galleries.count, context)
            XCTAssertEqual(parsedURLStrings, expectedURLStrings, context)

            let expectedIdentifiers = expectedURLStrings.map { urlString -> String in
                let components = urlString.split(separator: "/")
                return "\(components[components.count - 2])/\(components[components.count - 1])"
            }
            XCTAssertEqual(galleries.map { "\($0.gid)/\($0.token)" }, expectedIdentifiers, context)
            XCTAssertEqual(Set(galleries.map(\.gid)).count, galleries.count, context)

            for gallery in galleries {
                XCTAssertFalse(gallery.gid.isEmpty, context)
                XCTAssertFalse(gallery.token.isEmpty, context)
                XCTAssertFalse(gallery.title.isEmpty, context)
                XCTAssertGreaterThan(gallery.pageCount, 0, context)
                XCTAssertEqual(gallery.coverURL?.host, "ehgt.org", context)
                XCTAssertTrue((0.0...5.0).contains(gallery.rating), context)
                // Thumbnail mode has no uploader column at all, so the parser must not invent one.
                if type.filename.rawValue.hasSuffix("ThumbnailList") {
                    XCTAssertNil(gallery.uploader, context)
                }
            }
        }
    }

    // MARK: - Sentinel values

    func testFrontPageSentinelValues() throws {
        let frontPageTypes: [ListParserTestType] = [
            .frontPageMinimalList, .frontPageMinimalPlusList,
            .frontPageCompactList, .frontPageExtendedList, .frontPageThumbnailList
        ]
        let expectedPostedDate = try Self.publishedDate("2023-09-08 00:35")

        for type in frontPageTypes {
            let context = String(describing: type)
            let galleries = try Parser.parseGalleries(doc: htmlDocument(filename: type.filename))
            let first = try XCTUnwrap(galleries.first, context)

            XCTAssertEqual(first.gid, "2668617", context)
            XCTAssertEqual(first.token, "2f0bbb38f9", context)
            XCTAssertEqual(first.title, "[ROM宅 (ROM)] せめぱん3 (ドラゴンボールGT) [DL版]", context)
            XCTAssertEqual(first.category, .doujinshi, context)
            XCTAssertEqual(first.pageCount, 48, context)
            XCTAssertEqual(first.rating, 0.0, context)
            XCTAssertEqual(
                first.coverURL?.absoluteString,
                "https://ehgt.org/78/50/7850409de81adcf7a0e7086bcf009f95794089fa-483855-661-920-jpg_250.jpg",
                context
            )
            XCTAssertEqual(
                first.galleryURL?.absoluteString,
                "https://e-hentai.org/g/2668617/2f0bbb38f9/",
                context
            )
            XCTAssertEqual(first.postedDate, expectedPostedDate, context)
            if type.hasUploader {
                XCTAssertEqual(first.uploader, "hobohobo", context)
            } else {
                XCTAssertNil(first.uploader, context)
            }

            XCTAssertEqual(galleries.last?.gid, "2668517", context)
            XCTAssertEqual(galleries.last?.token, "8720fd620e", context)
        }
    }

    func testToplistsSentinelValues() throws {
        let galleries = try Parser.parseGalleries(doc: htmlDocument(filename: .toplistsCompactList))
        XCTAssertEqual(galleries.count, 50)

        let first = try XCTUnwrap(galleries.first)
        XCTAssertEqual(first.gid, "596447")
        XCTAssertEqual(first.token, "3894f02c20")
        XCTAssertEqual(first.title, "[LemonFont] Shapeshifter Part 1-3")
        XCTAssertEqual(first.category, .western)
        XCTAssertEqual(first.uploader, "Project_Demise")
        XCTAssertEqual(first.pageCount, 345)
        XCTAssertEqual(first.rating, 5.0)
        let expectedPostedDate = try Self.publishedDate("2013-05-27 07:47")
        XCTAssertEqual(first.postedDate, expectedPostedDate)
        XCTAssertEqual(
            first.coverURL?.absoluteString,
            "https://ehgt.org/2b/ae/2bae2cd65255d1ac661649a91a422317ac51925f-252950-1157-722-png_250.jpg"
        )

        // Compact mode carries inline tags; they must survive namespace grouping.
        let language = try XCTUnwrap(first.tags.first { $0.rawNamespace == "language" })
        XCTAssertEqual(language.contents.map(\.text), ["english"])
        let female = try XCTUnwrap(first.tags.first { $0.rawNamespace == "female" })
        XCTAssertTrue(female.contents.map(\.text).contains("big breasts"))
        XCTAssertEqual(galleries.last?.gid, "594960")
    }

    // Watched fixtures were captured with a redacted first gallery id; it is still a real row and
    // must not be silently dropped.
    func testWatchedRedactedRowIsStillParsed() throws {
        let galleries = try Parser.parseGalleries(doc: htmlDocument(filename: .watchedMinimalList))
        let first = try XCTUnwrap(galleries.first)
        XCTAssertEqual(first.gid, "0000000")
        XCTAssertEqual(first.token, "000000000")
        XCTAssertEqual(first.title, "[SweetEdda (ろき)] SweetEdda vol.11 悪の組織編2 細胞怪人リクオール [英訳]")
        XCTAssertEqual(first.uploader, "TGE7")
        XCTAssertEqual(first.pageCount, 55)
        XCTAssertEqual(first.rating, 4.5)
    }

    // MARK: - Malformed row policy

    // A row whose title link cannot be resolved must be skipped without shifting, duplicating or
    // dropping any other row.
    func testRowWithUnparsableTitleIsSkippedWithoutShiftingOtherRows() throws {
        var html = try htmlString(filename: .frontPageMinimalList)
        let brokenRange = try XCTUnwrap(html.range(of: "class=\"glink\""))
        html.replaceSubrange(brokenRange, with: "class=\"gbroken\"")

        let galleries = try Parser.parseGalleries(doc: Kanna.HTML(html: html, encoding: .utf8))
        let expectedURLStrings = try fixtureGalleryURLStrings(filename: .frontPageMinimalList)

        XCTAssertEqual(galleries.count, expectedURLStrings.count - 1)
        XCTAssertEqual(
            galleries.compactMap { $0.galleryURL?.absoluteString },
            Array(expectedURLStrings.dropFirst())
        )
        XCTAssertEqual(galleries.first?.gid, "2668616")
    }

    func testUnrecognisedListDocumentThrowsParseFailed() throws {
        let document = try Kanna.HTML(html: "<html><body><main>maintenance</main></body></html>", encoding: .utf8)

        XCTAssertThrowsError(try Parser.parseGalleries(doc: document)) { error in
            XCTAssertEqual(error as? AppError, .parseFailed)
        }
    }

    func testRecognisedNoResultsListReturnsEmptyGalleries() throws {
        let html = """
        <html>
          <body>
            <div id="dms">
              <select onchange="inline_set=dm_">
                <option selected="selected">Compact</option>
              </select>
            </div>
            <p>No hits found</p>
          </body>
        </html>
        """
        let document = try Kanna.HTML(html: html, encoding: .utf8)

        XCTAssertEqual(try Parser.parseGalleries(doc: document), [])
    }

    // MARK: - Pagination

    func testDateSeekNavigation() throws {
        let frontpage = try htmlDocument(filename: .frontPageMinimalList)
        let frontpageNavigation = try XCTUnwrap(Parser.parsePageNum(doc: frontpage).dateSeekNavigation)
        XCTAssertNil(frontpageNavigation.newerURL)
        XCTAssertEqual(frontpageNavigation.olderURL?.host, "e-hentai.org")
        XCTAssertEqual(frontpageNavigation.olderURL?.query, "next=2668517")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let date = try XCTUnwrap(formatter.date(from: "2015-06-01"))
        let seekURL = try XCTUnwrap(frontpageNavigation.seekURL(date: date, direction: .older))
        XCTAssertTrue(seekURL.absoluteString.contains("next=2668517"))
        XCTAssertTrue(seekURL.absoluteString.contains("seek=2015-06-01"))

        let popular = try htmlDocument(filename: .popularMinimalList)
        XCTAssertNil(Parser.parsePageNum(doc: popular).dateSeekNavigation)
    }

    // MARK: - Downloads

    func testGalleryDownloadManifestRoundTrip() throws {
        let original = GalleryDownload(
            gallery: .preview,
            detail: .preview,
            previewConfig: .normal(rows: 4),
            folderName: "Offline"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GalleryDownload.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.folderName, "Offline")
        XCTAssertEqual(decoded.completedCount, 0)
    }

    func testFixtureToDownloadManifestSmokePath() throws {
        let galleries = try Parser.parseGalleries(doc: htmlDocument(filename: .frontPageCompactList))
        let gallery = try XCTUnwrap(galleries.first)
        let (detail, state) = try Parser.parseGalleryDetail(
            doc: htmlDocument(filename: .galleryDetail), gid: gallery.gid
        )
        let previewConfig = try XCTUnwrap(state.previewConfig)
        let manifest = GalleryDownload(
            gallery: gallery, detail: detail, previewConfig: previewConfig, folderName: "Smoke"
        )

        let decoded = try JSONDecoder().decode(
            GalleryDownload.self, from: try JSONEncoder().encode(manifest)
        )
        XCTAssertEqual(decoded.gallery.gid, gallery.gid)
        XCTAssertEqual(decoded.detail.gid, gallery.gid)
        XCTAssertEqual(decoded.previewConfig, previewConfig)
        XCTAssertEqual(decoded.fileNames, [:])
        XCTAssertFalse(decoded.canReadOffline)
    }

    // MARK: - Reader cache keys

    func testReaderImageCacheKeyIgnoresTemporaryHostAndQuery() throws {
        let first = try XCTUnwrap(URL(string: "https://a.hath.network/h/hash/file.jpg?dl=1"))
        let second = try XCTUnwrap(URL(string: "https://b.hath.network/h/hash/file.jpg?download=1"))
        // Comparing the two optionals directly would also pass if both regressed to nil.
        let firstKey = try XCTUnwrap(first.stableImageCacheKey)
        let secondKey = try XCTUnwrap(second.stableImageCacheKey)
        XCTAssertEqual(firstKey, "reader::h/hash/file.jpg")
        XCTAssertEqual(secondKey, "reader::h/hash/file.jpg")
    }

    func testReaderImageCacheKeyIgnoresHAtHKeystamp() throws {
        let first = try XCTUnwrap(URL(string:
            "https://a.hath.network/h/contenthash/keystamp=abc;fileindex=7;xres=org/page.webp"
        ))
        let second = try XCTUnwrap(URL(string:
            "https://b.hath.network/h/contenthash/keystamp=xyz;fileindex=7;xres=org/page.webp"
        ))
        let firstKey = try XCTUnwrap(first.stableImageCacheKey)
        let secondKey = try XCTUnwrap(second.stableImageCacheKey)
        XCTAssertEqual(firstKey, "reader::h/contenthash/fileindex=7;xres=org/page.webp")
        XCTAssertEqual(secondKey, firstKey)
    }

    func testReaderImageCacheKeyKeepsOrdinaryHostIdentity() throws {
        let first = try XCTUnwrap(URL(string: "https://a.example/images/page.jpg"))
        let second = try XCTUnwrap(URL(string: "https://b.example/images/page.jpg"))
        XCTAssertEqual(try XCTUnwrap(first.stableImageCacheKey), "reader::a.example/images/page.jpg")
        XCTAssertEqual(try XCTUnwrap(second.stableImageCacheKey), "reader::b.example/images/page.jpg")
    }

    func testReaderImageAspectRatioUsesHAtHPathDimensions() throws {
        let url = try XCTUnwrap(URL(string:
            "https://a.hath.network/h/hash-311480-1280-1920-jpg/keystamp=abc;fileindex=7;xres=1280/page.jpg"
        ))
        XCTAssertEqual(try XCTUnwrap(url.readerImageAspectRatio), 2.0 / 3.0, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private static func publishedDate(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try XCTUnwrap(formatter.date(from: value))
    }
}
