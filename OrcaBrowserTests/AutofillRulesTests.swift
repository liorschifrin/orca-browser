import Foundation
import Testing
@testable import OrcaBrowser

@MainActor
struct AutofillRulesTests {
    private func context(
        url: String = "https://docs.google.com/forms/d/abc123/viewform",
        label: String = "University ID",
        sensitive: Bool = false
    ) -> AutofillFieldContext {
        AutofillFieldContext([
            "attributes": ["label": label, "name": "entry.123", "inputType": "text"],
            "sensitive": sensitive
        ], url: URL(string: url))
    }

    @Test func exactFormAndLabelMatch() {
        let rule = AutofillRule(
            category: "firstName",
            siteMode: .only,
            domains: ["docs.google.com"],
            pageURLContains: "/forms/d/abc123/",
            source: .label,
            operation: .exact,
            pattern: "University ID"
        )
        let store = AutofillRules.shared
        #expect(store.matches(rule, context: context()))
        #expect(!store.matches(rule, context: context(url: "https://docs.google.com/forms/d/other/viewform")))
        #expect(!store.matches(rule, context: context(label: "Email address")))
        #expect(!store.matches(rule, context: context(sensitive: true)))
    }

    @Test func wildcardDomainsRespectBoundaries() {
        let rule = AutofillRule(
            category: "firstName",
            siteMode: .only,
            domains: ["*.brandeis.edu"],
            source: .label,
            pattern: "University"
        )
        let store = AutofillRules.shared
        #expect(store.matches(rule, context: context(url: "https://forms.brandeis.edu/")))
        #expect(!store.matches(rule, context: context(url: "https://brandeis.edu.evil.example/")))
    }

    @Test func regexAndNegativeMatches() {
        let rule = AutofillRule(
            category: "firstName",
            source: .label,
            operation: .regex,
            pattern: "student\\s+(id|number)",
            mustNotContain: "confirm"
        )
        let store = AutofillRules.shared
        #expect(store.matches(rule, context: context(label: "Student ID")))
        #expect(!store.matches(rule, context: context(label: "Confirm Student ID")))
    }
}
