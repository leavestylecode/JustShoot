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

    enum ReferenceScene: CaseIterable {
        case street, landscape, portrait

        var photo: FilmSampleScene {
            switch self {
            case .street: .rainCyclist
            case .landscape: .fuji
            case .portrait: .park
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .street: FilmSceneTag.street.title
            case .landscape: FilmSceneTag.landscape.title
            case .portrait: FilmSceneTag.portrait.title
            }
        }
    }

    struct Sample {
        static let film = FilmPreset.kodakPortra400

        let look: Look
        let filmOnly: UIImage
        let filmWithCurve: UIImage?

        static func load(scene: ReferenceScene, look: Look) async -> Sample? {
            guard let filmOnly = await FilmCardImageCache.shared.loadImage(
                imageName: scene.photo.filename, maxPixel: 1024, gradedWith: film
            ), !Task.isCancelled else { return nil }

            return await BlockingImageWork.shared.run {
                let curve = look.curve
                guard !curve.isNeutral else { return Sample(look: look, filmOnly: filmOnly, filmWithCurve: nil) }
                guard let input = filmOnly.cgImage,
                      let output = FilmProcessor.shared.gradedPreview(input, curve: curve) else { return nil }
                return Sample(look: look, filmOnly: filmOnly, filmWithCurve: UIImage(cgImage: output))
            }
        }
    }

    private struct Request: Equatable {
        let scene: ReferenceScene
        let look: Look
        let attempt: Int
    }

    let look: Look
    @State private var scene = ReferenceScene.street
    @State private var samples: [ReferenceScene: Sample] = [:]
    @State private var failedRequest: Request?
    @State private var attempt = 0

    var body: some View {
        let request = Request(scene: scene, look: look, attempt: attempt)
        let sample = samples[scene]

        VStack(spacing: 4) {
            Rectangle()
                .fill(.primary.opacity(0.05))
                .aspectRatio(1.5, contentMode: .fit)
                .overlay {
                    if failedRequest == request {
                        PageNotice(title: "Preview unavailable", systemImage: "photo",
                            action: .init(title: "Retry", icon: "arrow.clockwise") { attempt += 1 })
                    } else if let sample {
                        if let filmWithCurve = sample.filmWithCurve {
                            CurvePhotoWipe(filmOnly: sample.filmOnly, filmWithCurve: filmWithCurve, scene: scene.photo)
                        } else {
                            Image(uiImage: sample.filmOnly)
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel(Text(scene.photo.title))
                                .accessibilityIdentifier("curves.samplePhoto")
                        }
                    } else {
                        ProgressView().accessibilityLabel("Loading sample")
                    }
                }
                .clipShape(.rect(cornerRadius: 12))

            HStack(spacing: 12) {
                ForEach(ReferenceScene.allCases, id: \.self) { option in
                    Button { scene = option } label: {
                        Text(option.title)
                            .font(.subheadline.weight(scene == option ? .semibold : .regular))
                            .foregroundStyle(scene == option ? .primary : .secondary)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) {
                                if scene == option { Capsule().frame(height: 2) }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(.rect)
                    }
                    .accessibilityAddTraits(scene == option ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Text(verbatim: Sample.film.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .task(id: request) { await load(request) }
    }

    private func load(_ request: Request) async {
        guard samples[request.scene]?.look != request.look else { return }
        if case .draft = request.look, samples[request.scene] != nil {
            guard (try? await Task.sleep(for: .milliseconds(90))) != nil else { return }
        }
        let sample = await Sample.load(scene: request.scene, look: request.look)
        guard !Task.isCancelled else { return }
        if let sample {
            samples[request.scene] = sample
            failedRequest = nil
        } else {
            failedRequest = request
        }
    }
}

private struct CurvePhotoWipe: View {
    let filmOnly: UIImage
    let filmWithCurve: UIImage
    let scene: FilmSampleScene
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let divider = size.width * split
            ZStack(alignment: .topLeading) {
                photo(filmWithCurve, size: size)
                photo(filmOnly, size: size)
                    .mask(alignment: .leading) { Rectangle().frame(width: divider) }

                Rectangle()
                    .fill(.white)
                    .frame(width: 1.5)
                    .padding(.horizontal, 0.5)
                    .background(.black.opacity(0.35))
                    .position(x: divider, y: size.height / 2)

                HStack {
                    badge("LUT").opacity(split > 0.22 ? 1 : 0)
                    Spacer()
                    badge("LUT + Curve").opacity(split < 0.78 ? 1 : 0)
                }
                .padding(10)
                .frame(maxHeight: .infinity, alignment: .bottom)

                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 32, height: 32)
                    .background(.white, in: .circle)
                    .overlay { Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5) }
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
            Slider(value: $split, in: 0...1) {
                Text("LUT image coverage")
            }
            .accessibilityValue(Text(split, format: .percent.precision(.fractionLength(0))))
            .accessibilityHint(Text(scene.title))
            .accessibilityIdentifier("curves.photoComparison")
        }
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
