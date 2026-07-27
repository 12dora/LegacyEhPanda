//
//  WebView.swift
//  EhPanda
//
//  Created by 荒木辰造 on R 2/12/27.
//

import WebKit
import SwiftUI

// The native session lives in `HTTPCookieStorage`, while a default `WKWebView` starts with
// an empty `WKHTTPCookieStore`. Embedded pages such as Manage Tags or the configuration
// page therefore used to load unauthenticated and ask for a second login. Cookies are
// exchanged in both directions here, and only for the app's own hosts: anything the
// embedded browser picks up elsewhere stays inside the web view's data store.
enum WebViewCookiePolicy {
    private static let trustedHostSuffixes = ["e-hentai.org", "exhentai.org"]

    static func isTrusted(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return trustedHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
    }

    static func nativeCookies(for url: URL) -> [HTTPCookie] {
        guard isTrusted(host: url.host) else { return [] }
        return HTTPCookieStorage.shared.cookies(for: url) ?? []
    }

    static func adoptNativeCookies(_ cookies: [HTTPCookie]) {
        for cookie in cookies where isTrusted(host: cookie.domain) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

struct WebView: UIViewControllerRepresentable {
    private let url: URL
    private let loginDoneAction: (() -> Void)?

    init(url: URL, loginDoneAction: (() -> Void)? = nil) {
        self.url = url
        self.loginDoneAction = loginDoneAction
    }

    final class Coodinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var parent: WebView

        init(parent: WebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Reverse sync policy: every finished navigation on a trusted host hands its
            // cookies back, so tokens the site refreshes inside the web view stay usable by
            // the native session instead of expiring there.
            if WebViewCookiePolicy.isTrusted(host: webView.url?.host) {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    WebViewCookiePolicy.adoptNativeCookies(cookies)
                }
            }

            guard parent.url.absoluteString == Defaults.URL.webLogin.absoluteString, let webViewURL = webView.url,
                  let queryItems = URLComponents(url: webViewURL, resolvingAgainstBaseURL: false)?.queryItems,
                  queryItems.contains(where: { queryItem in
                      queryItem.name == Defaults.URL.Component.Key.code.rawValue
                      && queryItem.value == Defaults.URL.Component.Value.zeroOne.rawValue
                  })
            else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.parent.loginDoneAction?()
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Logger.error(error)
        }
    }

    func makeCoordinator() -> WebView.Coodinator {
        Coodinator(parent: self)
    }

    func makeUIViewController(context: Context) -> EmbeddedWebviewController {
        let webViewController = EmbeddedWebviewController(coordinator: context.coordinator)
        webViewController.loadUrl(url)

        return webViewController
    }

    func updateUIViewController(
        _ uiViewController: EmbeddedWebviewController,
        context: UIViewControllerRepresentableContext<WebView>
    ) {}
}

final class EmbeddedWebviewController: UIViewController {
    private var webview: WKWebView

    private weak var delegate: WebView.Coordinator?

    init(coordinator: WebView.Coordinator) {
        delegate = coordinator
        webview = WKWebView()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        webview = WKWebView()
        super.init(coder: coder)
    }

    func loadUrl(_ url: URL) {
        let cookies = WebViewCookiePolicy.nativeCookies(for: url)
        guard !cookies.isEmpty else {
            webview.load(URLRequest(url: url))
            return
        }

        // Every applicable write has to be acknowledged before the first load; a request
        // issued alongside the writes can still reach the server without the session.
        let cookieStore = webview.configuration.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        cookies.forEach { cookie in
            group.enter()
            cookieStore.setCookie(cookie) {
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.webview.load(URLRequest(url: url))
        }
    }

    override func loadView() {
        webview.navigationDelegate = delegate
        webview.uiDelegate = delegate
        view = webview
    }
}
