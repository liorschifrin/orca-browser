import Foundation
import Testing
@testable import MyApp

/// `isForeign` compares against the device's preferred languages, so these
/// say what the answer should be for whatever the test device reads.
struct TranslationTests {
    private func reads(_ code: String) -> Bool {
        Locale.preferredLanguages.contains { Locale(identifier: $0).language.languageCode?.identifier == code }
    }

    private let french = """
    La ville de Paris est la capitale de la France. Elle est connue pour ses musées, \
    ses monuments et sa cuisine, et attire chaque année des millions de visiteurs.
    """

    private let english = """
    The city of London is the capital of England. It is known for its museums, its \
    landmarks and its theatre, and draws millions of visitors every year.
    """

    @Test func longTextIsJudgedByWhatItSays() {
        #expect(Translation.isForeign(declared: "", text: french) == !reads("fr"))
        #expect(Translation.isForeign(declared: "", text: english) == !reads("en"))
    }

    @Test func textOutweighsAWrongDeclaration() {
        #expect(Translation.isForeign(declared: "en", text: french) == !reads("fr"))
    }

    @Test func shortPagesFallBackToTheDeclaredLanguage() {
        #expect(Translation.isForeign(declared: "fr", text: "Bonjour") == !reads("fr"))
        #expect(Translation.isForeign(declared: "", text: "Bonjour") == false)
    }
}
