//
// DrinkNameMatcher.swift
//
// Turns a spoken list ("Wilkinson, Calpis Soda and 十六茶") into catalogue
// drinks. Keys are a drink's name, nameJa and aliases, normalised: NFKC,
// lowercased, whitespace, ASCII hyphens and the middle dot removed. Order:
// an exact key; else the longest key contained in the phrase; else, for a
// phrase of 3+ characters, the one drink whose keys contain it. Foundation
// only; tested in tests/showcase-machines.
//

import Foundation

enum DrinkNameMatcher {
    /// Shortest key or phrase the containing rules will act on.
    private static let minKeyLength = 2
    private static let minPhraseInKeyLength = 3

    static func split(_ utterance: String) -> [String] {
        splitSegments(utterance).flatMap { splitOnTo($0) }
    }

    /// Splits on the unambiguous separators only (not 「と」).
    private static func splitSegments(_ utterance: String) -> [String] {
        var text = utterance
        text = text.replacingOccurrences(of: " and ", with: "\n", options: .caseInsensitive)
        for separator in [",", "、", "・"] {
            text = text.replacingOccurrences(of: separator, with: "\n")
        }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func normalise(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "-" && $0 != "・"
        })
    }

    static func match(_ phrase: String, in catalog: DrinkCatalog) -> Drink? {
        let p = normalise(phrase)
        guard p.count >= minKeyLength else { return nil }
        let keyed = catalog.drinks.map { drink in
            (drink, Set(([drink.name, drink.nameJa] + drink.aliases).map(normalise).filter { !$0.isEmpty }))
        }

        if let exact = keyed.first(where: { $0.1.contains(p) }) { return exact.0 }

        var best: (drink: Drink, length: Int)?
        for (drink, keys) in keyed {
            for key in keys where key.count >= minKeyLength && p.contains(key) {
                if best == nil || key.count > best!.length { best = (drink, key.count) }
            }
        }
        if let best { return best.drink }

        guard p.count >= minPhraseInKeyLength else { return nil }
        let holders = keyed.filter { $0.1.contains { $0.contains(p) } }
        return holders.count == 1 ? holders[0].0 : nil
    }

    /// Splits a segment on 「と」, except where the 「と」 sits inside a
    /// catalogue key (ほっと十六茶), so those names survive.
    private static func splitOnTo(_ segment: String, protecting protected: [String] = []) -> [String] {
        let chars = Array(segment)
        guard chars.contains("と") else {
            let t = segment.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? [] : [t]
        }
        var norm: [Character] = []
        var origin: [Int] = []
        for (i, ch) in chars.enumerated() {
            for n in normalise(String(ch)) { norm.append(n); origin.append(i) }
        }
        var keep = Set<Int>()
        for key in protected {
            let k = Array(key)
            guard k.count <= norm.count else { continue }
            for start in 0...(norm.count - k.count) where Array(norm[start..<start + k.count]) == k {
                for j in start..<start + k.count { keep.insert(origin[j]) }
            }
        }
        var parts: [String] = []
        var current = ""
        for (i, ch) in chars.enumerated() {
            if ch == "と" && !keep.contains(i) { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Matches each part of the list; drinks are de-duplicated, order kept.
    static func matchAll(_ utterance: String, in catalog: DrinkCatalog) -> (matched: [Drink], unmatched: [String]) {
        var matched: [Drink] = []
        var unmatched: [String] = []
        let protectedKeys = catalog.drinks
            .flatMap { [$0.name, $0.nameJa] + $0.aliases }
            .map(normalise).filter { $0.contains("と") }
        let parts = splitSegments(utterance).flatMap { splitOnTo($0, protecting: protectedKeys) }
        for part in parts {
            if let drink = match(part, in: catalog) {
                if !matched.contains(where: { $0.id == drink.id }) { matched.append(drink) }
            } else {
                unmatched.append(part)
            }
        }
        return (matched, unmatched)
    }
}
