import MessageUI
import SwiftUI
import UIKit

struct AboutAuthorView: View {
    @State private var isShowingMailCompose = false
    @State private var showMailAlert = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                MoreAuthorCard()

                sectionTitle("more_products")

                ForEach(MoreSectionCatalog.products) { product in
                    MoreProductCard(product: product)
                }

                sectionTitle("more_contact")
                contactButton

                websiteSectionTitle
                websiteButton
            }
            .padding()
            .pageContentWidth()
        }
        .appPageBackground()
        .navigationTitle("About the Author")
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .softScrollEdges()
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $isShowingMailCompose) {
            MailComposeView(
                recipients: ["leavestyle101@gmail.com"],
                subject: String(localized: "Feedback for \(AppBrand.displayName)"),
                body: ""
            )
            // 注意：此 sheet 不可使用 presentationDetents，否则 iOS 26 会对
            // _UISceneHostingController 调用 _setSheetConfiguration: 导致崩溃
        }
        .alert("mail_error_title", isPresented: $showMailAlert) {
            Button("OK") {}
        } message: {
            Text("mail_error_message")
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.footnote)
            .bold()
            .foregroundStyle(.secondary)
            .padding(.top)
            .padding(.leading)
    }

    private var contactButton: some View {
        Button {
            if MFMailComposeViewController.canSendMail() {
                isShowingMailCompose = true
            } else {
                showMailAlert = true
            }
        } label: {
            HStack(spacing: 16) {
                Image(decorative: "gmail_logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .padding(.leading, 10)
                Text("leavestyle101@gmail.com")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.gray)
                    .padding(.leading, 10)
                Spacer()
                Text("more_contact_email")
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .foregroundColor(.black)
                    .background(.green)
                    .cornerRadius(5)
            }
        }
        .buttonStyle(.plain)
        .padding()
        .settingsGlassCard(cornerRadius: 16, interactive: true)
    }

    private var websiteSectionTitle: some View {
        Text(NSLocalizedString("Independent Website", comment: ""))
            .font(.footnote)
            .bold()
            .foregroundStyle(.secondary)
            .padding(.top)
            .padding(.leading)
    }

    private var websiteButton: some View {
        Button {
            if let url = URL(string: "https://www.leavestyle.com") {
                UIApplication.shared.open(url)
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "globe.asia.australia.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .foregroundColor(.blue)
                    .padding(.leading, 10)
                Text("www.leavestyle.com")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(.gray)
                    .padding(.leading, 10)
                Spacer()
                Text(NSLocalizedString("Visit", comment: ""))
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .foregroundColor(.white)
                    .background(.blue)
                    .cornerRadius(5)
            }
        }
        .buttonStyle(.plain)
        .padding()
        .settingsGlassCard(cornerRadius: 16, interactive: true)
    }
}
// ============================================
// MARK: - Mail Compose View
// ============================================

private struct MailComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients(recipients)
        composer.setSubject(subject)
        composer.setMessageBody(body, isHTML: false)
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, @MainActor MFMailComposeViewControllerDelegate {
        let parent: MailComposeView

        init(_ parent: MailComposeView) {
            self.parent = parent
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: (any Error)?
        ) {
            parent.dismiss()
        }
    }
}

nonisolated struct MoreSocialLink: Identifiable, Equatable, Sendable {
    let id: String
    let imageName: String
    let imageSize: CGFloat
    let urlString: String

    var url: URL? {
        URL(string: urlString)
    }
}

nonisolated struct MoreProduct: Identifiable, Equatable, Sendable {
    let id: String
    let imageName: String
    let titleKey: String
    let descriptionKey: String
    let urlString: String
    let roundsIcon: Bool
    let badgeRed: Double
    let badgeGreen: Double
    let badgeBlue: Double
    let badgeOpacity: Double

    var url: URL? {
        URL(string: urlString)
    }
}

nonisolated enum MoreSectionCatalog {
    static let socialLinks: [MoreSocialLink] = [
        MoreSocialLink(
            id: "rednote",
            imageName: "rednote_logo",
            imageSize: 35,
            urlString: "https://www.xiaohongshu.com/user/profile/5ce77d700000000011012ba7"
        ),
        MoreSocialLink(
            id: "bilibili",
            imageName: "bilibili_logo",
            imageSize: 35,
            urlString: "https://space.bilibili.com/374625375?spm_id_from=333.1007.0.0"
        ),
        MoreSocialLink(
            id: "youtube",
            imageName: "youtube_logo",
            imageSize: 35,
            urlString: "https://www.youtube.com/@leavestyle101"
        ),
        MoreSocialLink(
            id: "x",
            imageName: "x_logo",
            imageSize: 40,
            urlString: "https://x.com/LeaveStyle1"
        ),
        MoreSocialLink(
            id: "github",
            imageName: "github_logo",
            imageSize: 35,
            urlString: "https://github.com/leavestylecode"
        ),
        MoreSocialLink(
            id: "linkedin",
            imageName: "linkedin_logo",
            imageSize: 35,
            urlString: "https://www.linkedin.com/in/jia-hunter-8903b3154/"
        )
    ]

    static let products: [MoreProduct] = [
        MoreProduct(
            id: "justnote",
            imageName: "justnote_logo",
            titleKey: "more_product_justnote",
            descriptionKey: "more_product_justnote_desc",
            urlString: "https://apps.apple.com/app/id6739179281",
            roundsIcon: true,
            badgeRed: 0.43,
            badgeGreen: 0.27,
            badgeBlue: 0.78,
            badgeOpacity: 0.6
        ),
        MoreProduct(
            id: "demark",
            imageName: "demark_logo",
            titleKey: "more_product_demark",
            descriptionKey: "more_product_demark_desc",
            urlString: "https://apps.apple.com/app/id6499131459",
            roundsIcon: false,
            badgeRed: 0,
            badgeGreen: 0.78,
            badgeBlue: 0,
            badgeOpacity: 0.45
        ),
        MoreProduct(
            id: "imagefit",
            imageName: "imagefit_logo",
            titleKey: "more_product_imagefit",
            descriptionKey: "more_product_imagefit_desc",
            urlString: "https://apps.apple.com/app/id6736737728",
            roundsIcon: true,
            badgeRed: 0.81,
            badgeGreen: 0.22,
            badgeBlue: 0.88,
            badgeOpacity: 0.5
        ),
        MoreProduct(
            id: "musicpal",
            imageName: "musicpal_logo",
            titleKey: "more_product_musicpal",
            descriptionKey: "more_product_musicpal_desc",
            urlString: "https://apps.apple.com/app/id6757587098",
            roundsIcon: false,
            badgeRed: 0.95,
            badgeGreen: 0.38,
            badgeBlue: 0.47,
            badgeOpacity: 0.6
        ),
        MoreProduct(
            id: "deepmusic",
            imageName: "app_icon_primary",
            titleKey: "more_product_deepmusic",
            descriptionKey: "more_product_deepmusic_desc",
            urlString: "https://apps.apple.com/app/id6760999336",
            roundsIcon: false,
            badgeRed: 0.24,
            badgeGreen: 0.54,
            badgeBlue: 0.91,
            badgeOpacity: 0.6
        ),
        MoreProduct(
            id: "musicecho",
            imageName: "musicecho_logo",
            titleKey: "more_product_musicecho",
            descriptionKey: "more_product_musicecho_desc",
            urlString: "https://apps.apple.com/app/id6783590331",
            roundsIcon: true,
            badgeRed: 0.36,
            badgeGreen: 0.12,
            badgeBlue: 0.86,
            badgeOpacity: 0.7
        )
    ]

}

struct MoreAuthorCard: View {
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 15) {
                Image(decorative: "AuthorPortrait").resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white, lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("LeaveStyle")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }

                    HStack {
                        Text("Leave the comfortable style, and leap into the imagination.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Spacer()
                    }
                }
                .padding(.bottom, 5)
            }

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ForEach(MoreSectionCatalog.socialLinks) { link in
                    Button {
                        guard let url = link.url else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Image(decorative: link.imageName).resizable()
                            .scaledToFit()
                            .frame(width: link.imageSize, height: link.imageSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey(link.id)))
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.top, 5)
        }
        .padding()
        .settingsGlassCard(cornerRadius: 16, interactive: true)
    }
}

struct MoreProductCard: View {
    let product: MoreProduct

    var body: some View {
        Button {
            guard let url = product.url else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 16) {
                productIcon

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(LocalizedStringKey(product.titleKey))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(verbatim: " iOS ")
                            .font(.caption)
                            .padding(4)
                            .foregroundStyle(.primary)
                            .background(
                                Color(
                                    red: product.badgeRed,
                                    green: product.badgeGreen,
                                    blue: product.badgeBlue
                                )
                                .opacity(product.badgeOpacity)
                            )
                            .cornerRadius(5)
                    }

                    HStack {
                        Text(LocalizedStringKey(product.descriptionKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Spacer()
                    }
                }
                .padding(.bottom, 5)
            }
            .padding()
            .settingsGlassCard(cornerRadius: 16, interactive: true)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var productIcon: some View {
        if product.roundsIcon {
            baseProductIcon.cornerRadius(10)
        } else {
            baseProductIcon
        }
    }

    private var baseProductIcon: some View {
        Image(decorative: product.imageName)
            .resizable()
            .scaledToFit()
            .frame(width: 50, height: 50)
    }
}
