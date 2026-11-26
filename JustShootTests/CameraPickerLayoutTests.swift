import CoreImage
import SwiftUI
import XCTest
@testable import JustShoot

@MainActor
final class CameraPickerLayoutTests: XCTestCase {
    func testPhoneViewfinderAndPickerSpacing() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        let presets: [FilmPreset] = [.kodakPortra400, .kodakGold200, .fujiPro400H, .fujiC200, .kodakEktar100]
        let covers = try await FilmSourcePickerStrip.preloadCovers(presets: presets, displayScale: window.screen.scale)
        let focus = DeviceFocalInfo(options: [13, 26, 35, 50].map { FocalLengthOption($0) },
            constituents: [], primaryNativeMm: 26)
        var frames: [String: CGRect] = [:]
        func measure(_ view: some View, _ name: String) -> some View {
            view.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames[name] = $0 }
        }

        func camera(showsPicker: Bool, scheme: ColorScheme) -> some View {
            IPhoneCameraLayout(showsPicker: showsPicker) {
                measure(VaultImage(filename: FilmSampleScene.fuji.filename, maxPixel: 1200)
                    .clipShape(.rect(cornerRadius: 12))
                    .aspectRatio(3.0 / 4, contentMode: .fit), "preview")
            } focalLengths: {
                measure(FocalLengthStrip(focalInfo: focus, current: focus.defaultOption, contentRotation: .zero) { _ in }, "zoom")
            } pickerRows: {
                measure(FilmCurvePickerStrip(curves: CurvePreset.allCases.map(FilmCurve.builtIn),
                    current: .builtIn(.none), contentRotation: .zero, orientation: .portrait, style: .iPhoneCamera), "curves")
                measure(FilmSourcePickerStrip(current: .preset(presets[0]), sources: presets.map(FilmSource.preset),
                    contentRotation: .zero, orientation: .portrait, preparedCovers: covers, style: .iPhoneCamera) { _ in }, "films")
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames["layout"] = $0 }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                IPhoneCameraCaptureBar {
                    VaultImage(filename: FilmSampleScene.torii.filename, maxPixel: 160)
                        .frame(width: 46, height: 46).clipShape(.rect(cornerRadius: 8))
                } shutter: {
                    measure(CameraShutterButton(isCapturing: false, isPreparingFilm: false,
                        canCapture: true, isPressed: false) {}, "shutter")
                } filmPicker: {
                    FilmSourceCoverThumbnail(source: .preset(presets[0])).frame(width: 46, height: 46)
                }
            }
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.colorScheme, scheme)
            .background(scheme == .light ? Color.white : .black)
        }

        let state = PickerTestState()
        func page(scheme: ColorScheme) -> some View {
            NavigationStack {
                PickerTestPage(state: state) { showsPicker in
                    // Sample settled control edges. The motion test covers the transition frames.
                    IPhoneCameraPage(showsPicker: showsPicker, reduceMotion: true) {
                        Image(systemName: "bolt.slash.fill").cameraTool(compact: true)
                        Image(systemName: "drop.halffull").cameraTool(compact: true)
                    } content: {
                        camera(showsPicker: showsPicker, scheme: scheme)
                    }
                }
                .cameraButtonOnlyNavigation()
            }
            .preferredColorScheme(scheme)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
        }

        let host = UIHostingController(rootView: page(scheme: .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        XCTAssertNil(frames["films"])

        @discardableResult
        func attachScreen(_ name: String) async throws -> UIImage {
            // Allow the appearance change and bundled thumbnails to reach the screen.
            try await Task.sleep(for: .milliseconds(550))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return image
        }

        for scheme in [ColorScheme.light, .dark] {
            host.rootView = page(scheme: scheme)
            host.view.layoutIfNeeded()
            let name = scheme == .light ? "light" : "dark"
            try await attachScreen("iphone-camera-\(name)")
            let closedPreview = try XCTUnwrap(frames["preview"])
            let layout = try XCTUnwrap(frames["layout"])
            let zoomHeight = try XCTUnwrap(frames["zoom"]).height
            let shutter = try XCTUnwrap(frames["shutter"])
            let inset: CGFloat = scheme == .light ? 16 : 0
            let availableHeight = layout.height - 8 - zoomHeight - 8
            let expectedWidth = min(layout.width - 2 * inset, availableHeight * 0.75)
            XCTAssertEqual(closedPreview.width, expectedWidth, accuracy: 0.5)
            XCTAssertEqual(closedPreview.midX, layout.midX, accuracy: 0.5)

            state.showsPicker = true
            let expandedImage = try await attachScreen("iphone-camera-expanded-\(name)")
            let expandedLayout = try XCTUnwrap(frames["layout"])
            XCTAssertLessThan(expandedLayout.minY, layout.minY)
            XCTAssertGreaterThan(expandedLayout.height, layout.height)
            let preview = try XCTUnwrap(frames["preview"])
            let zoom = try XCTUnwrap(frames["zoom"])
            let curves = try XCTUnwrap(frames["curves"])
            let films = try XCTUnwrap(frames["films"])
            XCTAssertEqual(preview.width / preview.height, 0.75, accuracy: 0.002)
            XCTAssertGreaterThanOrEqual(preview.minX - layout.minX, inset - 0.5)
            XCTAssertEqual(preview.midX, layout.midX, accuracy: 0.5)
            XCTAssertLessThanOrEqual(preview.height, closedPreview.height)
            XCTAssertEqual(zoom.minY - preview.maxY, 8, accuracy: 0.5)
            XCTAssertEqual(curves.minY - zoom.maxY, 8, accuracy: 0.5)
            XCTAssertEqual(films.minY - curves.maxY, 2, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(shutter.minY - films.maxY, 11.5)
            XCTAssertEqual(frames["shutter"], shutter)
            if scheme == .light {
                let image = expandedImage
                let raster = try XCTUnwrap(CIImage(image: image))
                let context = CIContext()
                // Measure the visible card and thumbnail edges, not the surrounding scroll views.
                for centerY in [curves.midY, films.midY, shutter.midY] {
                    let rowY = raster.extent.maxY - floor(centerY * image.scale) - 1
                    let row = CGRect(x: 0, y: rowY, width: raster.extent.width, height: 1)
                    let width = Int(row.width)
                    let rowBytes = ((width + 3) / 4) * 4 // Core Image requires four-byte alignment.
                    var pixels = [UInt8](repeating: 0, count: rowBytes)
                    context.render(raster, toBitmap: &pixels, rowBytes: pixels.count, bounds: row,
                        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
                    let backdrop = Int(try XCTUnwrap(pixels.first))
                    let leftEdge = try XCTUnwrap(pixels.prefix(width).firstIndex { abs(Int($0) - backdrop) > 15 })
                    XCTAssertEqual(CGFloat(leftEdge) / image.scale, layout.minX + 16, accuracy: 0.5)
                }
            }

            state.showsPicker = false
            try await Task.sleep(for: .milliseconds(550))
            XCTAssertEqual(frames["layout"], layout)
            XCTAssertEqual(frames["preview"], closedPreview)
            XCTAssertEqual(frames["shutter"], shutter)
        }
    }

    func testPhonePickerReversesInFlightAndRespectsReduceMotion() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let state = PickerTestState()
        let preview = UIView()
        let shutter = UIView()
        func page(reduceMotion: Bool) -> some View {
            PickerTestPage(state: state) { showsPicker in
                IPhoneCameraPage(showsPicker: showsPicker, reduceMotion: reduceMotion) {
                    Image(systemName: "bolt.slash.fill").cameraTool(compact: true)
                } content: {
                    IPhoneCameraLayout(showsPicker: showsPicker) {
                        PickerMotionProbe(view: preview).aspectRatio(0.75, contentMode: .fit)
                    } focalLengths: {
                        Color.gray.frame(height: 44)
                    } pickerRows: {
                        Color.orange.frame(height: 74)
                        Color.yellow.frame(height: 74)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        IPhoneCameraCaptureBar { Color.clear.frame(width: 46, height: 46) } shutter: {
                            PickerMotionProbe(view: shutter).frame(width: 68, height: 68)
                        } filmPicker: { Color.clear.frame(width: 46, height: 46) }
                    }
                }
            }
            .environment(\.horizontalSizeClass, .compact)
        }
        let host = UIHostingController(rootView: page(reduceMotion: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        func displayedFrame(_ view: UIView) throws -> CGRect {
            let layer = try XCTUnwrap(view.layer.presentation())
            let screen = try XCTUnwrap(window.layer.presentation())
            return layer.convert(layer.bounds, to: screen)
        }
        try await Task.sleep(for: .milliseconds(50))
        let closed = try displayedFrame(preview)
        let fixedShutter = try displayedFrame(shutter)
        // SwiftUI can commit an unanimated state change on the next display update.
        // Inspect the first changed frame so an actual intermediate frame still fails.
        func firstChangedFrame(after original: CGRect) async throws -> CGRect {
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                host.view.layoutIfNeeded()
                CATransaction.flush()
                let frame = try displayedFrame(preview)
                if frame != original { return frame }
                try await Task.sleep(for: .milliseconds(8))
            } while ContinuousClock.now < deadline
            XCTFail("The preview did not change")
            return original
        }
        state.showsPicker = true
        let opened = try await firstChangedFrame(after: closed)
        XCTAssertLessThan(opened.minY, closed.minY - 12)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try displayedFrame(preview), opened)
        state.showsPicker = false
        let collapsed = try await firstChangedFrame(after: opened)
        XCTAssertEqual(collapsed, closed)

        host.rootView = page(reduceMotion: false)
        host.view.layoutIfNeeded()
        state.showsPicker = true
        func waitForIntermediateFrame() async throws -> CGRect {
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                try await Task.sleep(for: .milliseconds(8))
                let current = try displayedFrame(preview)
                XCTAssertEqual(try displayedFrame(shutter), fixedShutter)
                if current.minY > opened.minY + 2 && current.minY < closed.minY - 2 { return current }
            } while ContinuousClock.now < deadline
            XCTFail("The preview skipped the intermediate frames")
            return try displayedFrame(preview)
        }
        let duringOpening = try await waitForIntermediateFrame()
        state.showsPicker = false
        let duringReversal = try await waitForIntermediateFrame()
        XCTAssertLessThan(abs(duringReversal.minY - duringOpening.minY), abs(opened.minY - closed.minY) / 2)
        try await Task.sleep(for: .milliseconds(550))
        let settled = try displayedFrame(preview)
        let pixel = 1 / window.screen.scale
        XCTAssertEqual(settled.minX, closed.minX, accuracy: pixel)
        XCTAssertEqual(settled.minY, closed.minY, accuracy: pixel)
        XCTAssertEqual(settled.width, closed.width, accuracy: pixel)
        XCTAssertEqual(settled.height, closed.height, accuracy: pixel)
        XCTAssertEqual(try displayedFrame(shutter), fixedShutter)
    }

    func testPickerOpensAtCurrentCurveAndFilm() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let state = PickerTestState()
        let curves = CurvePreset.allCases.map(FilmCurve.builtIn)
        let films = [FilmPreset.kodakPortra400, .kodakGold200, .fujiPro400H, .fujiC200].map(FilmSource.preset)
        let curve = try XCTUnwrap(curves.last)
        let film = try XCTUnwrap(films.last)
        let host = UIHostingController(rootView: PickerTestPage(state: state) { showsPicker in
            IPhoneCameraPage(showsPicker: showsPicker, reduceMotion: false) {} content: {
                IPhoneCameraLayout(showsPicker: showsPicker) { Color.black } focalLengths: {
                    Color.clear.frame(height: 44)
                } pickerRows: {
                    FilmCurvePickerStrip(curves: curves, current: curve, contentRotation: .zero,
                        orientation: .portrait, style: .iPhoneCamera)
                    FilmSourcePickerStrip(current: film, sources: films, contentRotation: .zero,
                        orientation: .portrait, style: .iPhoneCamera) { _ in }
                }
            }
            .frame(width: 212)
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        state.showsPicker = true
        try await Task.sleep(for: .milliseconds(550))

        func scrollViews(in view: UIView) -> [UIScrollView] {
            if let scroll = view as? UIScrollView { return [scroll] }
            return view.subviews.flatMap { scrollViews(in: $0) }
        }
        let rows = scrollViews(in: host.view)
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            let end = row.contentSize.width - row.bounds.width
            XCTAssertGreaterThan(end, 0)
            XCTAssertEqual(row.contentOffset.x, end, accuracy: 1)
        }
    }

    func testSortingPreviewReturnsToFirstCurveAndCameraFindsSelection() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        func strip(_ presentation: FilmCurvePickerStrip.Presentation) -> some View {
            FilmCurvePickerStrip(curves: CurvePreset.allCases.map(FilmCurve.builtIn),
                current: .builtIn(.crossProcess), contentRotation: .zero, orientation: .portrait,
                presentation: presentation)
                .frame(width: 180)
        }
        let host = UIHostingController(rootView: strip(.preview))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()

        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host.view))
        let end = scroll.contentSize.width - scroll.bounds.width
        XCTAssertGreaterThan(end, 0)
        XCTAssertEqual(scroll.contentOffset.x, 0, accuracy: 1)
        scroll.setContentOffset(CGPoint(x: end, y: 0), animated: false)

        func waitForOffset(_ offset: @autoclosure () -> CGFloat) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while abs(scroll.contentOffset.x - offset()) > 1 && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(scroll.contentOffset.x, offset(), accuracy: 1)
        }
        host.rootView = strip(.sortingPreview)
        try await waitForOffset(0)
        host.rootView = strip(.camera)
        try await waitForOffset(scroll.contentSize.width - scroll.bounds.width)
    }

    func testStandardPickerRowsHaveMatchingHeights() async throws {
        let scene = try await TestWindowScene.foreground()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        let presets: [FilmPreset] = [.fujiRawVelvia, .fujiRawClassicChrome, .fujiRawACROS]
        let covers = try await FilmSourcePickerStrip.preloadCovers(presets: presets, displayScale: window.screen.scale)
        let films = FilmSourcePickerStrip(current: .preset(presets[0]), sources: presets.map(FilmSource.preset),
            contentRotation: .zero, orientation: .portrait, preparedCovers: covers) { _ in }
        let curves = FilmCurvePickerStrip(curves: CurvePreset.allCases.map(FilmCurve.builtIn),
            current: .builtIn(.filmSoft), contentRotation: .zero, orientation: .portrait,
            onManage: {}, onSelect: { _ in })

        for sizeClass in [UserInterfaceSizeClass.compact, .regular] {
            let proposal = CGSize(width: 390, height: 400)
            let filmHost = UIHostingController(rootView: films.environment(\.horizontalSizeClass, sizeClass))
            let curveHost = UIHostingController(rootView: curves.environment(\.horizontalSizeClass, sizeClass))
            let filmHeight = filmHost.sizeThatFits(in: proposal).height
            let curveHeight = curveHost.sizeThatFits(in: proposal).height
            XCTAssertEqual(filmHeight, curveHeight, accuracy: 0.5)
            XCTAssertEqual(filmHeight, sizeClass == .regular ? 92 : 74, accuracy: 0.5)
        }

        let host = UIHostingController(rootView: VStack(spacing: 12) {
            curves
            films
        }
        .padding(16)
        .background(.black)
        .environment(\.horizontalSizeClass, .compact)
        .preferredColorScheme(.dark))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        let height = host.sizeThatFits(in: host.view.bounds.size).height
        let size = CGSize(width: host.view.bounds.width, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            host.view.drawHierarchy(in: CGRect(x: 0, y: (height - host.view.bounds.height) / 2,
                width: size.width, height: host.view.bounds.height), afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "iphone-camera-look-picker"
        attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-camera-look-picker.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("iphone_camera_look_picker path=\(url.path)")
    }
}

@MainActor
private final class PickerTestState: ObservableObject {
    @Published var showsPicker = false
}

private struct PickerTestPage<Content: View>: View {
    @ObservedObject var state: PickerTestState
    @ViewBuilder var content: (Bool) -> Content

    var body: some View { content(state.showsPicker) }
}

private struct PickerMotionProbe: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) {}
}
