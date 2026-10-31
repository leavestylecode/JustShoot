import UIKit

/// Rotation is a device-family policy, shared by every tab, destination and sheet.
/// Navigation must never change it or force an iPad back to portrait.
enum AppInterfaceOrientationPolicy {
    static func supportedOrientations(for idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        idiom == .pad ? .all : .portrait
    }
}
