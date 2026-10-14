import UIKit
import XCTest

@MainActor
enum TestWindowScene {
    static func foreground() async throws -> UIWindowScene {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) { return scene }
            // Hosted tests can start before SwiftUI connects its scene. Yield the main actor
            // instead of asserting against the transient empty connectedScenes collection.
            try await Task.sleep(for: .milliseconds(20))
        } while ProcessInfo.processInfo.systemUptime < deadline
        return try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "Test host did not activate a window scene")
    }
}
