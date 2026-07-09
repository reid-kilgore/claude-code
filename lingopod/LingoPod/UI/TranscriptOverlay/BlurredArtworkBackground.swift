// M4
// Blurred artwork + contrast gradient background layer
// (docs/specs/M4-overlay-ui.md §3, layer 1). Falls back to a flat
// dark-mode-appropriate color if artwork fails to load.
import SwiftUI

struct BlurredArtworkBackground: View {
    let artworkURL: URL?

    var body: some View {
        ZStack {
            AsyncImage(url: artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Color(.systemGray6)
                }
            }
            .ignoresSafeArea()
            .blur(radius: 50)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.35), .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
}
