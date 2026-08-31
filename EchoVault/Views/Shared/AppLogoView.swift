import SwiftUI

struct AppLogoView: View {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 24) {
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

#Preview("App logo") {
    AppLogoView()
        .frame(width: 180, height: 180)
        .padding()
}
