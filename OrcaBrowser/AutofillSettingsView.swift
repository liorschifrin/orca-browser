import SwiftUI

/// Manage all built-in and custom categories, their values and matching rules.
struct AutofillSettingsView: View {
    private let rules = AutofillRules.shared
    private let values = FormSuggestions.shared
    @State private var showingAdd = false
    @State private var newTitle = ""
    @State private var newDynamic: AutofillCategory.DynamicValue = .none

    var body: some View {
        List {
            if let error = values.storageError {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                ForEach(rules.categories) { category in
                    NavigationLink {
                        AutofillCategoryEditor(categoryID: category.id)
                    } label: {
                        HStack {
                            Text(category.title)
                            Spacer()
                            Text(category.dynamic == .none
                                 ? "\(values.items.filter { $0.kind == category.id }.count) saved"
                                 : "Dynamic")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Autofill categories")
            } footer: {
                Text("Create rules to decide which fields match each category. Site-specific rules can target an individual Google Form URL.")
            }
            Section {
                Button {
                    newTitle = ""
                    newDynamic = .none
                    showingAdd = true
                } label: {
                    Label("Add custom category", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Autofill")
        .alert("New category", isPresented: $showingAdd) {
            TextField("Category name", text: $newTitle)
            Button("Add") { _ = rules.addCategory(title: newTitle, dynamic: newDynamic) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("For example: Student ID, Frequent flyer number or Membership number.")
        }
    }
}

private struct AutofillCategoryEditor: View {
    let categoryID: String
    private let rules = AutofillRules.shared
    private let store = FormSuggestions.shared
    @State private var showingAddValue = false
    @State private var newValue = ""
    @State private var editValue: SavedFormValue?
    @State private var editedText = ""
    @State private var editingRule: AutofillRule?
    @State private var categoryName = ""
    @State private var showingRename = false
    @State private var categoryDomains = ""
    @Environment(\.dismiss) private var dismiss

    private var category: AutofillCategory? { rules.category(categoryID) }
    private var categoryRules: [AutofillRule] { rules.rules.filter { $0.category == categoryID } }

    var body: some View {
        List {
            if let category {
                Section("Availability") {
                    Toggle("Enabled", isOn: Binding(
                        get: { self.category?.enabled ?? true },
                        set: { new in
                            guard var updated = self.category else { return }
                            updated.enabled = new
                            rules.updateCategory(updated)
                        }
                    ))
                    Toggle("Suggest automatically", isOn: Binding(
                        get: { self.category?.automatic ?? true },
                        set: { new in
                            guard var updated = self.category else { return }
                            updated.automatic = new
                            rules.updateCategory(updated)
                        }
                    ))
                    Picker("Websites", selection: Binding(
                        get: { self.category?.siteMode ?? .everywhere },
                        set: { new in
                            guard var updated = self.category else { return }
                            updated.siteMode = new
                            rules.updateCategory(updated)
                        }
                    )) {
                        Text("All websites").tag(AutofillRule.SiteMode.everywhere)
                        Text("Only listed websites").tag(AutofillRule.SiteMode.only)
                        Text("Except listed websites").tag(AutofillRule.SiteMode.except)
                    }
                    if category.siteMode != .everywhere {
                        TextField("Domains, comma-separated", text: $categoryDomains)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveCategoryDomains)
                        Button("Save website list", action: saveCategoryDomains)
                    }
                }
                Section {
                    if category.dynamic == .none {
                        ForEach(store.items.filter { $0.kind == categoryID }) { item in
                            Button(item.value) {
                                editValue = item
                                editedText = item.value
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.delete(item) }
                            }
                        }
                        Button {
                            newValue = ""
                            showingAddValue = true
                        } label: {
                            Label("Add saved value", systemImage: "plus.circle")
                        }
                    } else {
                        LabeledContent("Generated value", value: category.dynamic == .today ? "Today's date" : "Current year")
                        Text("Generated when you tap the suggestion, using the device's current date.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("Values") }
                Section {
                    ForEach(categoryRules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.pattern)
                                    .foregroundStyle(.primary)
                                Text(rule.siteMode == .everywhere ? "All sites" : rule.domains.joined(separator: ", "))
                                    .font(.footnote).foregroundStyle(.secondary)
                                if !rule.pageURLContains.isEmpty {
                                    Text("Page contains: \(rule.pageURLContains)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { rules.deleteRule(rule.id) }
                        }
                    }
                    Button {
                        editingRule = AutofillRule(category: categoryID)
                    } label: {
                        Label("Add matching rule", systemImage: "plus.circle")
                    }
                } header: { Text("When to suggest") }
                Section {
                    Button("Rename category") {
                        categoryName = category.title
                        showingRename = true
                    }
                    if UUID(uuidString: categoryID) != nil {
                        Button("Delete custom category", role: .destructive) {
                            rules.deleteCategory(categoryID)
                            dismiss()
                        }
                    }
                }
            }
        }
        .navigationTitle(category?.title ?? "Autofill")
        .onAppear { categoryDomains = category?.domains.joined(separator: ", ") ?? "" }
        .sheet(item: $editingRule) { rule in
            NavigationStack {
                AutofillRuleEditor(rule: rule) { updated in
                    rules.saveRule(updated)
                    editingRule = nil
                } onCancel: {
                    editingRule = nil
                }
            }
        }
        .alert("Add value", isPresented: $showingAddValue) {
            TextField("Value", text: $newValue)
            Button("Save") { store.addValue(category: categoryID, value: newValue) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit value", isPresented: Binding(
            get: { editValue != nil }, set: { if !$0 { editValue = nil } }
        )) {
            TextField("Value", text: $editedText)
            Button("Save") {
                if let editValue { store.update(editValue, value: editedText) }
                editValue = nil
            }
            Button("Cancel", role: .cancel) { editValue = nil }
        }
        .alert("Rename category", isPresented: $showingRename) {
            TextField("Category name", text: $categoryName)
            Button("Save") { rules.renameCategory(categoryID, to: categoryName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func saveCategoryDomains() {
        guard var updated = category else { return }
        updated.domains = categoryDomains.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        rules.updateCategory(updated)
    }
}

private struct AutofillRuleEditor: View {
    @State var rule: AutofillRule
    let onSave: (AutofillRule) -> Void
    let onCancel: () -> Void
    @State private var domainText: String = ""
    var body: some View {
        Form {
            Section("Behavior") {
                Toggle("Enabled", isOn: $rule.enabled)
                Toggle("Suggest automatically", isOn: $rule.automatic)
                Stepper("Priority: \(rule.priority)", value: $rule.priority, in: 0...300, step: 10)
            }
            Section("Websites") {
                Picker("Availability", selection: $rule.siteMode) {
                    Text("All websites").tag(AutofillRule.SiteMode.everywhere)
                    Text("Only these websites").tag(AutofillRule.SiteMode.only)
                    Text("Except these websites").tag(AutofillRule.SiteMode.except)
                }
                if rule.siteMode != .everywhere {
                    TextField("example.com, *.school.edu", text: $domainText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                TextField("Page URL must contain (optional)", text: $rule.pageURLContains)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Text("For a particular Google Form, paste the unique /forms/d/… portion of its URL.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Field matching") {
                Picker("Inspect", selection: $rule.source) {
                    ForEach(AutofillRule.MatchSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Picker("Match", selection: $rule.operation) {
                    ForEach(AutofillRule.MatchOperator.allCases) { operation in
                        Text(operation.rawValue).tag(operation)
                    }
                }
                TextField("Match text or pattern", text: $rule.pattern)
                    .textInputAutocapitalization(.never)
                TextField("Must not contain (optional)", text: $rule.mustNotContain)
                    .textInputAutocapitalization(.never)
                if rule.operation == .regex,
                   !rule.pattern.isEmpty,
                   (try? NSRegularExpression(pattern: rule.pattern)) == nil {
                    Text("Invalid regular expression")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Matching rule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    rule.domains = domainText.split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    }
                    onSave(rule)
                }
                .disabled(rule.pattern.isEmpty || (rule.operation == .regex &&
                    (try? NSRegularExpression(pattern: rule.pattern)) == nil))
            }
        }
        .onAppear { domainText = rule.domains.joined(separator: ", ") }
    }
}

/// Manual picker remains available even when a website has unusual field labels.
struct AutofillManualPicker: View {
    private let rules = AutofillRules.shared
    private let store = FormSuggestions.shared
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(rules.categories) { category in
                    Section(category.title) {
                        if store.fieldContext != nil && !store.isSensitive {
                            Button("Remember this field as \(category.title) on this site") {
                                store.rememberField(as: category.id)
                                onDone()
                            }
                        }
                        if let generated = rules.dynamicValue(for: category.id,
                            inputType: store.fieldContext?.attributes["inputType"] ?? "") {
                            Button(generated) {
                                store.selectCategory(category.id)
                                store.fillDynamic()
                                onDone()
                            }
                        }
                        ForEach(store.items.filter { $0.kind == category.id }) { item in
                            Button(item.value) {
                                store.selectCategory(category.id)
                                store.fill(item)
                                onDone()
                            }
                        }
                        if store.fieldContext != nil && !store.isSensitive &&
                            category.dynamic == .none {
                            Button("Save current field as \(category.title)") {
                                store.selectCategory(category.id)
                                store.saveCandidate()
                                onDone()
                            }
                            .disabled(store.candidate.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("Autofill")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) }
            }
        }
    }
}
