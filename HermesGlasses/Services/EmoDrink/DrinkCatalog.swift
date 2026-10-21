//
// DrinkCatalog.swift
//
// The drinks the recommender chooses from: a bundled JSON of public Asahi
// Group soft drinks, each tagged by what it is for. Adding a drink is a JSON
// edit; the recommender reads only the fields here. Foundation only;
// tested in tests/emodrink-catalog.
//

import Foundation

enum DrinkFunction: String, Codable, CaseIterable, Equatable {
    case hydrate, calm, energise, recover, refresh

    var label: String {
        switch self {
        case .hydrate: return "Hydrate"
        case .calm: return "Calm"
        case .energise: return "Energise"
        case .recover: return "Recover"
        case .refresh: return "Refresh"
        }
    }
}

enum SugarLevel: String, Codable, Equatable {
    case none, low, regular
}

enum ServedTemperature: String, Codable, Equatable {
    case cold, hot, either
}

struct Drink: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let nameJa: String
    let kind: String
    /// In priority order: the first function is what the drink is mostly for.
    let functions: [DrinkFunction]
    let caffeineMg: Int
    let sugar: SugarLevel
    let served: ServedTemperature
    let emoji: String?
    let colorHex: String?
    /// Short spoken forms (Japanese, katakana, English) the matcher accepts.
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, kind, functions, sugar, served, emoji, aliases
        case nameJa = "name_ja"
        case caffeineMg = "caffeine_mg"
        case colorHex = "color"
    }

    init(id: String, name: String, nameJa: String, kind: String, functions: [DrinkFunction],
         caffeineMg: Int, sugar: SugarLevel, served: ServedTemperature,
         emoji: String? = nil, colorHex: String? = nil, aliases: [String] = []) {
        self.id = id; self.name = name; self.nameJa = nameJa; self.kind = kind
        self.functions = functions; self.caffeineMg = caffeineMg; self.sugar = sugar
        self.served = served; self.emoji = emoji; self.colorHex = colorHex; self.aliases = aliases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        nameJa = try c.decode(String.self, forKey: .nameJa)
        kind = try c.decode(String.self, forKey: .kind)
        functions = try c.decode([DrinkFunction].self, forKey: .functions)
        caffeineMg = try c.decode(Int.self, forKey: .caffeineMg)
        sugar = try c.decode(SugarLevel.self, forKey: .sugar)
        served = try c.decode(ServedTemperature.self, forKey: .served)
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }

    /// The drink's own colour, else its first function's colour.
    var displayColorHex: String {
        if let colorHex { return colorHex }
        switch functions.first {
        case .calm: return "#7FB6FF"
        case .energise: return "#FFB36B"
        case .hydrate, .none: return "#4FE3C1"
        case .recover: return "#8A7DFF"
        case .refresh: return "#8DEB7A"
        }
    }

    var displayEmoji: String {
        if let emoji { return emoji }
        switch kind {
        case let k where k.contains("tea"): return "🍵"
        case let k where k.contains("coffee"): return "☕"
        case "water": return "💧"
        default: return "🥤"
        }
    }
}

struct DrinkCatalog: Codable, Equatable {
    let drinks: [Drink]

    static let bundledResourceName = "asahi-drinks"
    /// Where the same file lives in the repo, for the swiftc tests.
    static let repoPath = "HermesGlasses/Resources/EmoDrink/asahi-drinks.json"

    enum CatalogError: LocalizedError, Equatable {
        case empty
        case duplicateID(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "The drink catalogue is empty."
            case .duplicateID(let id): return "Duplicate drink id: \(id)"
            }
        }
    }

    static func decode(_ data: Data) throws -> DrinkCatalog {
        let catalog = try JSONDecoder().decode(DrinkCatalog.self, from: data)
        guard !catalog.drinks.isEmpty else { throw CatalogError.empty }
        var seen = Set<String>()
        for drink in catalog.drinks {
            guard seen.insert(drink.id).inserted else { throw CatalogError.duplicateID(drink.id) }
        }
        return catalog
    }

    /// The copy shipped in the app bundle. Nil when the resource is missing
    /// or invalid; the caller decides how loudly to fail.
    static func bundled(bundle: Bundle = .main) -> DrinkCatalog? {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    func drink(id: String) -> Drink? { drinks.first { $0.id == id } }

    /// The drinks for these ids, in the given order; unknown ids are skipped.
    func drinks(ids: [String]) -> [Drink] { ids.compactMap { drink(id: $0) } }
}
