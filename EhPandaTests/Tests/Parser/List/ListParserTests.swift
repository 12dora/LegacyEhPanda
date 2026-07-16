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
}
