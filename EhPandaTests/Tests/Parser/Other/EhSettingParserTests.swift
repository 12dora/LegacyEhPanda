//
//  EhSettingParserTests.swift
//  EhPandaTests
//
//  Created by 荒木辰造 on R 4/02/15.
//

import Kanna
import XCTest
@testable import EhPanda

class EhSettingParserTests: XCTestCase, TestHelper {
    func testExample() throws {
        let document = try htmlDocument(filename: .ehSetting)
        let ehSetting = try Parser.parseEhSetting(doc: document)
        testEhProfiles(ehSetting.ehProfiles)
        testCapability(ehSetting: ehSetting)
        testRemainingStuff(ehSetting: ehSetting)
    }

    func testMissingThumbnailSelectorDefaultsToEnabled() throws {
        guard let url = Bundle(for: Self.self).url(forResource: HTMLFilename.ehSetting.rawValue, withExtension: "html")
        else { throw TestError.htmlDocumentNotFound(.ehSetting) }
        let html = try String(contentsOf: url).replacingOccurrences(
            of: #"<input[^>]*name="xn_0"[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        let document = try Kanna.HTML(html: html, encoding: .utf8)

        let ehSetting = try Parser.parseEhSetting(doc: document)

        XCTAssertTrue(ehSetting.enableGalleryThumbnailSelector)
    }

    func testEhProfiles(_ profiles: [EhProfile]) {
        XCTAssertEqual(profiles.count, 3)
        
        let ehProfile1 = profiles[0]
        XCTAssertEqual(ehProfile1.value, 1)
        XCTAssertEqual(ehProfile1.name, "Default Profile")
        XCTAssertEqual(ehProfile1.isSelected, true)
        XCTAssertEqual(ehProfile1.isDefault, true)

        let ehProfile2 = profiles[1]
        XCTAssertEqual(ehProfile2.value, 2)
        XCTAssertEqual(ehProfile2.name, "EhPanda")
        XCTAssertEqual(ehProfile2.isSelected, false)
        XCTAssertEqual(ehProfile2.isDefault, false)
        XCTAssertTrue(EhSetting.verifyEhPandaProfileName(with: ehProfile2.name))
    }

    func testCapability(ehSetting: EhSetting) {
        XCTAssertEqual(ehSetting.capableLoadThroughHathSetting, .legacyNo)
        XCTAssertEqual(ehSetting.capableLoadThroughHathSettings, EhSetting.LoadThroughHathSetting.allCases)

        XCTAssertEqual(ehSetting.capableImageResolution, .x2400)
        // .x980 is deprecated / removed from site; never offer it in the picker.
        XCTAssertEqual(
            ehSetting.capableImageResolutions,
            EhSetting.ImageResolution.allCases.filter { $0 != .x980 }
        )
        XCTAssertFalse(ehSetting.capableImageResolutions.contains(.x980))

        XCTAssertEqual(ehSetting.capableSearchResultCount, .oneHundred)
        XCTAssertEqual(ehSetting.capableSearchResultCounts, [.twentyFive, .fifty, .oneHundred])

        XCTAssertEqual(ehSetting.capableThumbnailConfigSizes, [.auto, .small, .normal])

        XCTAssertEqual(ehSetting.capableThumbnailConfigRowCount, .forty)
        XCTAssertEqual(ehSetting.capableThumbnailConfigRowCounts, EhSetting.ThumbnailRowCount.allCases)
    }

    func testRemainingStuff(ehSetting: EhSetting) {
        XCTAssertEqual(ehSetting.loadThroughHathSetting, .anyClient)
        XCTAssertEqual(ehSetting.browsingCountry, .autoDetect)
        XCTAssertEqual(ehSetting.literalBrowsingCountry, "Japan")
        XCTAssertEqual(ehSetting.imageResolution, .auto)
        XCTAssertEqual(ehSetting.imageSizeWidth, 0)
        XCTAssertEqual(ehSetting.imageSizeHeight, 0)
        XCTAssertEqual(ehSetting.galleryName, .japanese)
        XCTAssertEqual(ehSetting.archiverBehavior, .manualSelectManualStart)
        XCTAssertEqual(ehSetting.displayMode, .compact)
        XCTAssertEqual(ehSetting.showSearchRangeIndicator, true)
        XCTAssertEqual(ehSetting.enableGalleryThumbnailSelector, true)
        XCTAssertEqual(ehSetting.disabledCategories, .init(repeating: false, count: 10))
        XCTAssertEqual(ehSetting.favoriteCategories, [
            "Favorites 0", "Favorites 1", "Favorites 2", "Favorites 3", "Favorites 4",
            "Favorites 5", "Favorites 6", "Favorites 7", "Favorites 8", "Favorites 9"
        ])
        XCTAssertEqual(ehSetting.favoritesSortOrder, .favoritedTime)
        XCTAssertEqual(ehSetting.ratingsColor, "")
        XCTAssertEqual(ehSetting.tagFilteringThreshold, 0)
        XCTAssertEqual(ehSetting.tagWatchingThreshold, 0)
        XCTAssertEqual(ehSetting.showFilteredRemovalCount, true)
        XCTAssertEqual(ehSetting.excludedLanguages, .init(repeating: false, count: 50))
        XCTAssertEqual(ehSetting.excludedUploaders, "")
        XCTAssertEqual(ehSetting.searchResultCount, .oneHundred)
        XCTAssertEqual(ehSetting.thumbnailLoadTiming, .onMouseOver)
        XCTAssertEqual(ehSetting.thumbnailConfigSize, .auto)
        XCTAssertEqual(ehSetting.thumbnailConfigRows, .four)
        XCTAssertEqual(ehSetting.coverScaleFactor, 100)
        XCTAssertEqual(ehSetting.viewportVirtualWidth, 0)
        XCTAssertEqual(ehSetting.commentsSortOrder, .oldest)
        XCTAssertEqual(ehSetting.commentVotesShowTiming, .onHoverOrClick)
        XCTAssertEqual(ehSetting.tagsSortOrder, .alphabetical)
        XCTAssertEqual(ehSetting.galleryPageNumbering, .none)
        XCTAssertEqual(ehSetting.useOriginalImages, false)
        XCTAssertEqual(ehSetting.useMultiplePageViewer, true)
        XCTAssertEqual(ehSetting.multiplePageViewerStyle, .alignLeftScaleIfOverWidth)
        XCTAssertEqual(ehSetting.multiplePageViewerShowThumbnailPane, true)
    }
}
