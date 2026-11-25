import AVFoundation
import SwiftUI

/// The same two-second StarMan animation used on the author's other membership cards.
struct StarManArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let animate: Bool

    var body: some View {
        Group {
            if animate, !reduceMotion, scenePhase == .active,
               let url = Bundle.main.url(forResource: "StarMan", withExtension: "mov") {
                StarManClip(url: url)
            } else {
                Image(decorative: "StarMan")
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StarManClip: UIViewRepresentable {
    let url: URL

    class ClipView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private let poster = UIImageView(image: UIImage(named: "StarMan"))
        private var readyObservation: NSKeyValueObservation?

        init(url: URL) {
            super.init(frame: .zero)
            isOpaque = false
            poster.contentMode = .scaleAspectFit
            addSubview(poster)
            let player = AVPlayer(url: url)
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            player.actionAtItemEnd = .pause
            playerLayer.player = player
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    poster.isHidden = playerLayer.isReadyForDisplay
                }
            }
            player.play()
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            poster.frame = bounds
        }
    }

    func makeUIView(context: Context) -> ClipView { ClipView(url: url) }
    func updateUIView(_ view: ClipView, context: Context) {}

    static func dismantleUIView(_ view: ClipView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }
}
