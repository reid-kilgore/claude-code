// M1
// Podcast search screen (spec §6.3): debounced iTunes search, per-row
// Subscribe, and an "Add by RSS URL" affordance.
import SwiftUI
import LingoPodKit

struct SearchView: View {
    @Environment(AppContainer.self) private var container

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var subscribedResultIDs: Set<String> = []
    @State private var subscribingResultIDs: Set<String> = []

    @State private var feedURLText = ""
    @State private var addByURLError: String?
    @State private var isAddingByURL = false

    var body: some View {
        List {
            Section("Add by RSS URL") {
                HStack {
                    TextField("https://example.com/feed.xml", text: $feedURLText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Add") {
                        Task { await addByURL() }
                    }
                    .disabled(feedURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingByURL)
                }
                if let addByURLError {
                    Text(addByURLError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let searchError {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(searchError)
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await runSearch() }
                        }
                    }
                }
            } else if !trimmedQuery.isEmpty, results.isEmpty {
                Text("No podcasts found for '\(trimmedQuery)'")
                    .foregroundStyle(.secondary)
            } else if !results.isEmpty {
                Section("Results") {
                    ForEach(results) { result in
                        resultRow(result)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Search podcasts")
        .task(id: query) {
            await debouncedSearch()
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resultRow(_ result: PodcastSearchResult) -> some View {
        HStack {
            AsyncImage(url: result.artworkURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Image(systemName: "waveform")
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading) {
                Text(result.title).font(.body)
                if let author = result.author {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if subscribedResultIDs.contains(result.id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if subscribingResultIDs.contains(result.id) {
                ProgressView()
            } else {
                Button("Subscribe") {
                    Task { await subscribe(result) }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Debounce: cancels/replaces on every `query` change via `.task(id:)`
    /// (an equally-valid alternative to a manually-managed `Task` per spec
    /// §6.3), waits 400ms, then checks cancellation before searching.
    private func debouncedSearch() async {
        guard !trimmedQuery.isEmpty else {
            results = []
            searchError = nil
            isSearching = false
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        await runSearch()
    }

    private func runSearch() async {
        guard !trimmedQuery.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await container.catalogService.search(term: trimmedQuery)
        } catch {
            results = []
            searchError = "Search failed. Try again."
        }
    }

    private func subscribe(_ result: PodcastSearchResult) async {
        subscribingResultIDs.insert(result.id)
        defer { subscribingResultIDs.remove(result.id) }
        do {
            _ = try await container.catalogService.subscribe(feedURL: result.feedURL)
            subscribedResultIDs.insert(result.id)
        } catch {
            // Row simply reverts to a re-tappable "Subscribe" button; no
            // per-row inline error surfaced in v1.
        }
    }

    private func addByURL() async {
        addByURLError = nil
        let trimmed = feedURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            addByURLError = "Enter a valid http(s) feed URL."
            return
        }
        isAddingByURL = true
        defer { isAddingByURL = false }
        do {
            _ = try await container.catalogService.subscribe(feedURL: url)
            feedURLText = ""
        } catch {
            addByURLError = "Couldn't subscribe. Check the URL and try again."
        }
    }
}
