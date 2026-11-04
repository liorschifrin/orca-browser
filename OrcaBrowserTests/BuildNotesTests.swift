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

    @Test func decodesThreadLink() {
        let notes = BuildNotes.decode(base64: encode(#"{"changed":[],"test":[],"thread":"t3code://threads/env/thread"}"#))
        #expect(notes?.threadURL == URL(string: "t3code://threads/env/thread"))
    }

    @Test func decodesMoreAndHeading() {
        let notes = BuildNotes.decode(base64: encode(#"{"changed":["New"],"test":[],"more":["Old 1","Old 2"],"heading":"Recent updates"}"#))
        #expect(notes?.more == ["Old 1", "Old 2"])
        #expect(notes?.heading == "Recent updates")
        #expect(BuildNotes.decode(base64: encode(#"{"changed":["New"]}"#))?.heading == "Changed")
    }

    @Test func decodesNewCount() {
        #expect(BuildNotes.decode(base64: encode(#"{"changed":["A","B"],"newCount":1}"#))?.newCount == 1)
        #expect(BuildNotes.decode(base64: encode(#"{"changed":["A","B"]}"#))?.newCount == 0)
        #expect(BuildNotes.decode(base64: encode(#"{"changed":["A"],"newCount":-3}"#))?.newCount == 0)
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
