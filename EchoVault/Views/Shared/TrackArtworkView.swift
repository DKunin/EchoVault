import SwiftUI
import UIKit

struct TrackArtworkView: View {
    let artworkURL: URL?
    var cornerRadius: CGFloat = 10
    var symbolSize: CGFloat = 22
    var maxPixelSize = 256

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.9),
                            Color.accentColor.opacity(0.45),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: symbolSize, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: artworkURL) {
            image = nil
            guard let artworkURL else {
                return
            }
            image = await ArtworkImageCache.image(
                at: artworkURL,
                maxPixelSize: maxPixelSize
            )
        }
    }
}

#Preview("Artwork fallback") {
    TrackArtworkView(artworkURL: nil, cornerRadius: 24, symbolSize: 54)
        .frame(width: 240, height: 240)
        .padding()
}
