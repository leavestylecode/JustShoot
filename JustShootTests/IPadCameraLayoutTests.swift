import SwiftUI
import XCTest
@testable import JustShoot

final class IPadCameraLayoutTests: XCTestCase {
    func testPortraitLandscapeAndNarrowIPadKeepShutterAtRightGripAndZoomAtLeft() {
        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                     CGSize(width: 1032, height: 1376), CGSize(width: 1376, height: 1032),
                     CGSize(width: 375, height: 640), CGSize(width: 600, height: 450)] {
            let aspect = size.width > size.height ? 4.0 / 3.0 : 3.0 / 4.0
            for zoomCount in [4, 6] {
                let layout = IPadCameraLayoutGeometry(size: size, aspect: aspect, zoomCount: zoomCount)
                let bounds = CGRect(origin: .zero, size: size)
                XCTAssertEqual(layout.shutter.x, layout.preview.maxX - 60)
                XCTAssertLessThanOrEqual(layout.shutter.y, size.height / 2)
                if size.height >= 744 { XCTAssertEqual(layout.shutter.y, size.height / 2) }
                XCTAssertLessThan(layout.zoom.x, size.width / 2)
                XCTAssertEqual(layout.zoom.x, layout.preview.minX + 52)
                XCTAssertEqual(layout.recentPhoto.x, layout.shutter.x)
                XCTAssertGreaterThan(layout.recentPhoto.y - 28, layout.shutter.y + 36)
                if layout.toolsAxis == .vertical {
                    XCTAssertLessThanOrEqual(layout.tools.maxY + 20, layout.shutter.y - 36)
                } else {
                    XCTAssertEqual(layout.tools.height, 44)
                    XCTAssertGreaterThan(layout.tools.minX, 116, "Keep the back and location controls clear")
                }
                XCTAssertTrue(bounds.contains(layout.preview))
                XCTAssertTrue(bounds.contains(layout.tools))
                XCTAssertTrue(bounds.contains(layout.picker))
                XCTAssertLessThanOrEqual(layout.picker.width, min(840, size.width - 32))
                XCTAssertEqual(layout.picker.midX, size.width / 2)
                XCTAssertEqual(layout.picker.maxY, size.height - 16)
                XCTAssertLessThanOrEqual(layout.recentPhoto.y + 28 + 16, layout.picker.minY)
                XCTAssertEqual(layout.preview.width / layout.preview.height, aspect, accuracy: 0.00001)
                let focalFrame = CGRect(x: layout.zoom.x - 26, y: layout.zoom.y - CGFloat(zoomCount * 46 + 6) / 2,
                    width: 52, height: CGFloat(zoomCount * 46 + 6))
                XCTAssertTrue(bounds.contains(focalFrame))
                XCTAssertTrue(layout.preview.contains(focalFrame), "Focal lengths must not straddle the photo edge")
                XCTAssertTrue(layout.preview.contains(CGRect(x: layout.shutter.x - 38,
                    y: layout.shutter.y - 38, width: 76, height: 76)))
                XCTAssertGreaterThanOrEqual(focalFrame.minY, 84)
                XCTAssertFalse(focalFrame.intersects(layout.picker))
                let backFrame = CGRect(x: layout.back.x - 26, y: layout.back.y - 26, width: 52, height: 52)
                XCTAssertTrue(bounds.contains(backFrame))
                XCTAssertEqual(backFrame.midX, focalFrame.midX)
                XCTAssertEqual(focalFrame.minY - backFrame.maxY, 16)
                XCTAssertFalse(backFrame.intersects(layout.tools))
                XCTAssertFalse(backFrame.intersects(layout.picker))
                for showsPicker in [false, true] {
                    let adjustments = layout.adjustmentFrame(showsPicker: showsPicker)
                    XCTAssertTrue(bounds.contains(adjustments))
                    XCTAssertFalse(adjustments.intersects(layout.tools))
                    XCTAssertFalse(adjustments.intersects(focalFrame))
                    XCTAssertFalse(adjustments.intersects(backFrame))
                    if showsPicker { XCTAssertFalse(adjustments.intersects(layout.picker)) }
                    if layout.toolsAxis == .vertical {
                        XCTAssertEqual(adjustments.minY + 10, layout.preview.minY + 16, accuracy: 0.01)
                    }
                    let bottomEdge = showsPicker ? min(layout.preview.maxY, layout.picker.minY) : layout.preview.maxY
                    XCTAssertEqual(adjustments.maxY - 10, bottomEdge - 16, accuracy: 0.01)
                }
            }
        }
    }

    @MainActor
    func testOpeningLookPickerKeepsRenderedViewfinderAndShutterStationary() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let covers = try await FilmSourcePickerStrip.preloadCovers(displayScale: window.screen.scale)

        for size in [CGSize(width: 834, height: 1194), CGSize(width: 1194, height: 834),
                     CGSize(width: 1032, height: 1376), CGSize(width: 375, height: 640),
                     CGSize(width: 600, height: 450)] {
            let state = LayoutState()
            let host = UIHostingController(rootView: LayoutFixture(state: state, size: size, covers: covers))
            root.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let preview = try XCTUnwrap(state.frames["preview"])
            let shutter = try XCTUnwrap(state.frames["shutter"])
            XCTAssertEqual(shutter.midX, preview.maxX - 60, accuracy: 1)
            let recentPhoto = try XCTUnwrap(state.frames["recentPhoto"])
            let focalLengths = try XCTUnwrap(state.frames["focalLengths"])
            let back = try XCTUnwrap(state.frames["back"])
            XCTAssertEqual(back.midX, focalLengths.midX, accuracy: 0.5)
            XCTAssertEqual(focalLengths.minY - back.maxY, 16, accuracy: 0.5)
            let bounds = CGRect(origin: .zero, size: size)
            XCTAssertTrue(bounds.contains(focalLengths), "Every focal length must fit without opening a menu")
            XCTAssertGreaterThanOrEqual(focalLengths.height, CGFloat(size.width >= 700 ? 6 : 4) * 44)
            try assertControlsRemainAccessible(state: state, host: host, bounds: bounds)
            state.showsPicker = true
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            XCTAssertEqual(state.frames["preview"], preview)
            XCTAssertEqual(state.frames["shutter"], shutter)
            XCTAssertEqual(state.frames["back"], back)
            let picker = try XCTUnwrap(state.frames["picker"])
            XCTAssertEqual(picker.maxY, size.height - 16, accuracy: 1)
            XCTAssertLessThanOrEqual(picker.width, min(840, size.width - 32) + 1)
            XCTAssertEqual(picker.midX, size.width / 2, accuracy: 1)
            XCTAssertGreaterThanOrEqual(picker.minY, recentPhoto.maxY + 16)
            let curves = try XCTUnwrap(state.frames["curves"])
            let films = try XCTUnwrap(state.frames["films"])
            XCTAssertTrue(picker.contains(curves) && picker.contains(films), "Both complete rows must fit inside the overlay")
            XCTAssertEqual(curves.height, films.height, accuracy: 0.5)
            XCTAssertEqual(curves.height, size.width >= 700 ? 80 : 70, accuracy: 0.5)
            try assertControlsRemainAccessible(state: state, host: host, bounds: bounds)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "ipad-camera-\(Int(size.width))x\(Int(size.height))-picker"
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ipad-camera-\(Int(size.width))x\(Int(size.height)).png")
            try XCTUnwrap(image.pngData()).write(to: url)
            print("ipad_camera_snapshot path=\(url.path)")
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    @MainActor
    private func assertControlsRemainAccessible(state: LayoutState, host: UIViewController, bounds: CGRect) throws {
        let names = ["back", "location", "shutter", "recentPhoto", "focalLengths", "exposure"]
            + ["bolt.slash.fill", "livephoto", "slider.horizontal.3", "camera.filters"].map { "tool.\($0)" }
        let controls = try names.map { name in (name, try XCTUnwrap(state.frames[name], name)) }
        for (index, control) in controls.enumerated() {
            XCTAssertTrue(bounds.contains(control.1), "\(control.0) must remain visible")
            XCTAssertGreaterThanOrEqual(control.1.width, 44)
            XCTAssertGreaterThanOrEqual(control.1.height, 44)
            for other in controls.dropFirst(index + 1) {
                XCTAssertFalse(control.1.intersects(other.1), "\(control.0) overlaps \(other.0)")
            }
            if state.showsPicker {
                XCTAssertFalse(control.1.intersects(try XCTUnwrap(state.frames["picker"])), "Picker covers \(control.0)")
            }
        }
        func sliders(in view: UIView) -> [CameraColorSliderView] {
            (view as? CameraColorSliderView).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
        }
        let tracks = sliders(in: host.view)
        XCTAssertEqual(tracks.count, 2)
        let tint = try XCTUnwrap(tracks.first { $0.accessibilityIdentifier == "camera.white_balance.tint" })
        let temperature = try XCTUnwrap(tracks.first { $0.accessibilityIdentifier == "camera.white_balance.temperature" })
        let tintFrame = tint.convert(tint.bounds, to: host.view)
        let temperatureFrame = temperature.convert(temperature.bounds, to: host.view)
        let adjustmentFrame = try XCTUnwrap(state.frames["whiteBalance"])
        XCTAssertEqual(tintFrame.minY, adjustmentFrame.minY + 10, accuracy: 0.5,
            "Tint must remain at the upper edge")
        XCTAssertEqual(temperatureFrame.maxY, adjustmentFrame.maxY - 10, accuracy: 0.5,
            "Temperature must remain at the lower edge")
        XCTAssertLessThan(tintFrame.maxY, temperatureFrame.minY)
        for track in tracks {
            let frame = track.convert(track.bounds, to: host.view)
            XCTAssertTrue(bounds.contains(frame))
            XCTAssertEqual(frame.height, 44, accuracy: 0.5)
            for control in controls {
                XCTAssertFalse(frame.intersects(control.1), "White balance overlaps \(control.0)")
            }
            if state.showsPicker {
                XCTAssertFalse(frame.intersects(try XCTUnwrap(state.frames["picker"])))
            }
        }
    }
}

@MainActor
private final class LayoutState: ObservableObject {
    @Published var showsPicker = false
    var frames: [String: CGRect] = [:]
}

private struct FramePreference: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func measure(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: FramePreference.self,
                value: [name: geometry.frame(in: .named("cameraLayout"))])
        })
    }
}

private struct LayoutFixture: View {
    @ObservedObject var state: LayoutState
    let size: CGSize
    let covers: [FilmPreset: UIImage]

    private var focalInfo: DeviceFocalInfo {
        DeviceFocalInfo(options: (size.width >= 700 ? [13, 24, 35, 50, 100, 200] : [13, 24, 35, 50])
            .map { FocalLengthOption($0) }, constituents: [], primaryNativeMm: 24)
    }

    var body: some View {
        IPadCameraLayout(aspect: size.width > size.height ? 4.0 / 3.0 : 3.0 / 4.0,
            showsPicker: state.showsPicker, zoomCount: focalInfo.options.count) {
            Color.gray.opacity(0.3)
                .overlay {
                    Path { path in
                        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
                            path.move(to: CGPoint(x: 0, y: size.height * fraction))
                            path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                            path.move(to: CGPoint(x: size.width * fraction, y: 0))
                            path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        }
                    }.stroke(.white.opacity(0.25))
                }
                .clipped()
                .measure("preview")
        } tools: { axis in
            IPadCameraTools(axis: axis) {
                ForEach(["bolt.slash.fill", "livephoto", "slider.horizontal.3", "camera.filters"], id: \.self) { icon in
                    Image(systemName: icon)
                        .foregroundStyle(icon == "slider.horizontal.3" ? Color.yellow : .white)
                        .iPadCameraTool(compact: axis == .horizontal)
                        .measure("tool.\(icon)")
                }
            }
        } shutter: {
            CameraShutterButton(isCapturing: false, isPreparingFilm: false,
                canCapture: true, isPressed: false) { }
                .measure("shutter")
        } recentPhoto: {
            Image(systemName: "photo.fill")
                .frame(width: 56, height: 56)
                .background(.gray, in: RoundedRectangle(cornerRadius: 8))
                .measure("recentPhoto")
        } zoom: {
            FocalLengthStrip(focalInfo: focalInfo, current: FocalLengthOption(35),
                contentRotation: .zero, axis: .vertical) { _ in }
                .measure("focalLengths")
        } picker: {
            IPadCameraLookPanel {
                FilmCurvePickerStrip(curves: CurvePreset.allCases.map(FilmCurve.builtIn),
                    current: .builtIn(.none), contentRotation: .zero, orientation: .portrait,
                    style: .iPadOverlay, onManage: {}, onSelect: { _ in })
                    .measure("curves")
            } films: {
                FilmSourcePickerStrip(current: .preset(.fujiRawVelvia), sources: FilmPreset.allCases.map(FilmSource.preset),
                    contentRotation: .zero, orientation: .portrait, preparedCovers: covers,
                    style: .iPadOverlay) { _ in }
                    .measure("films")
            }
            .measure("picker")
        } overlays: { layout in
            let frame = layout.adjustmentFrame(showsPicker: state.showsPicker)
            WhiteBalanceControl(selection: .automatic, tint: .automatic,
                automaticReading: CameraWhiteBalanceReading(temperature: 5_200, tint: 8),
                onTemperature: { _ in }, onTint: { _ in }, onAutomaticTemperature: {},
                onAutomaticTint: {}, onEditingEnded: {})
                .frame(width: frame.width, height: frame.height)
                .measure("whiteBalance")
                .position(x: frame.midX, y: frame.midY)
            ExposureCompensationControl(bias: 0.7) { _ in }
                .measure("exposure")
                .position(layout.exposurePosition(showsColorControls: true, showsPicker: state.showsPicker))
            IPadCameraBackButton().measure("back").position(layout.back)
            Image(systemName: "location.slash.fill").foregroundStyle(.orange)
                .frame(width: 44, height: 44).cameraControlSurface()
                .measure("location").position(x: 108, y: 38)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "cameraLayout")
        .onPreferenceChange(FramePreference.self) { state.frames = $0 }
        .foregroundStyle(.white)
        .background(.black)
        .preferredColorScheme(.dark)
        .environment(\.horizontalSizeClass, size.width >= 700 ? .regular : .compact)
        .ignoresSafeArea()
    }
}
