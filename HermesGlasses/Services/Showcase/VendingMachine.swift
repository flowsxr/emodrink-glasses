//
// VendingMachine.swift
//
// The machines Taka saves for the showcase and the drinks each holds. A
// machine lists catalogue drink ids plus any generic "custom" drinks he named
// that the catalogue does not know. Foundation only; tested in
// tests/showcase-machines.
//

import Foundation

/// A drink the catalogue does not know: shown as a generic card.
struct CustomDrink: Codable, Equatable, Identifiable {
    let id: String
    var name: String

    init(id: String = "custom-" + UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

struct VendingMachine: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var drinkIDs: [String]
    var customDrinks: [CustomDrink]
    var navigationEnabled: Bool
    var distanceMeters: Int

    /// The built-in machine: nine flagships covering every function.
    static let sample = VendingMachine(
        id: "sample",
        name: "Asahi lobby",
        drinkIDs: ["wilkinson-tansan", "calpis-water", "juroku-cha", "rokujo-mugicha",
                   "wonda-morning-shot", "super-h2o", "mitsuya-cider", "oishii-mizu", "dodekamin"],
        customDrinks: [],
        navigationEnabled: true,
        distanceMeters: 40)
}

/// Saves machines as `machines.json` in a directory, written atomically.
final class MachineStore {
    private let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("machines.json")
    }

    /// The saved machines, or `[.sample]` when the file is missing or unreadable.
    func load() -> [VendingMachine] {
        guard let data = try? Data(contentsOf: fileURL),
              let machines = try? JSONDecoder().decode([VendingMachine].self, from: data) else {
            return [.sample]
        }
        return machines
    }

    func save(_ machines: [VendingMachine]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(machines)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
