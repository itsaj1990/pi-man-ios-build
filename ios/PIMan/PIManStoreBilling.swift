import Foundation
import StoreKit
import WebKit

/// Native StoreKit 2 purchase and restore flow. Nothing about a transaction
/// is trusted merely because the client reports it; the PI Man backend must
/// verify it with Apple's authenticated App Store Server API before we finish.
@MainActor
final class PIManStoreBilling {
    private weak var browser: PIManBrowser?
    private var busy = false
    private var updates: Task<Void, Never>?

    init(browser: PIManBrowser) { self.browser = browser }

    deinit { updates?.cancel() }

    func observeTransactions() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, case .verified(let transaction) = result,
                      transaction.productID == "com.piman.app.premium.monthly" else { continue }
                do {
                    _ = try await self.confirm(transaction, founderIntentId: nil)
                    await transaction.finish()
                } catch {
                    // Leave the transaction unfinished so the original account can retry.
                }
            }
        }
    }

    func start(_ command: [String: Any]) {
        guard !busy, let browser, let url = browser.webView.url,
              PIManBrowser.isFirstParty(url), url.path == "/subscribe",
              let action = command["action"] as? String,
              ["purchase", "restore", "quote"].contains(action) else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                if action == "purchase" {
                    try await purchase(voluntary: command["voluntary"] as? Bool == true)
                } else if action == "quote" {
                    try await quote()
                } else {
                    try await restore()
                }
            } catch {
                notify("error")
            }
        }
    }

    private enum BillingFailure: Error { case invalidResponse, invalidPurchase, unverified }

    private func request(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let browser else { throw BillingFailure.invalidResponse }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            browser.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0.filter {
                    PIManBrowser.isOwnSecureCookie($0)
                })
            }
        }
        let url = URL(string: "/api/billing/" + path, relativeTo: PIManBrowser.origin)!.absoluteURL
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(PIManBrowser.origin.absoluteString, forHTTPHeaderField: "Origin")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw BillingFailure.invalidResponse }
        for cookie in configuration.httpCookieStorage?.cookies(for: PIManBrowser.origin) ?? []
            where PIManBrowser.isOwnSecureCookie(cookie) {
            await withCheckedContinuation { continuation in
                browser.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
        return value
    }

    private func quote() async throws {
        let identifier = "com.piman.app.premium.monthly"
        guard let product = try await Product.products(for: [identifier]).first,
              let subscription = product.subscription else {
            notify("error", message: "unavailable")
            return
        }
        var prices = ["price": product.displayPrice]
        if let offer = subscription.introductoryOffer, await subscription.isEligibleForIntroOffer {
            prices["introPrice"] = offer.displayPrice
        }
        notify("quote", details: prices)
    }

    private func purchase(voluntary: Bool) async throws {
        let prepared = try await request("prepare", body: ["voluntary": voluntary])
        guard let identifier = prepared["productId"] as? String,
              identifier == "com.piman.app.premium.monthly",
              let rawToken = prepared["purchaseToken"] as? String,
              let token = UUID(uuidString: rawToken),
              let environment = prepared["storeEnvironment"] as? String else {
            throw BillingFailure.invalidResponse
        }
        // A sandbox-only server cannot open a production payment sheet.
        guard case .verified(let appTransaction) = try await AppTransaction.shared,
              (environment == "sandbox" && appTransaction.environment == .sandbox) ||
              (environment == "production" && appTransaction.environment == .production) else {
            throw BillingFailure.unverified
        }
        let products = try await Product.products(for: [identifier])
        guard let product = products.first(where: { $0.id == identifier }) else {
            notify("error", message: "unavailable")
            return
        }
        let result = try await product.purchase(options: [.appAccountToken(token)])
        switch result {
        case .success(let verified):
            guard case .verified(let transaction) = verified,
                  transaction.productID == identifier,
                  transaction.appAccountToken == token else {
                throw BillingFailure.unverified
            }
            let environment = try await confirm(transaction, founderIntentId: prepared["intentId"] as? String)
            await transaction.finish()
            notify("success", details: ["environment": environment])
        case .pending:
            notify("pending")
        case .userCancelled:
            notify("cancelled")
        @unknown default:
            throw BillingFailure.invalidPurchase
        }
    }

    private func restore() async throws {
        try await AppStore.sync()
        var environment: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == "com.piman.app.premium.monthly" else { continue }
            environment = try await confirm(transaction, founderIntentId: nil)
            await transaction.finish()
        }
        if let environment { notify("success", details: ["environment": environment]) }
        else { notify("error", message: "unavailable") }
    }

    private func confirm(_ transaction: StoreKit.Transaction, founderIntentId: String?) async throws -> String {
        var body: [String: Any] = ["transactionId": String(transaction.id)]
        if let founderIntentId { body["founderIntentId"] = founderIntentId }
        let result = try await request("apple/verify", body: body)
        guard result["verified"] as? Bool == true, let environment = result["environment"] as? String
        else { throw BillingFailure.unverified }
        return environment
    }

    private func notify(_ status: String, message: String? = nil, details: [String: String] = [:]) {
        guard let webView = browser?.webView, let url = webView.url,
              PIManBrowser.isFirstParty(url), url.path == "/subscribe" else { return }
        var detail = details
        detail["status"] = status
        if let message { detail["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: detail),
              let value = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('piman:billing-status', {detail: " + value + "}));",
            completionHandler: nil
        )
    }
}
