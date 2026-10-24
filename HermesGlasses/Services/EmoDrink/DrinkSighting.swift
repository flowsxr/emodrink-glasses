//
// DrinkSighting.swift
//
// Drink mode's vision question and what to do with the answer. The model
// says what it sees (a vending machine, some drinks, or nothing) and names
// every drink it can read; the names are matched to the catalogue with
// DrinkNameMatcher. Drinks it reads but the catalogue lacks are kept by
// name, so the wearer hears them. Foundation only; tested in
// tests/emodrink-sighting.
//

import Foundation

enum DrinkSighting {
    enum Scene: String, Equatable { case machine, drinks, none }

    struct Reading: Equatable {
        let scene: Scene
        /// As read off the labels, most prominent first, each once.
        let drinks: [String]
    }

    /// What drink mode offers for a reading.
    enum Plan: Equatable {
        /// Nothing worth a moment.
        case none
        /// A machine or several drinks. `pool` is what the choices come
        /// from: the seen catalogue drinks when two or more, else empty for
        /// the whole catalogue. `seen` and `unknown` are what was read.
        case offer(pool: [Drink], seen: [Drink], unknown: [String])
        /// Exactly one drink in view (not a machine): comment on it, then
        /// suggest from the whole catalogue. `known` is nil when the
        /// catalogue lacks it; `name` is how to say it either way.
        case single(known: Drink?, name: String)
    }

    static let maxNames = 12

    static let systemPrompt = "You read images for a drinks assistant on smart glasses. Reply with JSON only, no other text."
    /// A machine on a screen counts: the owner tests with a photo of one.
    static let userText = """
    Look at this image and reply with JSON only: {"scene": "machine" | "drinks" | "none", "drinks": [names]}. \
    scene is "machine" for a drinks vending machine (a real one, or a photo or video of one on a screen, poster or page); \
    "drinks" when there is no machine but one or more drink bottles, cans or cartons are visible; otherwise "none". \
    drinks lists each drink whose brand and product you can read on its label, as printed (for example "Calpis Water", \
    "ワンダ モーニングショット"), most prominent first, each once, at most \(maxNames). Leave out drinks you cannot read.
    """

    /// Reads the JSON reply (a ```json fence is fine). A reply with no JSON
    /// falls back to the old YES/NO reading: YES is a machine.
    static func parse(_ reply: String) -> Reading {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(reply[start...end].utf8)) as? [String: Any]
        else {
            return Reading(scene: VendingMachineDetector.isYes(reply) ? .machine : .none, drinks: [])
        }
        var names: [String] = []
        var keys = Set<String>()
        for raw in object["drinks"] as? [Any] ?? [] {
            guard let name = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  keys.insert(DrinkNameMatcher.normalise(name)).inserted else { continue }
            names.append(name)
            if names.count == maxNames { break }
        }
        var scene = Scene(rawValue: (object["scene"] as? String ?? "").lowercased()) ?? .none
        // Named drinks outrank a scene that says there are none.
        if scene == .none, !names.isEmpty { scene = .drinks }
        return Reading(scene: scene, drinks: names)
    }

    static func plan(_ reading: Reading, catalog: DrinkCatalog) -> Plan {
        var seen: [Drink] = []
        var unknown: [String] = []
        for name in reading.drinks {
            if let drink = DrinkNameMatcher.match(name, in: catalog) {
                if !seen.contains(drink) { seen.append(drink) }
            } else {
                unknown.append(name)
            }
        }
        if reading.scene == .none { return .none }
        if reading.scene == .drinks, seen.count + unknown.count == 1 {
            return .single(known: seen.first, name: seen.first?.name ?? unknown[0])
        }
        return .offer(pool: seen.count >= 2 ? seen : [], seen: seen, unknown: unknown)
    }
}
