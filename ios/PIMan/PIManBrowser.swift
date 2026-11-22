import Combine
import SwiftUI
import UIKit
import WebKit

/// The iOS client uses the existing authenticated PI Man website as its data and
/// coaching service. No Supabase service keys, Lens mappings, or model rules live here.
///
/// The origin allowlist is navigation policy, not an authentication boundary.
/// Supabase sessions remain in WKWebView's persistent first-party cookie store.
final class PIManBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    // Only fixed reviewed targets; the public TestFlight builder forces sandbox.
    // Page JavaScript cannot choose a different API, host or session origin.
    private static let productionOrigin = URL(string: "https://app.pi-man.com")!
    private static let sandboxOrigin = URL(string: "https://pi-man-v10-git-feat-billing-entitlement-efe602-iandresari4-2394.vercel.app")!
    static let origin: URL = {
        let environment = Bundle.main.object(forInfoDictionaryKey: "PIManEnvironment") as? String ?? "production"
        switch environment {
        case "production": return productionOrigin
        case "sandbox": return sandboxOrigin
        default: fatalError("Unsupported PI Man iOS environment")
        }
    }()

    static func isOwnSecureCookie(_ cookie: HTTPCookie) -> Bool {
        guard cookie.isSecure, let host = origin.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        return domain == host || domain == "." + host
    }

    @Published private(set) var path = "/"
    @Published private(set) var loading = true
    @Published private(set) var failure: String?
    private lazy var nativeAuth = PIManNativeSignIn(browser: self)
    private lazy var nativeBilling = PIManStoreBilling(browser: self)

    private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
        weak var destination: WKScriptMessageHandler?
        init(_ destination: WKScriptMessageHandler) {
            self.destination = destination
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            destination?.userContentController(controller, didReceive: message)
        }
    }

    private static let nativeBridge = #"""
    (function () {
      // Experience-only flag: never use it for access control on the server.
      window.__PI_MAN_IOS_NATIVE__ = true;

      function nativeStyle() {
        if (!document.head || document.getElementById('pi-man-ios-style')) return;
        var style = document.createElement('style');
        style.id = 'pi-man-ios-style';
        // The four primary routes are presented as real native iOS controls.
        // Existing page content, AJGPT and check-in logic remain untouched.
        style.textContent = '#bottomNav { display: none !important; }'
          + ' .auth-google, .auth-google-native { display:none !important; }';
        document.head.appendChild(style);
      }
      nativeStyle();
      document.addEventListener('DOMContentLoaded', nativeStyle);

      function tellNative() {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.piManRoute) {
          window.webkit.messageHandlers.piManRoute.postMessage(window.location.pathname);
        }
      }

      ['pushState', 'replaceState'].forEach(function (name) {
        var previous = history[name];
        history[name] = function () {
          var result = previous.apply(this, arguments);
          tellNative();
          return result;
        };
      });
      addEventListener('popstate', tellNative);
      addEventListener('pageshow', tellNative);
      document.addEventListener('DOMContentLoaded', tellNative);
    })();
    """#

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let content = configuration.userContentController
        content.add(WeakScriptHandler(self), name: "piManRoute")
        content.add(WeakScriptHandler(self), name: "piManAuth")
        content.add(WeakScriptHandler(self), name: "piManBilling")
        content.addUserScript(WKUserScript(
            source: "window.__PI_MAN_IOS_GOOGLE_ENABLED__ = " +
                (PIManNativeSignIn.googleConfigured ? "true" : "false") + ";\n" + Self.nativeBridge,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        web.scrollView.backgroundColor = web.backgroundColor
        nativeBilling.observeTransactions()
        web.load(URLRequest(url: Self.origin, cachePolicy: .useProtocolCachePolicy))
        return web
    }()

    static func isFirstParty(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == origin.host
            && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil
    }

    private static func validExternalScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "mailto", "tel", "whatsapp"].contains(scheme)
    }

    func openPath(_ destination: String) {
        let permitted = Set(["today", "ajgpt", "enneagram", "more"])
        guard permitted.contains(destination) else { return }
        UISelectionFeedbackGenerator().selectionChanged()

        let js = #"""
        (function () {
          if (!document.getElementById('app')) return false;
          window.dispatchEvent(new CustomEvent('piman:navigate', {
            detail: { route: '\#(destination)' }
          }));
          return true;
        })();
        """#
        webView.evaluateJavaScript(js) { [weak self] result, error in
            if error != nil || (result as? Bool) != true {
                self?.loadPath("/" + destination)
            }
        }
    }

    func loadPath(_ value: String) {
        guard value.hasPrefix("/"), !value.hasPrefix("//"),
              let url = URL(string: value, relativeTo: Self.origin)?.absoluteURL,
              Self.isFirstParty(url) else { return }
        failure = nil
        webView.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
    }

    func retry() {
        failure = nil
        if let current = webView.url, Self.isFirstParty(current) {
            webView.reload()
        } else {
            loadPath("/")
        }
    }

    func openIncoming(_ url: URL) {
        if Self.isFirstParty(url) {
            loadPath(url.path.isEmpty ? "/" : url.path)
        } else if Self.validExternalScheme(url) {
            UIApplication.shared.open(url)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == Self.origin.host else { return }
        if message.name == "piManBilling" {
            guard let command = message.body as? [String: Any] else { return }
            nativeBilling.start(command)
            return
        }
        if message.name == "piManAuth" {
            guard let command = message.body as? [String: Any] else { return }
            nativeAuth.start(command)
            return
        }
        guard message.name == "piManRoute",
              let value = message.body as? String,
              value.hasPrefix("/"), !value.hasPrefix("//"), value.count <= 200 else { return }
        path = value
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true
        failure = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        failure = nil
        if let url = webView.url, Self.isFirstParty(url) {
            path = url.path
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loading = false
        failure = "Couldn't connect to PI Man. Check your internet connection and retry."
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loading = false
        failure = "This page couldn't load. Your progress requires a connection to PI Man."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if Self.isFirstParty(url) || url.scheme == "about" || url.scheme == "blob" {
            decisionHandler(.allow)
            return
        }

        // External destinations (including Brotherhood WhatsApp) open in the
        // system browser/app. We intentionally do not attempt embedded Google
        // OAuth; Apple and Google login need a dedicated native auth integration.
        if Self.validExternalScheme(url) {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
        if Self.isFirstParty(url) {
            webView.load(URLRequest(url: url))
        } else if Self.validExternalScheme(url) {
            UIApplication.shared.open(url)
        }
        return nil
    }

    // Do not silently grant microphone access. WebKit and iOS must prompt the
    // member before recording AJGPT voice input.
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host == Self.origin.host ? .prompt : .deny)
    }
}

struct PIManWebView: UIViewRepresentable {
    @ObservedObject var browser: PIManBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
