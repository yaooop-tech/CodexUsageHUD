import Foundation
import SwiftUI

final class SystemAppearanceMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var colorScheme: ColorScheme

    private var observer: NSObjectProtocol?

    init() {
        colorScheme = Self.currentColorScheme()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.colorScheme = Self.currentColorScheme()
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private static func currentColorScheme() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
}
