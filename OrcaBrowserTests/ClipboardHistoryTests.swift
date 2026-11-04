import Foundation
import Testing
import UIKit
@testable import OrcaBrowser

@MainActor
struct ClipboardHistoryTests {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    }

    @Test func choosingHistoryInsertsAtTheSelectionAndKeepsTheFieldFocused() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let field = UITextField(frame: CGRect(x: 20, y: 100, width: 280, height: 44))
        controller.view.addSubview(field)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }

        field.text = "before old after"
        #expect(field.becomeFirstResponder())
        let start = try #require(field.position(from: field.beginningOfDocument, offset: 7))
        let end = try #require(field.position(from: start, offset: 3))
        field.selectedTextRange = field.textRange(from: start, to: end)

        let directory = makeDirectory()
        let history = ClipboardHistory(directory: directory)
        defer {
            history.waitForWrites()
            try? FileManager.default.removeItem(at: directory)
        }
        history.record(text: "replacement")
        let item = try #require(history.items.first)
        history.record(text: "newer")

        #expect(history.insert(item))
        #expect(field.text == "before replacement after")
        #expect(field.isFirstResponder)
        #expect(UIPasteboard.general.string == "replacement")
        #expect(history.items.first?.id == item.id)
    }

    @Test func newTextIsAddedSilentlyAndARepeatOnlyMovesToTheTop() {
        let history = ClipboardHistory(directory: makeDirectory())
        #expect(history.record(text: "first"))
        #expect(history.record(text: "second"))
        #expect(history.items.map(\.text) == ["second", "first"])
        #expect(history.notice == nil)

        #expect(!history.record(text: "first"))
        #expect(history.items.map(\.text) == ["first", "second"])
        #expect(history.notice == nil)
    }

    @Test func withoutAddingNewOnlyKnownItemsMoveToTheTop() {
        let history = ClipboardHistory(directory: makeDirectory())
        history.record(text: "old")
        history.record(text: "newer")
        let announced = history.notice?.id
        #expect(!history.record(text: "old", addsNew: false))
        #expect(history.items.map(\.text) == ["old", "newer"])
        #expect(!history.record(text: "private", addsNew: false))
        #expect(!history.record(image: ClipboardImage(data: Data([4]), type: "public.png"), addsNew: false))
        #expect(history.items.map(\.text) == ["old", "newer"])
        #expect(history.notice?.id == announced)
    }

    @Test func blankTextIsIgnored() {
        let history = ClipboardHistory(directory: makeDirectory())
        #expect(!history.record(text: " \n\t "))
        #expect(history.items.isEmpty)
        #expect(history.notice == nil)
    }

    @Test func theOldestItemsGoWhenTheLimitIsReached() {
        let history = ClipboardHistory(directory: makeDirectory(), maxItems: 3)
        for number in 1...5 { history.record(text: "item \(number)") }
        #expect(history.items.map(\.text) == ["item 5", "item 4", "item 3"])
    }

    @Test func historySurvivesRelaunchWithTextAndImages() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ClipboardHistory(directory: directory)
        history.record(text: "kept")
        let image = ClipboardImage(data: Data([1, 2, 3]), type: "public.png")
        history.record(image: image)
        history.save()
        history.waitForWrites()

        let reopened = ClipboardHistory(directory: directory)
        #expect(reopened.items == history.items)
        #expect(reopened.items.first?.kind == .image)
        let file = directory.appending(path: "\(reopened.items[0].id.uuidString).img")
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
    }

    @Test func theSamePictureIsNotAddedTwice() {
        let history = ClipboardHistory(directory: makeDirectory())
        let image = ClipboardImage(data: Data([9, 9]), type: "public.png")
        #expect(history.record(image: image))
        history.record(text: "between")
        #expect(!history.record(image: ClipboardImage(data: Data([9, 9]), type: "public.png")))
        #expect(history.items.count == 2)
        #expect(history.items.first?.kind == .image)
    }

    @Test func deletingAndClearingRemoveItemsAndTheirFiles() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = ClipboardHistory(directory: directory)
        history.record(text: "text")
        history.record(image: ClipboardImage(data: Data([7]), type: "public.png"))
        history.waitForWrites()
        let image = history.items[0]
        let file = directory.appending(path: "\(image.id.uuidString).img")
        #expect(FileManager.default.fileExists(atPath: file.path))

        history.delete(image)
        history.waitForWrites()
        #expect(history.items.map(\.text) == ["text"])
        #expect(!FileManager.default.fileExists(atPath: file.path))

        history.clear()
        #expect(history.items.isEmpty)
        #expect(history.notice == nil)
    }
}

struct ClipboardRecordingRulesTests {
    @Test func nothingIsKeptForSecretsOrWhenTurnedOff() {
        #expect(ClipboardCache.shouldRemember(isEnabled: true, isConcealed: false))
        #expect(!ClipboardCache.shouldRemember(isEnabled: true, isConcealed: true))
        #expect(!ClipboardCache.shouldRemember(isEnabled: false, isConcealed: false))
    }
}

struct SearchClipboardBehaviorTests {
    @Test func emptyOrUntouchedSearchNavigates() {
        #expect(SearchOverlay.shouldNavigateClipboard(text: "", hasEditedText: false))
        #expect(SearchOverlay.shouldNavigateClipboard(text: "", hasEditedText: true))
        #expect(SearchOverlay.shouldNavigateClipboard(text: "https://example.com", hasEditedText: false))
    }

    @Test func editedSearchKeepsTypingInsteadOfNavigating() {
        #expect(!SearchOverlay.shouldNavigateClipboard(text: "my query ", hasEditedText: true))
        #expect(!SearchOverlay.shouldNavigateClipboard(text: "https://example.com", hasEditedText: true))
    }
}
