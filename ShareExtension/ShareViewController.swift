//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by 荒木辰造 on R 3/08/03.
//

import UIKit
import UniformTypeIdentifiers

/// Hands a shared gallery link over to the main app.
///
/// This controller renders nothing, so every path through it has to reach `finish(opening:)`
/// exactly once: an item that fails to load, is missing or is not a gallery link would otherwise
/// leave a blank share sheet on screen until the user dismisses it manually.
final class ShareViewController: UIViewController {
    private enum Constant {
        static let appScheme = "ehpanda"
        static let webSchemes: Set<String> = ["http", "https"]
        /// The exact hosts the main app is able to handle.
        static let allowedHosts: Set<String> = ["e-hentai.org", "exhentai.org"]
        static let galleryRoutes: Set<String> = ["g", "s"]
    }

    private var hasStarted = false
    private var hasFinished = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard !hasStarted else { return }
        hasStarted = true
        loadSharedURL()
    }

    private func loadSharedURL() {
        let typeIdentifier = UTType.url.identifier
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []
        guard let itemProvider = attachments
            .first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) })
        else {
            finish(opening: nil)
            return
        }

        itemProvider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
            let url = error == nil ? ShareViewController.appSchemeURL(from: item) : nil
            // The provider gives no main thread guarantee, while everything below is UIKit work.
            Task { @MainActor in
                self.finish(opening: url)
            }
        }
    }

    /// The single terminal path: opens the main app when a gallery link was recognized, and
    /// completes the extension request exactly once whether or not that succeeded.
    private func finish(opening url: URL?) {
        guard !hasFinished, let extensionContext = extensionContext else { return }
        hasFinished = true

        guard let url = url else {
            extensionContext.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        // `open(_:completionHandler:)` is the supported way for an extension to launch its
        // container app; reaching `UIApplication` through the responder chain is not.
        extensionContext.open(url) { _ in
            Task { @MainActor in
                extensionContext.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }

    /// Rewrites a shared gallery link into the app's custom scheme.
    ///
    /// Only the outer scheme is replaced, through `URLComponents`: a plain string replacement also
    /// rewrote occurrences inside the path, query and fragment, corrupting the link.
    private static func appSchemeURL(from item: NSSecureCoding?) -> URL? {
        guard let url = sharedURL(from: item),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), Constant.webSchemes.contains(scheme),
              let host = components.host?.lowercased(), Constant.allowedHosts.contains(host)
        else { return nil }

        let pathComponents = url.pathComponents
        guard pathComponents.count >= 4, Constant.galleryRoutes.contains(pathComponents[1]),
              !pathComponents[2].isEmpty, !pathComponents[3].isEmpty
        else { return nil }

        components.scheme = Constant.appScheme
        components.host = host
        return components.url
    }

    private static func sharedURL(from item: NSSecureCoding?) -> URL? {
        guard let item = item else { return nil }
        if let url = item as? URL {
            return url
        }
        if let string = item as? String {
            return URL(string: string)
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8).flatMap { URL(string: $0) }
        }
        return nil
    }
}
