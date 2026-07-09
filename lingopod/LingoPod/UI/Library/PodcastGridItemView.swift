// M1
// Small presentational subview for `LibraryView`'s grid (spec §6.4).
// Episode-count/unread badges are deliberately cut from v1 — there is no
// "read/unread" concept anywhere in architecture §4's model.
import SwiftUI
import LingoPodKit

struct PodcastGridItemView: View {
    let podcast: Podcast

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: podcast.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Image(systemName: "waveform")
                        .imageScale(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(podcast.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
    }
}
