//
// MachinesView.swift
//
// Taka's saved vending machines and the editor for one. Both are stock
// Lists (swipe to delete) styled with hermesFormStyle() and Hermes rows.
//
// The editor: name; the walk (toggle and a 10 to 200 m distance); the
// drinks (emoji and the name in the run's language, swipe to delete); and
// three ways to add: by voice (MachineDictation, then
// DrinkNameMatcher.matchAll, confirmed in a sheet), from the catalogue
// (searchable across name, nameJa and aliases, multi-select), or a custom
// drink by name. Every change is saved through ShowcaseViewModel.update.
// At least one machine always remains.
//

import SwiftUI

// MARK: - List

struct MachinesView: View {
    @Bindable var vm: ShowcaseViewModel
    @Binding var path: [ShowcaseRoute]

    var body: some View {
        List {
            Section {
                ForEach(vm.machines) { machine in
                    Button { path.append(.machine(machine.id)) } label: {
                        HermesRow(title: machine.name, icon: "cup.and.saucer", subtitle: summary(machine)) {
                            if machine.id == vm.selectedMachine?.id {
                                HermesChip(text: "In use")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .hermesListRow()
                    .deleteDisabled(vm.machines.count <= 1 || vm.running)
                }
                .onDelete { offsets in
                    let ids = offsets.map { vm.machines[$0].id }
                    for id in ids where vm.machines.count > 1 { vm.delete(id) }
                }
            } footer: {
                Text("Start uses the machine marked In use. Swipe to delete; one machine always stays.")
            }

            Section {
                Button {
                    let machine = vm.addMachine()
                    path.append(.machine(machine.id))
                } label: {
                    HermesRow("Add a machine", icon: "plus", showsChevron: false)
                }
                .buttonStyle(.plain)
                .hermesListRow()
            }
        }
        .hermesFormStyle()
        .navigationTitle("Machines")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ machine: VendingMachine) -> String {
        let count = machine.drinkIDs.count + machine.customDrinks.count
        let drinks = count == 1 ? "1 drink" : "\(count) drinks"
        return machine.navigationEnabled ? "\(drinks) · \(machine.distanceMeters) m walk" : drinks
    }
}

// MARK: - Editor

struct MachineEditorView: View {
    @Bindable var vm: ShowcaseViewModel
    let hermesVM: HermesSessionViewModel
    let machineID: String

    @Environment(\.dismiss) private var dismiss
    @State private var customName = ""
    @State private var showVoice = false
    @State private var showList = false
    @State private var confirmDelete = false
    @FocusState private var customFocused: Bool

    private var machine: VendingMachine? { vm.machines.first { $0.id == machineID } }

    var body: some View {
        Group {
            if let machine {
                form(machine)
            } else {
                Text("This machine was deleted.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HermesTheme.groupedCanvas.ignoresSafeArea())
            }
        }
        .navigationTitle(machine?.name.isEmpty == false ? machine!.name : "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if let machine, machine.name.trimmingCharacters(in: .whitespaces).isEmpty {
                edit { $0.name = "Machine" }
            }
        }
        .sheet(isPresented: $showVoice) {
            if let catalog = vm.catalog {
                VoiceAddSheet(catalog: catalog, language: vm.language,
                              existingIDs: Set(machine?.drinkIDs ?? []),
                              existingCustom: Set(machine?.customDrinks.map { $0.name.lowercased() } ?? [])) { ids, customs in
                    add(ids: ids)
                    for name in customs { addCustom(name) }
                }
            }
        }
        .sheet(isPresented: $showList) {
            if let catalog = vm.catalog {
                CatalogPickerSheet(catalog: catalog, language: vm.language,
                                   existingIDs: Set(machine?.drinkIDs ?? [])) { add(ids: $0) }
            }
        }
        .confirmationDialog("Delete \(machine?.name ?? "this machine")?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete machine", role: .destructive) {
                vm.delete(machineID)
                dismiss()
            }
        }
    }

    private func form(_ machine: VendingMachine) -> some View {
        List {
            Section("Name") {
                TextField("Machine name", text: Binding(get: { machine.name }, set: { name in edit { $0.name = name } }))
                    .font(.system(size: 17))
                    .submitLabel(.done)
            }

            Section {
                Toggle(isOn: Binding(get: { machine.navigationEnabled },
                                     set: { on in edit { $0.navigationEnabled = on } })) {
                    HermesRow("Walk to the machine", icon: "figure.walk", showsChevron: false)
                }
                .padding(.trailing, 16)
                .hermesListRow()
                Stepper(value: Binding(get: { machine.distanceMeters },
                                       set: { m in edit { $0.distanceMeters = m } }),
                        in: 10...200, step: 10) {
                    HermesRow("Distance", icon: "ruler", value: "\(machine.distanceMeters) m", showsChevron: false)
                }
                .padding(.trailing, 16)
                .hermesListRow()
                .disabled(!machine.navigationEnabled)
            } header: {
                Text("Navigation")
            } footer: {
                Text("When on, the run opens with the walk to the machine.")
            }

            drinksSection(machine)
            addSection

            Section {
                if machine.id != vm.selectedMachine?.id {
                    Button { vm.selectedMachineID = machine.id } label: {
                        HermesRow("Use for Start", icon: "checkmark.circle", showsChevron: false)
                    }
                    .buttonStyle(.plain)
                    .hermesListRow()
                    .disabled(vm.running)
                }
                if vm.machines.count > 1 {
                    Button { confirmDelete = true } label: {
                        HStack {
                            Spacer()
                            Text("Delete machine")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(HermesTheme.destructive)
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.running)
                }
            } footer: {
                if vm.machines.count <= 1 { Text("The last machine cannot be deleted.") }
            }
        }
        .hermesFormStyle()
    }

    // MARK: Drinks

    private func drinksSection(_ machine: VendingMachine) -> some View {
        Section {
            if machine.drinkIDs.isEmpty && machine.customDrinks.isEmpty {
                Text("No drinks yet. Add them below.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            ForEach(machine.drinkIDs, id: \.self) { id in
                drinkRow(id: id)
                    .hermesListRow()
            }
            .onDelete { offsets in edit { $0.drinkIDs.remove(atOffsets: offsets) } }
            .onMove { from, to in edit { $0.drinkIDs.move(fromOffsets: from, toOffset: to) } }

            ForEach(machine.customDrinks) { custom in
                DrinkLine(emoji: "🥤", name: custom.name, detail: "Custom drink · generic card")
                    .hermesListRow()
            }
            .onDelete { offsets in edit { $0.customDrinks.remove(atOffsets: offsets) } }
        } header: {
            Text("Drinks (\(machine.drinkIDs.count + machine.customDrinks.count))")
        } footer: {
            Text("Swipe a drink to remove it. Names show in the run's language.")
        }
    }

    @ViewBuilder
    private func drinkRow(id: String) -> some View {
        if let drink = vm.catalog?.drink(id: id) {
            DrinkLine(emoji: drink.displayEmoji, name: drinkName(drink, vm.language),
                      detail: drinkName(drink, vm.language.other))
        } else {
            DrinkLine(emoji: "❔", name: id, detail: "Not in this build's catalogue")
        }
    }

    // MARK: Add

    private var dictationBlockedReason: String? {
        if vm.catalog == nil { return "The catalogue is missing from this build." }
        if vm.running { return "Not during a run: the run is listening." }
        if hermesVM.connectionState != .disconnected { return "The voice session has the mic. Stop live drink mode first." }
        return nil
    }

    private var addSection: some View {
        Section {
            Button { showVoice = true } label: {
                HermesRow("Add by voice", icon: "mic",
                          subtitle: dictationBlockedReason ?? "Read the drinks aloud in \(vm.language == .ja ? "Japanese" : "English")")
            }
            .buttonStyle(.plain)
            .hermesListRow()
            .disabled(dictationBlockedReason != nil)
            .opacity(dictationBlockedReason != nil ? 0.5 : 1)

            Button { showList = true } label: {
                HermesRow("Add from list", icon: "list.bullet", subtitle: "Search the catalogue")
            }
            .buttonStyle(.plain)
            .hermesListRow()
            .disabled(vm.catalog == nil)

            HStack(spacing: 12) {
                HermesIconTile(systemName: "plus")
                TextField("Add custom drink", text: $customName)
                    .font(.system(size: 17))
                    .focused($customFocused)
                    .submitLabel(.done)
                    .onSubmit(commitCustom)
                Button("Add", action: commitCustom)
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(.borderless)
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .hermesListRow()
        } header: {
            Text("Add drinks")
        } footer: {
            Text("A custom drink is shown with a generic card.")
        }
    }

    private func commitCustom() {
        addCustom(customName)
        customName = ""
    }

    private func add(ids: [String]) {
        edit { machine in
            for id in ids where !machine.drinkIDs.contains(id) { machine.drinkIDs.append(id) }
        }
    }

    private func addCustom(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        edit { machine in
            guard !machine.customDrinks.contains(where: { $0.name.lowercased() == name.lowercased() }) else { return }
            machine.customDrinks.append(CustomDrink(name: name))
        }
    }

    private func edit(_ change: (inout VendingMachine) -> Void) {
        guard var machine else { return }
        change(&machine)
        vm.update(machine)
    }
}

// MARK: - Shared rows

func drinkName(_ drink: Drink, _ language: Language) -> String {
    language == .ja ? drink.nameJa : drink.name
}

/// Emoji, name, a small second line.
private struct DrinkLine: View {
    let emoji: String
    let name: String
    let detail: String?
    var selected: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji)
                .font(.system(size: 18))
                .frame(width: 29, height: 29)
                .background(HermesTheme.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 17)).kerning(-0.43).lineLimit(1)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(selected ? AnyShapeStyle(HermesTheme.accent) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

private extension View {
    /// A Hermes row owns its padding; the List cell adds none.
    func hermesListRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(HermesTheme.card)
    }
}

// MARK: - Add from list

private struct CatalogPickerSheet: View {
    let catalog: DrinkCatalog
    let language: Language
    let existingIDs: Set<String>
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: [String] = []

    private var results: [Drink] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return catalog.drinks }
        let folded = DrinkNameMatcher.normalise(q)
        return catalog.drinks.filter { drink in
            ([drink.name, drink.nameJa] + drink.aliases).contains { key in
                key.localizedCaseInsensitiveContains(q) || DrinkNameMatcher.normalise(key).contains(folded)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    Text("No drink matches \u{201C}\(query)\u{201D}. Add it as a custom drink instead.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                ForEach(results) { drink in
                    let already = existingIDs.contains(drink.id)
                    Button { toggle(drink.id) } label: {
                        DrinkLine(emoji: drink.displayEmoji, name: drinkName(drink, language),
                                  detail: already ? "Already on this machine" : drinkName(drink, language.other),
                                  selected: already || picked.contains(drink.id))
                    }
                    .buttonStyle(.plain)
                    .disabled(already)
                    .opacity(already ? 0.55 : 1)
                    .hermesListRow()
                }
            }
            .hermesFormStyle()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name, 日本語 or a short form")
            .navigationTitle("Add from list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Add" : "Add \(picked.count)") {
                        onAdd(picked)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(picked.isEmpty)
                }
            }
        }
        .tint(HermesTheme.accent)
    }

    private func toggle(_ id: String) {
        if let index = picked.firstIndex(of: id) { picked.remove(at: index) } else { picked.append(id) }
    }
}

// MARK: - Add by voice

private struct VoiceAddSheet: View {
    let catalog: DrinkCatalog
    let language: Language
    let existingIDs: Set<String>
    let existingCustom: Set<String>
    /// Catalogue ids to add, then custom names to add.
    let onAdd: ([String], [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dictation = MachineDictation()
    @State private var matched: [Drink] = []
    @State private var unmatched: [String] = []
    @State private var included: Set<String> = []
    @State private var customs: [String] = []
    @State private var heard: String?
    @State private var errorText: String?
    @State private var listenTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                listenSection
                if heard != nil { resultSections }
            }
            .hermesFormStyle()
            .navigationTitle("Add by voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(addCount == 0 ? "Add" : "Add \(addCount)") {
                        onAdd(matched.map(\.id).filter { included.contains($0) }, customs)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(addCount == 0)
                }
            }
        }
        .tint(HermesTheme.accent)
        .onAppear(perform: listen)
        .onDisappear {
            listenTask?.cancel()
            dictation.cancel()
        }
    }

    private var addCount: Int { included.count + customs.count }

    private var listening: Bool { dictation.phase != .idle }

    private var listenSection: some View {
        Section {
            VStack(spacing: 14) {
                Button {
                    if dictation.phase == .listening { dictation.finishNow() } else if !listening { listen() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(listening ? HermesTheme.accent : HermesTheme.accent.opacity(0.12))
                            .frame(width: 76, height: 76)
                        if dictation.phase == .starting || dictation.phase == .finishing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: listening ? "stop.fill" : "mic.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(listening ? .white : HermesTheme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(listening ? "Stop listening" : "Listen")

                Text(prompt)
                    .font(.system(size: 15, weight: .semibold))
                    .multilineTextAlignment(.center)
                if !dictation.transcript.isEmpty || heard != nil {
                    Text(listening ? dictation.transcript : (heard ?? ""))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorText {
                    Text(errorText)
                        .font(.system(size: 13))
                        .foregroundStyle(HermesTheme.destructive)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 16)
            .hermesListRow()
        } footer: {
            Text("Pause briefly between drinks. Listening stops after 2 s of quiet.")
        }
    }

    private var prompt: String {
        switch dictation.phase {
        case .starting: return "Starting the mic…"
        case .listening: return "Listening in \(language == .ja ? "Japanese" : "English")… read the drinks"
        case .finishing: return "Matching…"
        case .idle: return heard == nil ? "Tap the mic and read the drinks" : "Tap the mic to listen again"
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        Section {
            if matched.isEmpty {
                Text("No catalogue drinks recognised.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            ForEach(matched) { drink in
                let already = existingIDs.contains(drink.id)
                Button {
                    if included.contains(drink.id) { included.remove(drink.id) } else { included.insert(drink.id) }
                } label: {
                    DrinkLine(emoji: drink.displayEmoji, name: drinkName(drink, language),
                              detail: already ? "Already on this machine" : drinkName(drink, language.other),
                              selected: already || included.contains(drink.id))
                }
                .buttonStyle(.plain)
                .disabled(already)
                .opacity(already ? 0.55 : 1)
                .hermesListRow()
            }
        } header: {
            Text("Matched (\(matched.count))")
        } footer: {
            if !matched.isEmpty { Text("Tap a drink to leave it out.") }
        }

        if !unmatched.isEmpty {
            Section {
                ForEach(unmatched, id: \.self) { phrase in
                    let added = customs.contains(phrase)
                    HStack(spacing: 12) {
                        Text("\u{201C}\(phrase)\u{201D}")
                            .font(.system(size: 17))
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        if added {
                            Button("Added") { customs.removeAll { $0 == phrase } }
                                .buttonStyle(.borderless)
                                .font(.system(size: 15, weight: .semibold))
                        } else if existingCustom.contains(phrase.lowercased()) {
                            HermesChip(text: "Already custom", available: false)
                        } else {
                            Button("Add as custom") { customs.append(phrase) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .hermesListRow()
                }
            } header: {
                Text("Not in the catalogue")
            } footer: {
                Text("Add a phrase as a custom drink, or listen again. Custom drinks get a generic card.")
            }
        }
    }

    private func listen() {
        guard !listening else { return }
        errorText = nil
        let contextual = catalog.drinks.map { language == .ja ? $0.nameJa : $0.name }
        listenTask = Task {
            let result = await dictation.dictate(language: language, contextualStrings: contextual)
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text):
                heard = text
                let found = DrinkNameMatcher.matchAll(text, in: catalog)
                matched = found.matched
                unmatched = found.unmatched
                included = Set(found.matched.map(\.id).filter { !existingIDs.contains($0) })
                customs = []
            case .failure(let error):
                errorText = error.localizedDescription
            }
        }
    }
}
