import SwiftUI

private let cameraHorizontalInset: CGFloat = 16

/// The camera owns its top inset so the viewfinder and both picker rows share the
/// same animation clock. The system navigation bar stays hidden for the whole page.
struct IPhoneCameraPage<Controls: View, Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let showsPicker: Bool
    var reduceMotion = false
    var canHideTopBar = true
    @ViewBuilder var controls: Controls
    @ViewBuilder var content: Content

    var body: some View {
        let showsTopBar = !showsPicker || !canHideTopBar
        content
            .padding(.top, showsTopBar ? 52 : 0)
            .overlay(alignment: .top) {
                HStack(spacing: 6) {
                    CameraBackButton()
                    Spacer(minLength: 0)
                    controls
                }
                .buttonStyle(.plain)
                .padding(.horizontal, cameraHorizontalInset)
                .frame(height: 52)
                .offset(y: showsTopBar ? 0 : -10)
                .opacity(showsTopBar ? 1 : 0)
                .allowsHitTesting(showsTopBar)
                .accessibilityHidden(!showsTopBar)
            }
            .background(colorScheme == .light ? Color.white : .black)
            .animation(reduceMotion ? nil : .smooth(duration: 0.34), value: showsPicker)
    }
}

struct IPhoneCameraLayout<Viewfinder: View, FocalLengths: View, PickerRows: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    let showsPicker: Bool
    @ViewBuilder var viewfinder: Viewfinder
    @ViewBuilder var focalLengths: FocalLengths
    @ViewBuilder var pickerRows: () -> PickerRows

    var body: some View {
        let rowHeight = CameraPickerStyle.iPhoneCamera.rowHeight(for: sizeClass)
        let rowSpacing: CGFloat = 2
        let sectionSpacing: CGFloat = 8
        let pickerHeight = sectionSpacing + 2 * rowHeight + rowSpacing
        VStack(spacing: 0) {
            viewfinder
                .padding(.horizontal, colorScheme == .light ? cameraHorizontalInset : 0)
            focalLengths
                .padding(.horizontal, cameraHorizontalInset)
                .padding(.top, sectionSpacing)
            // Keep the horizontal clipping bounds fixed, even while the rows are unmounted.
            Color.clear
                .frame(height: showsPicker ? pickerHeight : 0)
                .overlay(alignment: .topLeading) {
                    if showsPicker {
                        VStack(spacing: rowSpacing, content: pickerRows)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, sectionSpacing)
                            .padding(.horizontal, cameraHorizontalInset)
                            .pageContentWidth(PageLayout.cameraControlsWidth)
                            .transition(.opacity)
                    }
                }
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 8)
    }
}

struct IPhoneCameraCaptureBar<RecentPhoto: View, Shutter: View, FilmPicker: View>: View {
    @ViewBuilder var recentPhoto: RecentPhoto
    @ViewBuilder var shutter: Shutter
    @ViewBuilder var filmPicker: FilmPicker

    var body: some View {
        HStack {
            recentPhoto
            Spacer()
            shutter
            Spacer()
            filmPicker
        }
        .padding(.horizontal, cameraHorizontalInset)
        .pageContentWidth(PageLayout.cameraControlsWidth)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}
