//
// ShowcaseDirector.swift
//
// The showcase autopilot as pure data: one run is built from a vending
// machine and a guest profile and holds the step list, the timings and the
// stacked deck of drink cards. No SwiftUI, no timers; the view model drives
// it. Everything shown comes only from the selected machine's drinks.
// Foundation only; tested in tests/showcase-director.
//

import Foundation

enum ShowcaseStep: Equatable {
    case idle, navigate, morning, scan, deck
    case chosen(drinkID: String)
}

/// What the deck is drawing. Lives here, not in the SwiftUI file, so the
/// runner suite compiles without SwiftUI.
enum DeckMode: Equatable {
    case reveal, why, chosen
}

enum ShowcaseError: Error, Equatable {
    case emptyMachine
}

enum ShowcaseTiming {
    static let idleRotate: TimeInterval = 8
    static let idleEnd: TimeInterval = 45
    /// The showcase pins the recommender's hour so a demo never depends on the clock.
    static let hour = 9
}

/// The one constant the handover build flips to `.ja`.
enum ShowcaseDefaults {
    static let defaultLanguage: Language = .en
}

struct ShowcaseCard: Equatable {
    let drinkID: String
    let name: String
    let emoji: String
    let colorHex: String
    let tag: String
    let reasons: [ShowcaseReason]
}

struct ShowcaseDeck: Equatable {
    static let maxCards = 3

    /// Front first.
    private(set) var cards: [ShowcaseCard]
    /// Every card the machine holds, so the conversation can bring any of them forward.
    private let pool: [ShowcaseCard]

    init(cards: [ShowcaseCard], pool: [ShowcaseCard]) {
        self.cards = cards
        self.pool = pool
    }

    /// The front card goes to the back.
    mutating func next() {
        guard cards.count > 1 else { return }
        cards.append(cards.removeFirst())
    }

    /// The back card comes to the front.
    mutating func previous() {
        guard cards.count > 1 else { return }
        cards.insert(cards.removeLast(), at: 0)
    }

    /// Moves a drink to the front. False, and no change, when the machine does not hold it.
    @discardableResult
    mutating func bringToFront(drinkID: String) -> Bool {
        if let index = cards.firstIndex(where: { $0.drinkID == drinkID }) {
            cards.insert(cards.remove(at: index), at: 0)
            return true
        }
        guard let card = pool.first(where: { $0.drinkID == drinkID }) else { return false }
        cards.insert(card, at: 0)
        if cards.count > Self.maxCards { cards.removeLast(cards.count - Self.maxCards) }
        return true
    }
}

struct ShowcaseRun {
    static let customColorHex = "#D9D4CC"

    let snapshot: PhysiologySnapshot
    var deck: ShowcaseDeck
    let steps: [ShowcaseStep]
    let machineDrinks: [Drink]

    init(machine: VendingMachine, profile: GuestProfile, catalog: DrinkCatalog,
         language: Language, date: String) throws(ShowcaseError) {
        var drinks = machine.drinkIDs.compactMap { catalog.drink(id: $0) }
        drinks += machine.customDrinks.map {
            Drink(id: $0.id, name: $0.name, nameJa: $0.name, kind: "custom", functions: [],
                  caffeineMg: 0, sugar: .none, served: .either)
        }
        guard !drinks.isEmpty else { throw .emptyMachine }

        let snapshot = profile.snapshot(date: date)
        let strings = ShowcaseStrings(language: language)
        let reasons = strings.reasons(for: snapshot)
        let pool = drinks.map { Self.card(for: $0, language: language, strings: strings, reasons: reasons) }

        // Custom drinks score 0, so they lead only when nothing else exists.
        let rec = DrinkRecommender.recommend(snapshot: snapshot, catalog: DrinkCatalog(drinks: drinks),
                                             hour: ShowcaseTiming.hour, lowSugar: false, language: language)
        let order = rec.map { [$0.pick] + $0.alternates } ?? drinks
        let ids = order.prefix(ShowcaseDeck.maxCards).map(\.id)
        let cards = ids.compactMap { id in pool.first { $0.drinkID == id } }

        self.snapshot = snapshot
        self.machineDrinks = drinks
        self.deck = ShowcaseDeck(cards: cards, pool: pool)
        self.steps = (machine.navigationEnabled ? [.navigate] : []) + [.morning, .scan, .deck]
    }

    func duration(of step: ShowcaseStep) -> TimeInterval {
        switch step {
        case .navigate: return 10
        case .morning: return 12
        case .scan: return 10
        case .idle, .deck, .chosen: return 0
        }
    }

    private static func card(for drink: Drink, language: Language, strings: ShowcaseStrings,
                             reasons: [ShowcaseReason]) -> ShowcaseCard {
        let custom = drink.kind == "custom"
        var tag = ""
        if let function = drink.functions.first {
            tag = strings.tag(for: function)
            if drink.caffeineMg > 30 {
                tag += language == .ja ? " · \(drink.caffeineMg)mg" : " · \(drink.caffeineMg) MG"
            }
        }
        return ShowcaseCard(drinkID: drink.id,
                            name: language == .ja ? drink.nameJa : drink.name,
                            emoji: drink.displayEmoji,
                            colorHex: custom ? customColorHex : drink.displayColorHex,
                            tag: tag,
                            reasons: reasons)
    }
}
