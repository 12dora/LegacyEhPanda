//
//  TestHelper.swift
//  TestHelper
//
//  Created by 荒木辰造 on R 3/08/21.
//

import Kanna
import XCTest

protocol TestHelper {}

extension TestHelper where Self: XCTestCase {
    func fixtureURL(filename: HTMLFilename) throws -> URL {
        guard let url = Bundle(for: Self.self).url(forResource: filename.rawValue, withExtension: "html") else {
            throw TestError.htmlDocumentNotFound(filename)
        }
        return url
    }

    func htmlDocument(filename: HTMLFilename) throws -> HTMLDocument {
        try Kanna.HTML(url: fixtureURL(filename: filename), encoding: .utf8)
    }

    func htmlString(filename: HTMLFilename) throws -> String {
        try String(contentsOf: fixtureURL(filename: filename), encoding: .utf8)
    }

    /// Every `https://e-hentai.org/g/<gid>/<token>/` link in the raw fixture, in document order,
    /// with duplicates removed.
    ///
    /// This is an oracle derived from the fixture itself rather than from the parser, so a
    /// page-mapping regression (every row resolving to the same gallery, rows silently shifted,
    /// rows dropped) cannot stay green just because the row count happens to match.
    func fixtureGalleryURLStrings(filename: HTMLFilename) throws -> [String] {
        let html = try htmlString(filename: filename)
        let regex = try NSRegularExpression(pattern: "https://e-hentai\\.org/g/[0-9]+/[0-9a-f]+/")
        var seen = Set<String>()
        var ordered = [String]()
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let urlString = String(html[range])
            if seen.insert(urlString).inserted {
                ordered.append(urlString)
            }
        }
        return ordered
    }
}
