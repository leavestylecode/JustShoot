import SwiftUI

struct CurvePhotoComparison: View {
    enum Look: Equatable, Sendable {
        case preset(CurvePreset)
        case draft(CustomFilmCurve)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case let (.preset(a), .preset(b)): a == b
            case let (.draft(a), .draft(b)):
                a.masterPoints == b.masterPoints && a.redPoints == b.redPoints
                    && a.greenPoints == b.greenPoints && a.bluePoints == b.bluePoints
            default: false
            }
        }

        var curve: FilmCurve {
            switch self {
            case .preset(let preset): .builtIn(preset)
            case .draft(let draft): draft.filmCurve
            }
        }
    }

    let look: Look
    @State private var images: (original: UIImage, graded: UIImage)?
    @State private var failed = false
    @State private var attempt = 0

    private struct Request: Equatable {
        let look: Look
        let attempt: Int
    }

    var body: some View {
        ZStack {
            if let images {
                CurvePhotoWipe(original: images.original, graded: images.graded)
            } else if failed {
                PageNotice(title: "Preview unavailable", systemImage: "photo",
                    action: .init(title: "Retry", icon: "arrow.clockwise") { attempt += 1 })
            } else {
                ProgressView().accessibilityLabel("Loading sample")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1.5, contentMode: .fit)
        .background(.primary.opacity(0.05))
        .clipShape(.rect(cornerRadius: 18))
        .task(id: Request(look: look, attempt: attempt)) {
            failed = false
            if case .draft = look, images != nil {
                // Coalesce edits while the user moves a control point.
                guard (try? await Task.sleep(for: .milliseconds(90))) != nil else { return }
            }
            let original = await FilmCardImageCache.shared.loadImage(
                imageName: FilmSampleScene.teaPortrait.filename, maxPixel: 1024)
            guard !Task.isCancelled else { return }
            let graded: UIImage? = await BlockingImageWork.shared.run { [look] in
                guard let cg = original?.cgImage,
                      let output = FilmProcessor.shared.gradedPreview(cg, curve: look.curve) else { return nil }
                return UIImage(cgImage: output)
            }
            guard !Task.isCancelled else { return }
            if let original, let graded {
                images = (original, graded)
            } else {
                images = nil
                failed = true
            }
        }
    }
}

private struct CurvePhotoWipe: View {
    let original: UIImage
    let graded: UIImage
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let divider = size.width * split
            ZStack(alignment: .topLeading) {
                photo(graded, size: size)
                photo(original, size: size)
                    .mask(alignment: .leading) { Rectangle().frame(width: divider) }

                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5)
                    .position(x: divider, y: size.height / 2)
                    .shadow(color: .black.opacity(0.4), radius: 1)

                HStack {
                    badge("Unfiltered").opacity(split > 0.22 ? 1 : 0)
                    Spacer()
                    badge("Curve Effect").opacity(split < 0.78 ? 1 : 0)
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .bottom)

                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(.white, in: .circle)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .frame(width: 44, height: size.height)
                    .contentShape(.rect)
                    .position(x: min(max(divider, 22), size.width - 22), y: size.height / 2)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("curveComparison"))
                        .onChanged { value in
                            split = min(max(value.location.x / max(size.width, 1), 0), 1)
                        })
            }
            .coordinateSpace(name: "curveComparison")
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityRepresentation {
            Slider(value: $split, in: 0...1, step: 0.1) {
                Text("Original photo coverage")
            }
        }
        .accessibilityIdentifier("curves.photoComparison")
    }

    private func photo(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image).resizable().scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.black.opacity(0.62), in: .capsule)
    }
}
