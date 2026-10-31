import SwiftUI

/// A gray shutter indicates that capture is unavailable; detailed status remains accessible.
struct CameraShutterButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let isCapturing: Bool
    let isPreparingFilm: Bool
    let canCapture: Bool
    let isPressed: Bool
    let action: () -> Void

    private var isUnavailable: Bool { isCapturing || isPreparingFilm || !canCapture }
    private var shutterColor: Color { isEnabled && !isUnavailable ? .white : .gray }
    private var isWaitingForSave: Bool { !isCapturing && !isPreparingFilm && !canCapture }
    private var status: LocalizedStringKey {
        if isCapturing { return "Capturing" }
        if isPreparingFilm { return "Preparing film" }
        if isWaitingForSave { return "Saving…" }
        return "Ready"
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(shutterColor, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(shutterColor)
                    .frame(width: 60, height: 60)
                    .scaleEffect(isPressed ? 0.85 : 1)
                    .animation(.easeInOut(duration: 0.1), value: isPressed)
            }
        }
        .buttonStyle(CaptureShutterButtonStyle())
        .accessibilityLabel("Capture")
        .accessibilityIdentifier("camera.shutter")
        .accessibilityHint("Take a photo")
        .accessibilityValue(Text(status))
        .disabled(isUnavailable)
    }
}

/// Touch-down responds independently of storage and native capture callbacks.
private struct CaptureShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

#Preview("Capture feedback") {
    HStack(spacing: 24) {
        CameraShutterButton(isCapturing: false, isPreparingFilm: false, canCapture: true, isPressed: false) { }
        CameraShutterButton(isCapturing: false, isPreparingFilm: true, canCapture: true, isPressed: false) { }
        CameraShutterButton(isCapturing: true, isPreparingFilm: false, canCapture: true, isPressed: true) { }
        CameraShutterButton(isCapturing: false, isPreparingFilm: false, canCapture: false, isPressed: false) { }
    }
    .padding(24)
    .background(.black)
    .preferredColorScheme(.dark)
}
