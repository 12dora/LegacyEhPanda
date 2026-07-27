//
//  Setting.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 3/01/09.
//

import SwiftUI
import Foundation
import ComposableArchitecture

struct Setting: Codable, Equatable {
    // Account
    var galleryHost: GalleryHost = .ehentai
    var showsNewDawnGreeting = false

    // General
    var enablesTagsExtension = false {
        didSet {
            if !enablesTagsExtension {
                translatesTags = false
                showsTagsSearchSuggestion = false
                showsImagesInTags = false
            }
        }
    }
    var translatesTags = false
    var showsTagsSearchSuggestion = false
    var showsImagesInTags = false
    // `redirectsLinksToSelectedHost` used to live here. It was never read outside this
    // model and its own toggle, so the control promised a host rewrite that no lookup,
    // fetch or cache path ever performed. Removed rather than left as a lying switch.
    var detectsLinksFromClipboard = false
    var backgroundBlurRadius: Double = 10
    var autoLockPolicy: AutoLockPolicy = .never

    // Appearance
    var listDisplayMode: ListDisplayMode = DeviceUtil.isPadWidth ? .thumbnail : .detail
    var preferredColorScheme = PreferredColorScheme.automatic
    // Stored as the project's own color representation so this blob no longer depends on a
    // retroactive `Codable` conformance on the imported `Color`. `CodingKeys` maps it back to
    // the `accentColor` key and the encoded shape is unchanged, so persisted settings still
    // decode. `accentColor` below stays a read/write `Color` for the views and their bindings.
    var accentColorStorage: CodableColor = .blue
    var appIconType: AppIconType = .default
    var showsTagsInList = false
    var listTagsNumberMaximum = 0
    var displaysJapaneseTitle = true

    // Reading
    var readingDirection: ReadingDirection = .vertical
    var prefetchLimit = 10
    var enablesLandscape = false
    var enablesDualPageMode = false
    var exceptCover = false
    var contentDividerHeight: Double = 0
    var maximumScaleFactor: Double = 3
    var doubleTapScaleFactor: Double = 2

    // Laboratory
    var bypassesSNIFiltering = false

    var accentColor: Color {
        get { accentColorStorage.color }
        set { accentColorStorage = CodableColor(newValue) ?? accentColorStorage }
    }

    // Declared explicitly only so `accentColorStorage` keeps writing and reading the historical
    // `accentColor` key. Every other case matches its property name, exactly as the synthesized
    // keys did. A stored property missing from this list would silently stop being encoded.
    enum CodingKeys: String, CodingKey {
        case galleryHost
        case showsNewDawnGreeting
        case enablesTagsExtension
        case translatesTags
        case showsTagsSearchSuggestion
        case showsImagesInTags
        case detectsLinksFromClipboard
        case backgroundBlurRadius
        case autoLockPolicy
        case listDisplayMode
        case preferredColorScheme
        case accentColorStorage = "accentColor"
        case appIconType
        case showsTagsInList
        case listTagsNumberMaximum
        case displaysJapaneseTitle
        case readingDirection
        case prefetchLimit
        case enablesLandscape
        case enablesDualPageMode
        case exceptCover
        case contentDividerHeight
        case maximumScaleFactor
        case doubleTapScaleFactor
        case bypassesSNIFiltering
    }
}

enum GalleryHost: String, Codable, Equatable, CaseIterable, Identifiable {
    case ehentai = "E-Hentai"
    case exhentai = "ExHentai"

    var id: Int { hashValue }
    var url: URL {
        switch self {
        case .ehentai:
            return Defaults.URL.ehentai
        case .exhentai:
            return Defaults.URL.exhentai
        }
    }
    var cookieURLs: [URL] {
        switch self {
        case .ehentai:
            return [Defaults.URL.ehentai]

        case .exhentai:
            return [Defaults.URL.exhentai, Defaults.URL.sexhentai]
        }
    }
    var abbr: String {
        switch self {
        case .ehentai:
            return "eh"
        case .exhentai:
            return "ex"
        }
    }
}

enum AutoLockPolicy: Int, Codable, CaseIterable, Identifiable {
    var id: Int { rawValue }

    case never = -1
    case instantly = 0
    case sec15 = 15
    case min1 = 60
    case min5 = 300
    case min10 = 600
    case min30 = 1800
}

extension AutoLockPolicy {
    var value: String {
        switch self {
        case .never:
            return L10n.Localizable.Enum.AutoLockPolicy.Value.never
        case .instantly:
            return L10n.Localizable.Enum.AutoLockPolicy.Value.instantly
        case .sec15:
            return L10n.Localizable.Common.Value.seconds("\(rawValue)")
        case .min1:
            return L10n.Localizable.Common.Value.minute("\(rawValue / 60)")
        case .min5, .min10, .min30:
            return L10n.Localizable.Common.Value.minutes("\(rawValue / 60)")
        }
    }
}

enum PreferredColorScheme: Int, Codable, CaseIterable, Identifiable {
    var id: Int { rawValue }

    case automatic
    case light
    case dark
}
extension PreferredColorScheme {
    var value: String {
        switch self {
        case .automatic:
            return L10n.Localizable.Enum.PreferredColorScheme.Value.automatic
        case .light:
            return L10n.Localizable.Enum.PreferredColorScheme.Value.light
        case .dark:
            return L10n.Localizable.Enum.PreferredColorScheme.Value.dark
        }
    }
    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .automatic:
            return .unspecified
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum ReadingDirection: Int, Codable, CaseIterable, Identifiable {
    var id: Int { rawValue }

    case vertical
    case rightToLeft
    case leftToRight
}
extension ReadingDirection {
    var value: String {
        switch self {
        case .vertical:
            return L10n.Localizable.Enum.ReadingDirection.Value.vertical
        case .rightToLeft:
            return L10n.Localizable.Enum.ReadingDirection.Value.rightToLeft
        case .leftToRight:
            return L10n.Localizable.Enum.ReadingDirection.Value.leftToRight
        }
    }
}

enum ListDisplayMode: Int, Codable, CaseIterable, Identifiable {
    var id: Int { rawValue }

    case detail
    case thumbnail
}
extension ListDisplayMode {
    var value: String {
        switch self {
        case .detail:
            return L10n.Localizable.Enum.ListDisplayMode.Value.detail
        case .thumbnail:
            return L10n.Localizable.Enum.ListDisplayMode.Value.thumbnail
        }
    }
}

// swiftlint:disable line_length
// MARK: Manually decode
extension Setting {
    init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        // Account
        galleryHost = (try? container?.decodeIfPresent(GalleryHost.self, forKey: .galleryHost)) ?? .ehentai
        showsNewDawnGreeting = (try? container?.decodeIfPresent(Bool.self, forKey: .showsNewDawnGreeting)) ?? false
        // General
        enablesTagsExtension = (try? container?.decodeIfPresent(Bool.self, forKey: .enablesTagsExtension)) ?? false
        translatesTags = (try? container?.decodeIfPresent(Bool.self, forKey: .translatesTags)) ?? false
        showsTagsSearchSuggestion = (try? container?.decodeIfPresent(Bool.self, forKey: .showsTagsSearchSuggestion)) ?? false
        showsImagesInTags = (try? container?.decodeIfPresent(Bool.self, forKey: .showsImagesInTags)) ?? false
        detectsLinksFromClipboard = (try? container?.decodeIfPresent(Bool.self, forKey: .detectsLinksFromClipboard)) ?? false
        backgroundBlurRadius = (try? container?.decodeIfPresent(Double.self, forKey: .backgroundBlurRadius)) ?? 10
        autoLockPolicy = (try? container?.decodeIfPresent(AutoLockPolicy.self, forKey: .autoLockPolicy)) ?? .never
        // Appearance
        listDisplayMode = (try? container?.decodeIfPresent(ListDisplayMode.self, forKey: .listDisplayMode)) ?? (DeviceUtil.isPadWidth ? .thumbnail : .detail)
        preferredColorScheme = (try? container?.decodeIfPresent(PreferredColorScheme.self, forKey: .preferredColorScheme)) ?? .automatic
        accentColorStorage = (try? container?.decodeIfPresent(CodableColor.self, forKey: .accentColorStorage)) ?? .blue
        appIconType = (try? container?.decodeIfPresent(AppIconType.self, forKey: .appIconType)) ?? .default
        showsTagsInList = (try? container?.decodeIfPresent(Bool.self, forKey: .showsTagsInList)) ?? false
        listTagsNumberMaximum = (try? container?.decodeIfPresent(Int.self, forKey: .listTagsNumberMaximum)) ?? 0
        displaysJapaneseTitle = (try? container?.decodeIfPresent(Bool.self, forKey: .displaysJapaneseTitle)) ?? true
        // Reading
        readingDirection = (try? container?.decodeIfPresent(ReadingDirection.self, forKey: .readingDirection)) ?? .vertical
        prefetchLimit = (try? container?.decodeIfPresent(Int.self, forKey: .prefetchLimit)) ?? 10
        enablesLandscape = (try? container?.decodeIfPresent(Bool.self, forKey: .enablesLandscape)) ?? false
        enablesDualPageMode = (try? container?.decodeIfPresent(Bool.self, forKey: .enablesDualPageMode)) ?? false
        exceptCover = (try? container?.decodeIfPresent(Bool.self, forKey: .exceptCover)) ?? false
        contentDividerHeight = (try? container?.decodeIfPresent(Double.self, forKey: .contentDividerHeight)) ?? 0
        maximumScaleFactor = (try? container?.decodeIfPresent(Double.self, forKey: .maximumScaleFactor)) ?? 3
        doubleTapScaleFactor = (try? container?.decodeIfPresent(Double.self, forKey: .doubleTapScaleFactor)) ?? 2
        // Laboratory
        bypassesSNIFiltering = (try? container?.decodeIfPresent(Bool.self, forKey: .bypassesSNIFiltering)) ?? false
    }
}
// swiftlint:enable line_length
