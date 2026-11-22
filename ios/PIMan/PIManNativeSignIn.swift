import AuthenticationServices
import CryptoKit
import Foundation
import GoogleSignIn
import Security
import UIKit
import WebKit

/// Presents the providers' real iOS sign-in interfaces. Provider credentials
/// are exchanged with PI Man over HTTPS from native code, never injected into
/// WKWebView JavaScript or stored in an app URL.
final class PIManNativeSignIn: NSObject, ASAuthorizationControllerDelegate,
                             ASAuthorizationControllerPresentationContextProviding {
    private weak var browser: PIManBrowser?
    private var busy = false
    private var mode = "signIn"
    private var remember = false
    private var returnTo: String?
    private var appleNonce: String?

    init(browser: PIManBrowser) {
        self.browser = browser
        super.init()
    }

    static var googleConfigured: Bool {
        guard let iosID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              let webID = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String else { return false }
        return iosID.hasSuffix(".apps.googleusercontent.com")
            && webID.hasSuffix(".apps.googleusercontent.com")
            && !iosID.contains("$") && !webID.contains("$")
    }

    func start(_ command: [String: Any]) {
        guard !busy, let browser,
              let current = browser.webView.url, PIManBrowser.isFirstParty(current),
              let provider = command["provider"] as? String,
              ["apple", "google"].contains(provider),
              let requestedMode = command["mode"] as? String,
              ["signIn", "link"].contains(requestedMode) else { return }

        // Prevent unrelated first-party pages from driving an auth operation.
        let path = current.path
        if requestedMode == "signIn" && !(path == "/auth" || path.hasPrefix("/auth/") ||
                                            path == "/2.0/auth" || path.hasPrefix("/2.0/auth/")) { return }
        if requestedMode == "link" && path != "/account/connections" { return }

        busy = true
        mode = requestedMode
        remember = command["remember"] as? Bool == true
        returnTo = command["returnTo"] as? String == "/2.0" ? "/2.0" : nil

        if provider == "google" {
            guard Self.googleConfigured,
                  let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
                  let serverID = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String,
                  let presenting = browser.webView.window?.rootViewController else {
                fail()
                return
            }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverID)
            do {
                // GoogleSignIn v9 supports a custom nonce. The ID token contains
                // its SHA-256 hash, while Supabase verifies the raw value.
                // Never disable Supabase's existing Google nonce check.
                let googleNonce = try Self.generateNonce()
                GIDSignIn.sharedInstance.signIn(
                    withPresenting: presenting,
                    hint: nil, additionalScopes: nil, nonce: Self.hash(googleNonce)
                ) { [weak self] result, error in
                    guard let self else { return }
                    guard error == nil, let result, let token = result.user.idToken?.tokenString else {
                        self.fail()
                        return
                    }
                    Task {
                        do {
                            try await self.complete(provider: "google", token: token,
                                                    nonce: googleNonce,
                                                    accessToken: result.user.accessToken.tokenString)
                        } catch { self.fail() }
                    }
                }
            } catch { fail() }
        } else {
            do {
                let nonce = try Self.generateNonce()
                appleNonce = nonce
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = [.email, .fullName]
                request.nonce = Self.hash(nonce)
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            } catch { fail() }
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window = browser?.webView.window { return window }
        return UIApplication.shared.connectedScenes.compactMap {
            ($0 as? UIWindowScene)?.keyWindow
        }.first ?? UIWindow()
    }

    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let raw = credential.identityToken,
              let token = String(data: raw, encoding: .utf8),
              let nonce = appleNonce else { fail(); return }
        appleNonce = nil
        Task {
            do { try await complete(provider: "apple", token: token, nonce: nonce, accessToken: nil) }
            catch { fail() }
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        fail()
    }

    private enum AuthFailure: Error { case invalidCredential, invalidResponse }

    private static func generateNonce() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { throw AuthFailure.invalidCredential }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func hash(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func complete(provider: String, token: String, nonce: String?, accessToken: String?) async throws {
        guard let browser else { throw AuthFailure.invalidResponse }
        let requestedMode = mode
        let url = URL(string: "https://app.pi-man.com/api/auth/" +
                      (requestedMode == "link" ? "native-link" : "native-token"))!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.pi-man.com", forHTTPHeaderField: "Origin")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        var payload: [String: Any] = ["provider": provider, "credential": token,
                                      "remember": remember]
        if let nonce { payload["nonce"] = nonce }
        if let accessToken { payload["accessToken"] = accessToken }
        if let returnTo { payload["returnTo"] = returnTo }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // Identity linking needs the user's *current* Supabase cookies. Send
        // those cookies only to our exact HTTPS origin, not to the OAuth provider.
        if requestedMode == "link" {
            let currentCookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                browser.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                    continuation.resume(returning: $0.filter {
                        $0.isSecure && ($0.domain == "app.pi-man.com" || $0.domain == ".app.pi-man.com")
                    })
                }
            }
            if let cookieHeader = HTTPCookie.requestHeaderFields(with: currentCookies)["Cookie"] {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let result = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw AuthFailure.invalidResponse }

        // Both sign-in AND identity linking may rotate the Supabase refresh
        // token. Transfer the returned session cookies into WKWebView before
        // reporting success to the user, so linked accounts stay signed in.
        // The Apple / Google ID token itself never reaches page JavaScript.
        let cookies = configuration.httpCookieStorage?.cookies(for: PIManBrowser.origin) ?? []
        guard cookies.contains(where: { $0.name.hasPrefix("sb-") && $0.name.contains("-auth-token") })
        else { throw AuthFailure.invalidResponse }
        for cookie in cookies where cookie.domain == "app.pi-man.com" || cookie.domain == ".app.pi-man.com" {
            await withCheckedContinuation { continuation in
                browser.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
        if requestedMode == "link" {
            guard result["linked"] as? Bool == true else { throw AuthFailure.invalidResponse }
            busy = false
            notify(status: "linked")
            return
        }

        guard let destination = result["destination"] as? String,
              destination.hasPrefix("/"), !destination.hasPrefix("//"),
              let resolvedURL = URL(string: destination, relativeTo: PIManBrowser.origin)?.absoluteURL,
              PIManBrowser.isFirstParty(resolvedURL)
        else { throw AuthFailure.invalidResponse }
        busy = false
        browser.webView.load(URLRequest(url: resolvedURL))
    }

    private func fail() {
        busy = false
        appleNonce = nil
        notify(status: "error")
    }

    private func notify(status: String) {
        guard let webView = browser?.webView,
              let url = webView.url, PIManBrowser.isFirstParty(url),
              let data = try? JSONSerialization.data(withJSONObject: ["status": status]),
              let value = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('piman:native-auth-status', {detail: " + value + "}));",
            completionHandler: nil
        )
    }
}
