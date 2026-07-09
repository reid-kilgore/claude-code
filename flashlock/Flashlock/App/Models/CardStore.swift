import FlashlockCore
import Foundation

/// Owns all deck/card/review-log data, persisted as JSON files in the App
/// Group container. Loaded ONLY by the main app: the monitor/shield extensions
/// run under tiny memory ceilings and must never touch card data
/// (docs/02-architecture.md §3).
@MainActor
final class CardStore: ObservableObject {
    @Published private(set) var decks: [Deck] = []
    @Published private(set) var cards: [Card] = []
    @Published private(set) var reviewLog: [ReviewLog] = []

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let fileManager = FileManager.default
        // Fall back to Documents when the App Group container is unavailable
        // (e.g. SwiftUI previews without the entitlement).
        let base = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.suiteName
        ) ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("CardData", isDirectory: true)

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        if decks.isEmpty {
            seedStarterDeck()
        }
    }

    // MARK: - Queries

    func cards(in deck: Deck) -> [Card] {
        cards.filter { $0.deckID == deck.id }
    }

    func deck(withID id: UUID) -> Deck? {
        decks.first { $0.id == id }
    }

    func dueCount(in deck: Deck, at date: Date = Date()) -> Int {
        cards(in: deck).filter { $0.phase != .new && $0.isDue(at: date) }.count
    }

    /// Distinct cards first reviewed today, for ReviewQueue's daily new-card
    /// allowance.
    func newCardsIntroducedToday(at date: Date = Date()) -> Int {
        let calendar = Calendar.current
        let ids = reviewLog
            .filter { $0.phaseBefore == .new && calendar.isDate($0.reviewedAt, inSameDayAs: date) }
            .map(\.cardID)
        return Set(ids).count
    }

    // MARK: - Review

    /// Stores the FSRS-updated card and appends its review log entry.
    func apply(_ reviewed: Card, log: ReviewLog) {
        if let index = cards.firstIndex(where: { $0.id == reviewed.id }) {
            cards[index] = reviewed
        }
        reviewLog.append(log)
        save()
    }

    // MARK: - CRUD

    @discardableResult
    func addDeck(named name: String) -> Deck {
        let deck = Deck(name: name)
        decks.append(deck)
        save()
        return deck
    }

    func update(_ deck: Deck) {
        if let index = decks.firstIndex(where: { $0.id == deck.id }) {
            decks[index] = deck
            save()
        }
    }

    func delete(_ deck: Deck) {
        decks.removeAll { $0.id == deck.id }
        cards.removeAll { $0.deckID == deck.id }
        save()
    }

    /// Inserts a new card or replaces the existing one with the same id.
    func upsert(_ card: Card) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
        save()
    }

    func delete(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        save()
    }

    // MARK: - Import / sync

    /// Imports (or re-imports) a deck file: merges by note guid into the
    /// existing deck with the same name (case-insensitive), creating the deck
    /// first if needed. Idempotent — re-importing the same file reports
    /// everything unchanged — and never deletes cards (DeckMerger semantics),
    /// so this is also the sync path for updated Anki exports.
    @discardableResult
    func applyImport(_ file: DeckImportFile) -> DeckMerger.Result {
        let deck: Deck
        if let existing = decks.first(where: {
            $0.name.caseInsensitiveCompare(file.name) == .orderedSame
        }) {
            deck = existing
        } else {
            deck = Deck(name: file.name)
            decks.append(deck)
        }

        let result = DeckMerger.merge(file, into: deck.id, existingCards: cards(in: deck))
        // result.cards is the deck's complete post-merge card list: replace
        // this deck's cards wholesale, leaving other decks' cards untouched.
        cards.removeAll { $0.deckID == deck.id }
        cards.append(contentsOf: result.cards)
        save()
        return result
    }

    // MARK: - Persistence

    private func load() {
        decks = read("decks.json") ?? []
        cards = read("cards.json") ?? []
        reviewLog = read("reviewlog.json") ?? []
    }

    private func save() {
        write(decks, to: "decks.json")
        write(cards, to: "cards.json")
        write(reviewLog, to: "reviewlog.json")
    }

    private func read<T: Decodable>(_ filename: String) -> T? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to filename: String) {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Seed data

    /// Starter content so the gate is usable on first launch, mixing all three
    /// answer modes to exercise the full question UI.
    private func seedStarterDeck() {
        let deck = Deck(name: "World Capitals")
        let facts: [(front: String, back: String, alt: [String], mode: AnswerMode)] = [
            ("Capital of France", "Paris", [], .multipleChoice),
            ("Capital of Japan", "Tokyo", [], .multipleChoice),
            ("Capital of Australia", "Canberra", [], .multipleChoice),
            ("Capital of Canada", "Ottawa", [], .multipleChoice),
            ("Capital of Brazil", "Brasília", ["Brasilia"], .typed),
            ("Capital of Egypt", "Cairo", [], .multipleChoice),
            ("Capital of Kenya", "Nairobi", [], .multipleChoice),
            ("Capital of India", "New Delhi", ["Delhi"], .typed),
            ("Capital of Germany", "Berlin", [], .multipleChoice),
            ("Capital of Spain", "Madrid", [], .multipleChoice),
            ("Capital of Turkey", "Ankara", [], .selfGraded),
            ("Capital of Argentina", "Buenos Aires", [], .selfGraded),
        ]
        decks = [deck]
        cards = facts.map { fact in
            Card(
                deckID: deck.id,
                front: fact.front,
                back: fact.back,
                alternativeAnswers: fact.alt,
                answerMode: fact.mode
            )
        }
        save()
    }
}
