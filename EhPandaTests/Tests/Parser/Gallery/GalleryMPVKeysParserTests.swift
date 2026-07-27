//
//  GalleryMPVKeysParserTests.swift
//  EhPandaTests
//
//  Created by 荒木辰造 on R 4/02/11.
//

import Kanna
import XCTest
@testable import EhPanda

class GalleryMPVKeysParserTests: XCTestCase, TestHelper {
    func testExample() throws {
        let document = try htmlDocument(filename: .galleryMPVKeys)
        let (mpvKey, mpvImageKeys) = try Parser.parseMPVKeys(doc: document)
        XCTAssertEqual(mpvKey, "00000000000")
        XCTAssertEqual(mpvImageKeys.count, 194)
    }

    // The image-key dictionary is a page-number → key mapping. A count-only assertion cannot tell
    // a correct mapping from an off-by-one or reversed one, which would silently serve the wrong
    // page for every request.
    func testImageKeysAreOneBasedAndMapEveryPage() throws {
        let document = try htmlDocument(filename: .galleryMPVKeys)
        let (_, mpvImageKeys) = try Parser.parseMPVKeys(doc: document)

        XCTAssertEqual(Set(mpvImageKeys.keys), Set(1...194))
        XCTAssertEqual(mpvImageKeys[1], "9d71dd93bb")
        XCTAssertEqual(mpvImageKeys[2], "6f2c341604")
        XCTAssertEqual(mpvImageKeys[193], "71d9243acf")
        XCTAssertEqual(mpvImageKeys[194], "fa89533b1e")
        XCTAssertTrue(mpvImageKeys.values.allSatisfy { $0.count == 10 })
        XCTAssertEqual(Set(mpvImageKeys.values).count, mpvImageKeys.count)
    }

    // A page without an mpvkey/imagelist script must fail, not return an empty-but-successful map.
    func testDocumentWithoutMPVScriptThrows() throws {
        let document = try Kanna.HTML(
            html: "<html><body><script type=\"text/javascript\">var gid=1;</script></body></html>",
            encoding: .utf8
        )
        XCTAssertThrowsError(try Parser.parseMPVKeys(doc: document)) { error in
            XCTAssertEqual(error as? AppError, .parseFailed)
        }
    }
}
