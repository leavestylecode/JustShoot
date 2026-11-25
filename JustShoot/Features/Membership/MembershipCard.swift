import SwiftUI

struct MembershipCard: View {
    let memberSince: Date?
    var celebrate = false

    private let gold = Color(red: 0.96, green: 0.82, blue: 0.58)
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: AppBrand.displayName)
                    .font(.headline.weight(.bold))
                Spacer()
                if memberSince != nil {
                    Label("Membership Active", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(gold)
                        .accessibilityIdentifier("membership.active")
                } else {
                    Image(systemName: "crown")
                        .foregroundStyle(gold)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            if memberSince != nil {
                StarManArtwork(animate: celebrate)
                    .frame(width: 164, height: 164)
                    .frame(maxWidth: .infinity)
            } else {
                filmStrip
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Lifetime Membership")
                    .font(.system(.largeTitle, design: .serif, weight: .medium))
                    .accessibilityAddTraits(.isHeader)
                if let memberSince {
                    Text("Member since \(memberSince, format: .dateTime.year().month(.abbreviated).day())")
                        .font(.subheadline)
                        .foregroundStyle(gold)
                } else {
                    Text("One-time purchase")
                        .font(.subheadline)
                        .foregroundStyle(gold)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
        }
        .foregroundStyle(AppBrand.paper)
        .background {
            LinearGradient(colors: [Color(red: 0.22, green: 0.19, blue: 0.18), AppBrand.ink],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if memberSince != nil {
                RadialGradient(colors: [gold.opacity(0.18), .clear], center: .center,
                               startRadius: 10, endRadius: 150)
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(gold.opacity(0.26), lineWidth: 1) }
    }

    private var filmStrip: some View {
        VStack(spacing: 6) {
            perforations
            GeometryReader { geometry in
                HStack(spacing: 6) {
                    VaultImage(filename: FilmSampleScene.pinkDiner.filename, maxPixel: 800)
                        .frame(width: geometry.size.width * 0.62)
                    VaultImage(filename: FilmSampleScene.train.filename, maxPixel: 520)
                }
            }
            .aspectRatio(2.5, contentMode: .fit)
            perforations
        }
        .padding(.vertical, 6)
        .background(.black.opacity(0.45))
        .accessibilityHidden(true)
    }

    private var perforations: some View {
        Canvas { context, size in
            for x in stride(from: CGFloat(7), to: size.width, by: 19) {
                let hole = CGRect(x: x, y: 0, width: 9, height: size.height)
                context.fill(Path(roundedRect: hole, cornerRadius: 1.5), with: .color(AppBrand.paper.opacity(0.45)))
            }
        }
        .frame(height: 5)
    }
}
