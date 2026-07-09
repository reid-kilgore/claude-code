// M0
// M0's version is a thin stub: an empty-state screen wired to
// AppContainer so the environment-injection path is proven end to end,
// but with no real querying logic (M1 replaces this).
import SwiftUI

struct LibraryView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Podcasts Yet",
                systemImage: "books.vertical",
                description: Text("Search for a podcast or paste an RSS URL to subscribe.")
            )
            .navigationTitle("Library")
        }
    }
}
