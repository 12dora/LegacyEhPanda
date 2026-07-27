//
//  URLClient.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 4/01/16.
//

import SwiftUI
import Dependencies

struct URLClient {
    let checkIfHandleable: (URL) -> Bool
    let checkIfMPVURL: (URL?) -> Bool
    let parseGalleryID: (URL) -> String
}

// MARK: Route
extension URLClient {
    /// The exact hosts whose links may enter the trusted in-app gallery flow.
    ///
    /// A substring test on the absolute string used to accept lookalikes such as
    /// `e-hentai.org.attacker.example`, which let foreign HTML reach the gallery flow and the cache.
    static let handleableHosts: Set<String> = ["e-hentai.org", "exhentai.org"]

    enum GalleryRouteKind: String {
        /// `/g/{gid}/{token}/`
        case gallery = "g"
        /// `/s/{pageToken}/{gid}-{page}`
        case page = "s"
    }

    struct GalleryRoute: Equatable {
        let kind: GalleryRouteKind
        let galleryID: String
        let token: String
        let pageIndex: Int?
    }

    /// Validates that `url` is an HTTPS gallery or page route on an allowed host, and splits it up.
    ///
    /// Returns `nil` for everything else, so that no call site has to subscript path components
    /// blindly: a host-only or otherwise unexpected URL used to trap instead of being rejected.
    static func parseGalleryRoute(_ url: URL) -> GalleryRoute? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              handleableHosts.contains(host)
        else { return nil }

        let pathComponents = url.pathComponents
        guard pathComponents.count >= 4,
              let kind = GalleryRouteKind(rawValue: pathComponents[1])
        else { return nil }
        let secondComponent = pathComponents[2]
        let thirdComponent = pathComponents[3]

        switch kind {
        case .gallery:
            guard isValidGalleryID(secondComponent), isValidToken(thirdComponent) else { return nil }
            return .init(kind: kind, galleryID: secondComponent, token: thirdComponent, pageIndex: nil)

        case .page:
            guard isValidToken(secondComponent),
                  let separator = thirdComponent.range(of: "-")
            else { return nil }
            let galleryID = String(thirdComponent[..<separator.lowerBound])
            guard isValidGalleryID(galleryID) else { return nil }
            return .init(
                kind: kind, galleryID: galleryID, token: secondComponent,
                pageIndex: Int(thirdComponent[separator.upperBound...])
            )
        }
    }

    /// The identifier of the comment a gallery link points at, taken from its fragment.
    static func parseCommentID(_ url: URL) -> String? {
        guard let fragment = url.fragment, fragment.hasPrefix("c") else { return nil }
        let identifier = String(fragment.dropFirst())
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return identifier
    }

    private static func isValidGalleryID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 32 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }
    private static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isASCII && ($0.isNumber || $0.isLetter) }
    }
}

extension URLClient {
    static let live: Self = .init(
        checkIfHandleable: { URLClient.parseGalleryRoute($0) != nil },
        checkIfMPVURL: { url in
            // A host-only URL has a single path component, so indexing blindly used to trap here.
            guard let url = url, let host = url.host, !host.isEmpty else { return false }
            return url.pathComponents.dropFirst().first == "mpv"
        },
        parseGalleryID: { URLClient.parseGalleryRoute($0)?.galleryID ?? .init() }
    )

    func resolveAppSchemeURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "ehpanda",
              let newURL = url.replaceScheme(to: "https")
        else { return url }
        return newURL
    }
    func analyzeURL(_ url: URL) -> (Bool, Int?, String?) {
        guard checkIfHandleable(url), let route = URLClient.parseGalleryRoute(url) else {
            return (false, nil, nil)
        }
        let commentID = URLClient.parseCommentID(url)
        let isGalleryImageURL = route.kind == .page && commentID == nil
        return (isGalleryImageURL, route.pageIndex, commentID)
    }
}

// MARK: API
enum URLClientKey: DependencyKey {
    static let liveValue = URLClient.live
    static let previewValue = URLClient.noop
    static let testValue = URLClient.unimplemented
}

extension DependencyValues {
    var urlClient: URLClient {
        get { self[URLClientKey.self] }
        set { self[URLClientKey.self] = newValue }
    }
}

// MARK: Test
extension URLClient {
    static let noop: Self = .init(
        checkIfHandleable: { _ in false },
        checkIfMPVURL: { _ in false },
        parseGalleryID: { _ in .init() }
    )

    static let unimplemented: Self = .init(
        checkIfHandleable: XCTestDynamicOverlay.unimplemented("\(Self.self).checkIfHandleable"),
        checkIfMPVURL: XCTestDynamicOverlay.unimplemented("\(Self.self).checkIfMPVURL"),
        parseGalleryID: XCTestDynamicOverlay.unimplemented("\(Self.self).parseGalleryID")
    )
}
