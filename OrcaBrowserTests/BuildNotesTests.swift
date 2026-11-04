import Foundation
import Testing
@testable import OrcaBrowser

struct BuildNotesTests {
    private func encode(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
    }

    @Test func decodesChangedAndTest() {
        let notes = BuildNotes.decode(base64: encode(#"{"changed":["A \"quoted\" line"],"test":["Try B","Try C"]}"#))
        #expect(notes == BuildNotes(changed: ["A \"quoted\" line"], test: ["Try B", "Try C"]))
    }

    @Test func missingSectionIsEmpty() {
        let notes = BuildNotes.decode(base64: encode(#"{"changed":["Only this"]}"#))
        #expect(notes == BuildNotes(changed: ["Only this"], test: []))
    }

    @Test(arguments: ["", "not base64!", "e30=", "eyJjaGFuZ2VkIjpbXSwidGVzdCI6W119"])
    func nothingToShowIsNil(input: String) {
        #expect(BuildNotes.decode(base64: input) == nil)
    }
}
