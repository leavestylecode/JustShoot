import XCTest
import SwiftUI
import UIKit
@testable import JustShoot

@MainActor
final class CameraColorControlsTests: XCTestCase {
    private func slider() -> CameraColorSliderView {
        let slider = CameraColorSliderView(frame: CGRect(x: 0, y: 0, width: 110, height: 44))
        slider.configure(kind: .temperature, value: 5_000, automatic: true, enabled: true, reduceMotion: false)
        slider.layoutIfNeeded()
        return slider
    }

    private func thumb(in slider: CameraColorSliderView) throws -> CALayer {
        try XCTUnwrap(slider.layer.sublayers?.first { $0.name == "color.thumb" })
    }

    func testAutomaticReadingAnimatesOnlyTheThumbWithoutEditingCameraValues() throws {
        let slider = slider()
        var edits = 0
        slider.onChange = { _ in edits += 1 }
        slider.configure(kind: .temperature, value: 6_000, automatic: true, enabled: true, reduceMotion: false)
        let thumb = try thumb(in: slider)
        let animation = try XCTUnwrap(thumb.animation(forKey: "automatic.position") as? CABasicAnimation)
        XCTAssertEqual(animation.duration, WhiteBalanceReadingGate.samplingInterval)
        XCTAssertEqual(animation.keyPath, "position.x")
        XCTAssertEqual(edits, 0)
        // Unrelated parent updates must not restart or remove the running interpolation.
        slider.configure(kind: .temperature, value: 6_000, automatic: true, enabled: true, reduceMotion: false)
        XCTAssertNotNil(thumb.animation(forKey: "automatic.position"))
        XCTAssertNil(slider.layer.animationKeys())
    }

    func testManualUpdatesAndReducedMotionDoNotAnimate() throws {
        let slider = slider()
        slider.configure(kind: .temperature, value: 6_000, automatic: false, enabled: true, reduceMotion: false)
        XCTAssertNil(try thumb(in: slider).animation(forKey: "automatic.position"))
        slider.configure(kind: .temperature, value: 7_000, automatic: true, enabled: true, reduceMotion: true)
        XCTAssertNil(try thumb(in: slider).animation(forKey: "automatic.position"))
    }

    func testDragStartsAtVisibleFractionAndRemainsContinuousBeforeQuantization() {
        let drag = CameraColorSliderDrag(startX: 70, startFraction: 0.433)
        XCTAssertEqual(drag.fraction(at: 70, travel: 60), 0.433, accuracy: 0.0001)
        XCTAssertEqual(drag.fraction(at: 70.3, travel: 60), 0.438, accuracy: 0.0001)
        XCTAssertEqual(drag.fraction(at: -1_000, travel: 60), 0)
        XCTAssertEqual(drag.fraction(at: 1_000, travel: 60), 1)
    }

    func testDragReturningToItsStartDoesNotJumpToTheFingerOnRelease() {
        let drag = CameraColorSliderDrag(startX: 50, startFraction: 0.8)
        XCTAssertEqual(drag.endingFraction(at: 50, trackStart: 44, travel: 60, hasEmittedValue: true), 0.8, accuracy: 0.0001)
        XCTAssertEqual(drag.endingFraction(at: 50, trackStart: 44, travel: 60, hasEmittedValue: false), 0.1, accuracy: 0.0001)
    }

    func testReadoutAndTrackShareOneHorizontalCenterline() throws {
        let slider = slider()
        let label = try XCTUnwrap(slider.subviews.compactMap { $0 as? UILabel }.first)
        let track = try XCTUnwrap(slider.layer.sublayers?.first { $0.name == "color.track" })
        XCTAssertEqual(label.frame.midY, track.frame.midY, accuracy: 0.01)
        XCTAssertLessThan(label.frame.maxX, track.frame.minX)
        slider.configure(kind: .temperature, value: 9_200, automatic: true, enabled: true, reduceMotion: true)
        XCTAssertEqual(label.text, "9200 K") // Real auto readings are not clamped to manual limits.
    }

    func testAccessibilityAdjustmentKeepsManualBoundsAndStep() {
        let slider = slider()
        var selected: Float?
        slider.onChange = { selected = $0 }
        slider.accessibilityIncrement()
        XCTAssertEqual(selected, 5_100)
        slider.configure(kind: .tint, value: 30, automatic: false, enabled: true, reduceMotion: false)
        slider.accessibilityIncrement()
        XCTAssertEqual(selected, 30)
        slider.accessibilityDecrement()
        XCTAssertEqual(selected, 29)
    }

    func testUnknownReadingHasNoInventedThumbOrInteractiveValue() throws {
        let slider = slider()
        slider.configure(kind: .temperature, value: nil, automatic: true, enabled: true, reduceMotion: false)
        XCTAssertTrue(try thumb(in: slider).isHidden)
        XCTAssertFalse(slider.isEnabled)
    }

    func testCompactControlsFitAndCaptureVisualPreview() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 160)
        let controls = WhiteBalanceControl(selection: .automatic, tint: .automatic,
            automaticReading: CameraWhiteBalanceReading(temperature: 5_200, tint: 8),
            onTemperature: { _ in }, onTint: { _ in }, onAutomaticTemperature: {},
            onAutomaticTint: {}, onEditingEnded: {})
        let host = UIHostingController(rootView: controls.padding(.horizontal, 16)
            .background(Color(white: 0.16)).environment(\.locale, Locale(identifier: "zh-Hans")))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        func sliders(in view: UIView) -> [CameraColorSliderView] {
            (view as? CameraColorSliderView).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
        }
        let tracks = sliders(in: host.view)
        XCTAssertEqual(tracks.count, 2)
        for track in tracks {
            let rect = track.convert(track.bounds, to: host.view)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, host.view.bounds.width)
            XCTAssertEqual(rect.height, 44, accuracy: 0.5)
        }
        let y = try XCTUnwrap(tracks.first).convert(.zero, to: window).y - 10
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: window.bounds.width, height: 64))
        let image = renderer.image { context in
            context.cgContext.translateBy(x: 0, y: -y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Horizontal color controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JustShoot-ColorControls-preview.png")
        try image.pngData()?.write(to: url)

        // iPhone SE-sized width: the two controls must remain side by side without overflow.
        window.frame.size.width = 320
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let compact = sliders(in: host.view).map { $0.convert($0.bounds, to: host.view) }.sorted { $0.minX < $1.minX }
        XCTAssertEqual(compact.count, 2)
        XCTAssertGreaterThanOrEqual(compact[0].minX, 0)
        XCTAssertLessThan(compact[0].maxX, compact[1].minX)
        XCTAssertLessThanOrEqual(compact[1].maxX, 320)
        XCTAssertEqual(compact[0].midY, compact[1].midY, accuracy: 0.5)
    }
}
