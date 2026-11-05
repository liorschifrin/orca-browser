import Foundation
import Security
import SwiftUI
import WebKit

enum FormFieldKind: String, Codable, CaseIterable, Identifiable {
    case firstName, lastName, email, phone, street, addressLine2, city, region, postalCode, country
    var id: String { rawValue }
    var title: String {
        switch self {
        case .firstName: "First name"
        case .lastName: "Last name"
        case .email: "Email"
        case .phone: "Phone"
        case .street: "Street address"
        case .addressLine2: "Address line 2"
        case .city: "City"
        case .region: "State / region"
        case .postalCode: "Postal code"
        case .country: "Country"
        }
    }
}

struct SavedFormValue: Codable, Identifiable {
    var id: UUID
    var kind: String
    var value: String
    var uses: Int
}

@MainActor @Observable
final class FormSuggestions {
    static let shared = FormSuggestions()
    private static let service = "OrcaBrowser.savedFormValues"
    private static let account = "values"
    private(set) var items: [SavedFormValue] = []
    private(set) var activeKind: String?
    private(set) var fieldContext: AutofillFieldContext?
    private(set) var isSensitive = true
    private(set) var fieldToken = ""
    private(set) var matchedRule: AutofillRule?
    private(set) var candidate = ""
    private weak var activeWebView: WKWebView?
    private var isPrivate = false
    private var generation = 0

    private init() { reload() }

    var suggestions: [SavedFormValue] {
        guard let activeKind else { return [] }
        return items.filter { $0.kind == activeKind }
            .sorted { $0.uses == $1.uses ? $0.value < $1.value : $0.uses > $1.uses }
    }
    var canSave: Bool {
        guard let kind = activeKind, !isPrivate, !isSensitive,
              AutofillRules.shared.category(kind)?.dynamic == .none else { return false }
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 256 &&
            !items.contains { $0.kind == kind && $0.value == value }
    }

    func receive(_ body: Any, from webView: WKWebView, privateTab: Bool) {
        guard let info = body as? [String: Any] else { return }
        // Never accept messages from subframes, hidden tabs or an unrelated page.
        guard webView.window != nil, !webView.isHidden else { return }
        let context = AutofillFieldContext(info, url: webView.url)
        let builtin = info["kind"] as? String
        let rule = AutofillRules.shared.matchingRule(context: context)
        let kind = context.isSensitive ? nil : (rule?.category ?? builtin)
        activeWebView = webView
        isPrivate = privateTab
        fieldContext = context
        isSensitive = context.isSensitive
        fieldToken = info["token"] as? String ?? ""
        matchedRule = rule
        activeKind = kind
        candidate = kind == nil ? "" : String((info["value"] as? String ?? "").prefix(257))
        generation += 1
    }

    func clear(for webView: WKWebView) {
        guard activeWebView === webView else { return }
        activeKind = nil
        candidate = ""
        fieldContext = nil
        matchedRule = nil
        fieldToken = ""
        activeWebView = nil
        generation += 1
    }

    func fill(_ item: SavedFormValue) {
        guard item.kind == activeKind, !isSensitive, let webView = activeWebView,
              webView.window != nil, !webView.isHidden else { return }
        let encoded = (try? JSONSerialization.data(withJSONObject: [item.value], options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let script = "window.__orcaFillFocusedFormField && window.__orcaFillFocusedFormField(\(encoded)[0])"
        let currentGeneration = generation
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration, error == nil,
                      (result as? Bool) == true else { return }
                if let index = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[index].uses += 1
                    self.persist()
                }
            }
        }
    }

    var activeTitle: String {
        activeKind.flatMap { AutofillRules.shared.category($0)?.title } ?? "Field"
    }

    var dynamicSuggestion: String? {
        guard let kind = activeKind, !isSensitive else { return nil }
        return AutofillRules.shared.dynamicValue(for: kind, inputType: fieldContext?.attributes["inputType"] ?? "")
    }

    func fillDynamic() {
        guard let value = dynamicSuggestion else { return }
        fillText(value)
    }

    func fillText(_ value: String) {
        guard !isSensitive, let webView = activeWebView,
              webView.window != nil, !webView.isHidden else { return }
        let encoded = (try? JSONSerialization.data(withJSONObject: [value]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        webView.evaluateJavaScript("window.__orcaFillFocusedFormField && window.__orcaFillFocusedFormField(\(encoded)[0])")
    }

    func selectCategory(_ category: String) {
        guard !isSensitive, AutofillRules.shared.category(category) != nil else { return }
        activeKind = category
        matchedRule = nil
    }

    func deleteCategory(_ category: String) {
        items.removeAll { $0.kind == category }
        persist()
    }

    func addValue(category: String, value: String) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AutofillRules.shared.category(category) != nil, !clean.isEmpty, clean.count <= 256,
              !items.contains(where: { $0.kind == category && $0.value == clean }) else { return }
        items.append(SavedFormValue(id: UUID(), kind: category, value: clean, uses: 0))
        persist()
    }

    func saveCandidate() {
        guard canSave, let kind = activeKind else { return }
        addValue(category: kind, value: candidate)
    }

    func delete(_ item: SavedFormValue) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func update(_ item: SavedFormValue, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 256,
              !items.contains(where: { $0.id != item.id && $0.kind == item.kind && $0.value == trimmed }),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].value = trimmed
        persist()
    }

    private func reload() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: Self.account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let values = try? JSONDecoder().decode([SavedFormValue].self, from: data) else { return }
        items = values
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service,
                                    kSecAttrAccount as String: Self.account]
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static let messageName = "orcaFormField"
    static let script = WKUserScript(source: #"""
    (() => {
      if (window.__orcaFormInstalled) return;
      window.__orcaFormInstalled = true;
      const patterns = [
        ['firstName', /given-name|first.?name|fname/i],
        ['lastName', /family-name|last.?name|surname|lname/i],
        ['email', /email|e-mail/i],
        ['phone', /tel|phone|mobile/i],
        ['addressLine2', /address-line2|address.?2|apt|apartment|suite|unit/i],
        ['street', /address-line1|street-address|street|address.?1|shipping.?address|billing.?address/i],
        ['city', /address-level2|city|town/i],
        ['region', /address-level1|state|province|region|county/i],
        ['postalCode', /postal-code|zip|post.?code/i],
        ['country', /country/i],
        ['birthday', /bday|birth.?date|date.?of.?birth|dob/i]
      ];
      const forbidden = /password|passcode|credit.?card|card.?number|cardholder|cc-|cvc|cvv|security.?code|expir|iban|routing|account.?number|one.?time.?code|otp|verification/i;
      function fieldAttributes(el) {
        const label = el.labels ? Array.from(el.labels).map(l => l.textContent).join(' ') : '';
        return {autocomplete: el.autocomplete || '', name: el.name || '', id: el.id || '',
          label: label.slice(0,500), placeholder: (el.placeholder || '').slice(0,500),
          ariaLabel: (el.getAttribute('aria-label') || '').slice(0,500),
          inputType: el.type || '', cssSelector: el.id ? '#' + CSS.escape(el.id) :
          (el.name ? '[name="' + CSS.escape(el.name) + '"]' : '')};
      }
      function isSensitive(el) {
        if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) return true;
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (!['text','email','tel','search','date','month','number'].includes(type) &&
            !(el instanceof HTMLTextAreaElement)) return true;
        if (el.disabled || el.readOnly) return true;
        const a = fieldAttributes(el);
        return forbidden.test(Object.values(a).join(' ')) ||
          (el.form && /payment|checkout-card|credit-card/i.test(el.form.getAttribute('name') || ''));
      }
      function classify(el) {
        if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) return null;
        if (isSensitive(el)) return null;
        const type = (el.getAttribute('type') || 'text').toLowerCase();
        if (!['text','email','tel','search','date','month','number'].includes(type) && !(el instanceof HTMLTextAreaElement)) return null;
        const form = el.form;
        const metadata = [el.autocomplete, el.name, el.id, el.placeholder, el.getAttribute('aria-label'),
          el.labels ? Array.from(el.labels).map(l => l.textContent).join(' ') : ''].join(' ');
        if (forbidden.test(metadata) || forbidden.test(type) ||
            (form && /payment|checkout-card|credit-card/i.test(form.getAttribute('name') || ''))) return null;
        const tokens = (el.autocomplete || '').split(/\s+/);
        for (const token of tokens) {
          if (forbidden.test(token)) return null;
          const match = patterns.find(([_, pattern]) => pattern.test(token));
          if (match) return match[0];
        }
        if (type === 'email') return 'email';
        if (type === 'tel') return 'phone';
        const match = patterns.find(([_, pattern]) => pattern.test(metadata));
        return match ? match[0] : null;
      }
      let last = null;
      let tokenSequence = 0;
      document.addEventListener('focusin', e => {
        if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement)
          e.target.setAttribute('data-orca-field-token', String(++tokenSequence));
      }, true);
      function report(el) {
        const kind = el ? classify(el) : null;
        const value = el && !isSensitive(el) ? String(el.value || '').slice(0,257) : '';
        const key = kind + ':' + value;
        if (last === key) return;
        last = key;
        const sensitive = el ? isSensitive(el) : false;
        const attributes = el ? fieldAttributes(el) : {};
        window.webkit.messageHandlers.orcaFormField.postMessage({kind, value, sensitive, attributes, token});
      }
      document.addEventListener('focusin', e => report(e.target), true);
      document.addEventListener('input', e => {
        if (e.target === document.activeElement) report(e.target);
      }, true);
      document.addEventListener('focusout', () => {
        setTimeout(() => {
          if (!(document.activeElement instanceof HTMLInputElement || document.activeElement instanceof HTMLTextAreaElement)) report(null);
        }, 100);
      }, true);
      window.__orcaFillFocusedFormField = value => {
        const el = document.activeElement;
        if (isSensitive(el) || typeof value !== 'string') return false;
        const prototype = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        report(el);
        return true;
      };
    })();
    """#, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
}

struct SavedFormValuesView: View {
    private let store = FormSuggestions.shared
    @State private var editing: SavedFormValue?
    @State private var text = ""
    var body: some View {
        List {
            ForEach(FormFieldKind.allCases) { kind in
                let values = store.items.filter { $0.kind == kind.rawValue }
                if !values.isEmpty {
                    Section(kind.title) {
                        ForEach(values) { item in
                            Button {
                                editing = item
                                text = item.value
                            } label: {
                                HStack {
                                    Text(item.value).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "pencil").foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.delete(item) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Saved form values")
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView("No saved values", systemImage: "text.badge.plus",
                    description: Text("Save a value using the button above the keyboard on a web form."))
            }
        }
        .alert("Edit saved value", isPresented: Binding(
            get: { editing != nil }, set: { if !$0 { editing = nil } }
        )) {
            TextField("Value", text: $text)
            Button("Save") {
                if let editing { store.update(editing, value: text) }
                editing = nil
            }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }
}
