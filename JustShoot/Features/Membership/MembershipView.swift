import StoreKit
import SwiftUI

struct MembershipView: View {
    @Environment(MembershipStore.self) private var membership
    @Environment(\.purchase) private var purchase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var celebrate = false

    private var accent: Color {
        colorScheme == .dark ? Color(red: 1, green: 0.77, blue: 0.40) : Color(red: 0.49, green: 0.28, blue: 0.07)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 0) {
                        if case .active(let since) = membership.entitlement {
                            MembershipCard(memberSince: since, celebrate: celebrate)
                                .id("card")
                            Text("Thank you for supporting OOO Cam.")
                                .font(.title3.weight(.medium))
                                .multilineTextAlignment(.center)
                                .padding(.top, 28)
                            Spacer(minLength: 36)
                            Button { dismiss() } label: {
                                Text("Done").frame(maxWidth: .infinity, minHeight: 28)
                            }
                            .modifier(MembershipButtonStyle(accent: accent))
                            .accessibilityIdentifier("membership.done")
                        } else if membership.entitlement == .checking {
                            Spacer()
                            ProgressView("Checking membership…")
                            Spacer()
                        } else {
                            MembershipCard(memberSince: nil)
                                .id("card")
                            VStack(alignment: .leading, spacing: 16) {
                                Label("Support the development of OOO Cam.", systemImage: "camera")
                                Label("Restore on any device with the same Apple Account.", systemImage: "arrow.clockwise")
                            }
                            .font(.subheadline)
                            .labelStyle(MembershipDetailLabelStyle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.top, 26)

                            Spacer(minLength: 32)
                            purchaseControls
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: 500)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: membership.entitlement) { previous, current in
                    if case .active = current {
                        if previous == .inactive || previous == .unverified {
                            celebrate = true
                            scroll.scrollTo("card", anchor: .top)
                        }
                    } else {
                        celebrate = false
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .appPageBackground()
        .navigationTitle("Membership")
        .navigationBarTitleDisplayMode(.inline)
        .matchingNavigationBackButton()
        .toolbar(.hidden, for: .tabBar)
        .softScrollEdges()
        .sensoryFeedback(.success, trigger: celebrate) { _, active in active }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { celebrate = false }
        }
        .onChange(of: membership.entitlement, initial: true) { _, entitlement in
            if entitlement == .inactive { Task { await membership.loadProduct() } }
        }
    }

    private func statusText(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private var purchaseControls: some View {
        VStack(spacing: 8) {
            if let notice = membership.notice, notice != .verificationFailed || membership.entitlement != .unverified {
                statusText(notice.title)
            } else if membership.isPurchasePending {
                statusText("Your purchase is pending. Membership activates after approval.")
            }

            if membership.entitlement == .unverified {
                statusText("Your purchase could not be verified. Try restoring purchases.")
            } else {
                purchaseAction
            }
            Button {
                Task { await membership.restorePurchases() }
            } label: {
                if membership.operation == .restoring {
                    ProgressView("Restoring purchases…")
                } else {
                    Text("Restore Purchases")
                }
            }
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 44)
            .disabled(membership.operation != nil)
            .accessibilityIdentifier("membership.restore")
        }
    }

    @ViewBuilder
    private var purchaseAction: some View {
        if !AppStore.canMakePayments {
            Text("In-app purchases are disabled on this device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            switch membership.productState {
            case .idle, .loading:
                ProgressView("Loading price…")
            case .available(let product):
                Button {
                    Task {
                        await membership.purchase { try await purchase($0) }
                    }
                } label: {
                    Group {
                        if membership.operation == .purchasing {
                            ProgressView().tint(colorScheme == .dark ? AppBrand.ink : .white).accessibilityLabel("Purchasing…")
                        } else {
                            Text("Buy for \(product.displayPrice)")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .modifier(MembershipButtonStyle(accent: accent))
                .disabled(membership.operation != nil)
                .accessibilityIdentifier("membership.purchase")
            case .unavailable:
                VStack(spacing: 6) {
                    Text("The price is unavailable right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await membership.loadProduct() }
                    }
                    .disabled(membership.operation != nil)
                }
                .multilineTextAlignment(.center)
            }
        }
    }
}

private struct MembershipButtonStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color

    func body(content: Content) -> some View {
        content
            .font(.headline)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(accent)
            .foregroundStyle(colorScheme == .dark ? AppBrand.ink : .white)
    }
}

private struct MembershipDetailLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 22)
            configuration.title
        }
    }
}

private extension MembershipStore.Notice {
    var title: LocalizedStringResource {
        switch self {
        case .purchaseFailed: "The purchase couldn’t be completed. Please try again."
        case .verificationFailed: "Your purchase could not be verified. Try restoring purchases."
        case .restoreFailed: "Purchases couldn’t be restored. Please try again."
        case .noPurchases: "No lifetime membership purchase was found."
        }
    }
}
