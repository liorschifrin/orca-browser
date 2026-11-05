import Foundation
import Security
import SwiftUI

/// Rules are stored separately from saved answers. A rule describes a category,
/// not one particular value, so multiple answers can share the same matching rules.
struct AutofillRule: Codable, Identifiable {
    enum MatchSource: String, Codable, CaseIterable, Identifiable {
        case autocomplete, name, id, label, placeholder, ariaLabel, inputType, cssSelector
        var id: String { rawValue }
        var title: String {
            switch self {
            case .autocomplete: "Autocomplete"
            case .name: "Name attribute"
            case .id: "ID attribute"
            case .label: "Visible label"
            case .placeholder: "Placeholder"
            case .ariaLabel: "Accessibility label"
            case .inputType: "Input type"
            case .cssSelector: "CSS selector"
            }
        }
    }
    enum MatchOperator: String, Codable, CaseIterable, Identifiable {
        case contains, exact, startsWith, regex
        var id: String { rawValue }
    }
    enum SiteMode: String, Codable, CaseIterable, Identifiable {
        case everywhere, only, except
        var id: String { rawValue }
    }
    var id = UUID()
    var category: String
    var enabled = true
    var automatic = true
    var siteMode: SiteMode = .everywhere
    var domains: [String] = []
    /// Optional path prefix or exact form URL substring. Useful for Google Forms,
    /// where every form shares docs.google.com but has a distinct /forms/d/... URL.
    var pageURLContains = ""
    var source: MatchSource = .label
    var operation: MatchOperator = .contains
    var pattern = ""
    var priority = 100
    var mustNotContain = ""
}

struct AutofillCategory: Codable, Identifiable {
    var id: String
    var title: String
    var dynamic: DynamicValue = .none
    enum DynamicValue: String, Codable, CaseIterable, Identifiable {
        case none, today, currentYear
        var id: String { rawValue }
    }
}

struct AutofillFieldContext {
    let url: URL?
    let attributes: [String: String]
    let isSensitive: Bool

    init(_ body: [String: Any], url: URL?) {
        self.url = url
        attributes = body["attributes"] as? [String: String] ?? [:]
        isSensitive = body["sensitive"] as? Bool ?? true
    }
}

@MainActor @Observable
final class AutofillRules {
    static let shared = AutofillRules()
    private let service = "OrcaBrowser.autofillRules"
    private let account = "configuration"
    private(set) var categories: [AutofillCategory] = []
    private(set) var rules: [AutofillRule] = []

    private init() {
        if let data = Self.read(service: service, account: account),
           let saved = try? JSONDecoder().decode(Configuration.self, from: data) {
            categories = saved.categories
            rules = saved.rules
        } else {
            categories = [
                AutofillCategory(id: "firstName", title: "First name"),
                AutofillCategory(id: "lastName", title: "Last name"),
                AutofillCategory(id: "email", title: "Email"),
                AutofillCategory(id: "phone", title: "Phone"),
                AutofillCategory(id: "street", title: "Street address"),
                AutofillCategory(id: "addressLine2", title: "Address line 2"),
                AutofillCategory(id: "city", title: "City"),
                AutofillCategory(id: "region", title: "State / region"),
                AutofillCategory(id: "postalCode", title: "Postal code"),
                AutofillCategory(id: "country", title: "Country"),
                AutofillCategory(id: "birthday", title: "Date of birth"),
                AutofillCategory(id: "today", title: "Today's date", dynamic: .today),
                AutofillCategory(id: "currentYear", title: "Current year", dynamic: .currentYear)
            ]
            // These rules supplement the built-in HTML classification.
            rules = [
                AutofillRule(category: "birthday", source: .autocomplete, pattern: "bday", priority: 200),
                AutofillRule(category: "birthday", source: .label, pattern: "date of birth", priority: 150),
                AutofillRule(category: "birthday", source: .name, pattern: "birth", priority: 120),
                AutofillRule(category: "birthday", source: .id, pattern: "dob", priority: 120)
            ]
        }
    }

    private struct Configuration: Codable {
        let categories: [AutofillCategory]
        let rules: [AutofillRule]
    }

    func category(_ id: String) -> AutofillCategory? { categories.first { $0.id == id } }

    func addCategory(title: String, dynamic: AutofillCategory.DynamicValue = .none) -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { return nil }
        let id = UUID().uuidString
        categories.append(AutofillCategory(id: id, title: clean, dynamic: dynamic))
        persist()
        return id
    }

    func renameCategory(_ id: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80,
              let index = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[index].title = clean
        persist()
    }

    func deleteCategory(_ id: String) {
        // Built-in categories remain available; custom categories can be deleted.
        guard UUID(uuidString: id) != nil else { return }
        categories.removeAll { $0.id == id }
        rules.removeAll { $0.category == id }
        FormSuggestions.shared.deleteCategory(id)
        persist()
    }

    func saveRule(_ rule: AutofillRule) {
        guard category(rule.category) != nil, rule.pattern.count <= 300,
              rule.pageURLContains.count <= 300,
              rule.domains.count <= 30 else { return }
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        persist()
    }

    func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        persist()
    }

    func matchingCategory(context: AutofillFieldContext) -> String? {
        guard !context.isSensitive else { return nil }
        return rules.filter { $0.enabled && $0.automatic && matches($0, context: context) }
            .sorted { $0.priority == $1.priority ? $0.id.uuidString < $1.id.uuidString : $0.priority > $1.priority }
            .first?.category
    }

    func matchingRule(context: AutofillFieldContext) -> AutofillRule? {
        rules.filter { $0.enabled && $0.automatic && matches($0, context: context) }
            .sorted { $0.priority > $1.priority }.first
    }

    func matches(_ rule: AutofillRule, context: AutofillFieldContext) -> Bool {
        guard !context.isSensitive else { return false }
        let host = context.url?.host?.lowercased() ?? ""
        let siteMatches = rule.domains.contains { domain in
            let d = domain.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = d.hasPrefix("*.") ? String(d.dropFirst(2)) : d
            return !bare.isEmpty && (host == bare || (d.hasPrefix("*.") && host.hasSuffix("." + bare)))
        }
        switch rule.siteMode {
        case .everywhere: break
        case .only: guard siteMatches else { return false }
        case .except: guard !siteMatches else { return false }
        }
        if !rule.pageURLContains.isEmpty,
           !(context.url?.absoluteString.localizedCaseInsensitiveContains(rule.pageURLContains) ?? false) {
            return false
        }
        let value = context.attributes[rule.source.rawValue] ?? ""
        if !rule.mustNotContain.isEmpty && value.localizedCaseInsensitiveContains(rule.mustNotContain) { return false }
        guard !rule.pattern.isEmpty else { return false }
        switch rule.operation {
        case .contains: return value.localizedCaseInsensitiveContains(rule.pattern)
        case .exact: return value.compare(rule.pattern, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .startsWith: return value.lowercased().hasPrefix(rule.pattern.lowercased())
        case .regex:
            guard let expression = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]),
                  value.count <= 1000 else { return false }
            return expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }
    }

    func dynamicValue(for id: String, inputType: String) -> String? {
        guard let category = category(id) else { return nil }
        switch category.dynamic {
        case .none: return nil
        case .today:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = inputType == "date" ? "yyyy-MM-dd" : "yyyy-MM-dd"
            return formatter.string(from: .now)
        case .currentYear: return String(Calendar.current.component(.year, from: .now))
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Configuration(categories: categories, rules: rules)) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            let attributes: [String: Any] = [kSecValueData as String: data,
                                              kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    private static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
