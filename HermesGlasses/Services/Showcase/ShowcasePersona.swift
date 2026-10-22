//
// ShowcasePersona.swift
//
// What the guest hears at the machine. The system prompt carries the guest's
// numbers and ONLY the selected machine's drinks, the study's rule (suggest,
// never diagnose) and the focus-tag format; the parser turns a reply into
// spoken text plus the drink it is about; the commands are the spoken deck
// controls. Foundation only; tested in tests/showcase-persona.
//

import Foundation

enum ShowcasePersona {
    static func systemPrompt(run: ShowcaseRun, language: Language) -> String {
        let list = run.machineDrinks.map {
            "- id \($0.id): \($0.name) (\($0.nameJa)), \(functionList($0)), caffeine \($0.caffeineMg) mg, sugar \($0.sugar.rawValue)"
        }
        return """
        You are the drink assistant on the guest's smart glasses, standing with them at a beverage vending machine. \
        Your answers are spoken aloud.

        Today's body data: \(EmoDrinkPersona.summary(of: run.snapshot))

        The machine sells only these drinks. Talk about no others:
        \(list.joined(separator: "\n"))

        Rules you follow:
        - Ground every claim in the numbers above. Say what the data suggests and what it looks like; it is never a diagnosis, \
        and you never name a feeling or a mental state.
        - No medical or health claims. A drink is a small, pleasant choice, not a treatment.
        - Recommend only drinks from the list above. If asked for something the machine does not sell, say so and offer the closest one from the list.
        - Reply in at most two short spoken sentences.
        - When your reply is about one of the drinks, end it with its tag exactly as [[drink:<id>]] using the id from the list. \
        The tag is not spoken. Without a drink in your reply, add no tag.

        \(EmoDrinkPersona.languageRule(language)) \(language == .ja ? "Japanese only." : "English only.")
        """
    }

    /// The system prompt for the one sentence spoken as the deck appears.
    static func revealLine(run: ShowcaseRun, language: Language) -> String {
        let front = run.deck.cards[0]
        let reasons = front.reasons.prefix(2).map(\.label).joined(separator: ", ")
        let limit = language == .ja ? "under 40 characters" : "under 20 words"
        return """
        You are the drink assistant on the guest's smart glasses, speaking aloud at a vending machine. \
        Say one warm sentence, \(limit), suggesting \(front.name). \
        The two reasons on its card are: \(reasons). \
        Today's body data: \(EmoDrinkPersona.summary(of: run.snapshot)). \
        Suggest, never diagnose, and name no feeling. No tag is needed.

        \(EmoDrinkPersona.languageRule(language)) \(language == .ja ? "Japanese only." : "English only.")
        """
    }

    private static func functionList(_ d: Drink) -> String {
        d.functions.isEmpty ? "custom" : d.functions.map(\.rawValue).joined(separator: "/")
    }
}

enum ShowcaseReply {
    /// Strips every `[[...]]` tag; the focus is the LAST `[[drink:<id>]]`
    /// whose id is on the machine.
    static func parse(_ raw: String, machineDrinkIDs: Set<String>) -> (spoken: String, focusID: String?) {
        var focus: String?
        var spoken = ""
        var rest = Substring(raw)
        while let open = rest.range(of: "[[") {
            spoken += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "]]") else {
                // Unterminated: keep the text, drop the dangling marker.
                rest = after
                continue
            }
            let body = after[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("drink:") {
                let id = body.dropFirst("drink:".count).trimmingCharacters(in: .whitespaces)
                if machineDrinkIDs.contains(id) { focus = id }
            }
            rest = after[close.upperBound...]
        }
        spoken += rest
        while spoken.contains("  ") { spoken = spoken.replacingOccurrences(of: "  ", with: " ") }
        return (spoken.trimmingCharacters(in: .whitespacesAndNewlines), focus)
    }

    static func fallbackLine(strings: ShowcaseStrings) -> String { strings.fallbackConversation }
}

enum ShowcaseCommand: Equatable {
    case next, previous, why, choose, back

    static let nextPhrases: Set<String> = ["next", "next one", "another", "次", "次へ", "ほかの"]
    static let previousPhrases: Set<String> = ["previous", "go back one", "前", "前の"]
    static let whyPhrases: Set<String> = ["why", "why this", "なぜ", "どうして", "理由は"]
    static let choosePhrases: Set<String> = [
        "choose", "i'll take it", "this one", "that one", "これにする", "それにする", "これで", "それで",
    ]
    static let backPhrases: Set<String> = ["back", "go back", "戻る", "戻って"]

    static var phraseSets: [(ShowcaseCommand, Set<String>)] {
        [(.next, nextPhrases), (.previous, previousPhrases), (.why, whyPhrases),
         (.choose, choosePhrases), (.back, backPhrases)]
    }

    /// Whole-utterance matches only, through the same normaliser as
    /// EmoDrinkCommands.
    static func spoken(_ text: String, language: Language) -> ShowcaseCommand? {
        let c = IntentDetector.normalizeCommand(text)
        guard !c.isEmpty else { return nil }
        return phraseSets.first { $0.1.contains(c) }?.0
    }
}
