import SwiftUI
import UIKit
import GoogleSignIn

private enum PIManTab: String, CaseIterable, Identifiable {
    case today
    case ajgpt
    case enneagram
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .ajgpt: return "AJGPT"
        case .enneagram: return "Lens"
        case .more: return "More"
        }
    }

    var icon: String {
        switch self {
        case .today: return "house"
        case .ajgpt: return "sparkles"
        case .enneagram: return "circle.hexagongrid"
        case .more: return "square.grid.2x2"
        }
    }
}

struct PIManShellView: View {
    @StateObject private var browser = PIManBrowser()
    private let gold = Color(red: 212 / 255, green: 175 / 255, blue: 124 / 255)
    private let charcoal = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)

    private var showingAppNavigation: Bool {
        let path = browser.path
        let routes: Set<String> = [
            "/today", "/checkin", "/quicklog", "/growth", "/ajgpt", "/enneagram",
            "/more", "/becoming", "/journal", "/accountability", "/brotherhood", "/profile"
        ]
        return routes.contains(path)
    }

    private func isSelected(_ tab: PIManTab) -> Bool {
        let path = browser.path
        switch tab {
        case .today: return ["/today", "/checkin", "/quicklog"].contains(path)
        case .ajgpt: return path == "/ajgpt"
        case .enneagram: return path == "/enneagram"
        case .more: return !["/today", "/checkin", "/quicklog", "/ajgpt", "/enneagram"].contains(path)
        }
    }

    var body: some View {
        ZStack {
            charcoal.ignoresSafeArea()
            PIManWebView(browser: browser)
                .background(charcoal)

            // Keep the WKWebView visible while routes load. The existing
            // Next.js loading screen provides the single branded progress UI;
            // a native spinner here would overlay it with a second design.

            if let failure = browser.failure {
                VStack(spacing: 18) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 32))
                        .foregroundStyle(gold)
                    Text("PI Man is temporarily offline")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(Color(red: 247 / 255, green: 243 / 255, blue: 233 / 255))
                    Text(failure)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { browser.retry() }
                        .buttonStyle(.borderedProminent)
                        .tint(gold)
                }
                .padding(26)
                .frame(maxWidth: 330)
                .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .contain)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showingAppNavigation {
                nativeNavigation
            }
        }
        .onOpenURL { url in
            // GoogleSignIn owns its registered redirect scheme.
            if !GIDSignIn.sharedInstance.handle(url) {
                browser.openIncoming(url)
            }
        }
    }

    private var nativeNavigation: some View {
        HStack(spacing: 2) {
            ForEach(PIManTab.allCases) { tab in
                let selected = isSelected(tab)
                Button {
                    browser.openPath(tab.rawValue)
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: selected ? tab.icon + ".fill" : tab.icon)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                            .accessibilityHidden(true)
                        Text(tab.title)
                            .font(.system(size: 10, weight: selected ? .bold : .medium))
                    }
                    .foregroundStyle(selected ? gold : Color(red: 174 / 255, green: 170 / 255, blue: 161 / 255))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 11)
                    .padding(.bottom, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .background {
            charcoal
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(gold.opacity(0.23))
                        .frame(height: 0.5)
                }
        }
    }
}

#Preview {
    PIManShellView()
}
