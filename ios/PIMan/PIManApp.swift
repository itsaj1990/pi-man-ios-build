import SwiftUI

@main
struct PIManApp: App {
    var body: some Scene {
        WindowGroup {
            PIManShellView()
                .preferredColorScheme(.dark)
                .tint(Color(red: 212 / 255, green: 175 / 255, blue: 124 / 255))
        }
    }
}
