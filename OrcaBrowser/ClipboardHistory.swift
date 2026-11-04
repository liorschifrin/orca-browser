import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit

/// One thing that was on the clipboard. Text is kept right here; an image's
/// bytes live in a file beside the list (see `ClipboardHistory`).
nonisolated struct ClipboardItem: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case text, image }

    var id = UUID()
    var kind: Kind
    var text = ""
    /// The image's type identifier, such as "public.png".
    var imageType: String?
    /// Tells identical pictures apart without comparing their bytes.
    var imageHash: String?
    /// When it was copied, or last copied again.
    var date: Date

    /// Enough of the text to fill a row, so a huge copy doesn't slow the list.
    var preview: String { kind == .image ? "Image" : String(text.prefix(300)) }
}

/// A picture read off the pasteboard, ready to be remembered.
nonisolated struct ClipboardImage: Sendable {
    let data: Data
    let type: String
    let hash: String

    init(data: Data, type: String) {
        self.data = data
        self.type = type
        hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// What the small chip at the top of the screen says.
struct ClipboardNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let item: ClipboardItem?
}

/// Everything copied in the app, and whatever was on the clipboard when the
/// app was opened, newest first. Kept between launches with no expiry.
///
///     Clipboard/items.json   the list, text included
///     Clipboard/<id>.img     the bytes of an image item
///
/// Copying something that's already in the list moves it to the top instead
/// of adding it again.
@MainActor
@Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    /// So large it is only a guard against runaway growth.
    nonisolated static let defaultLimit = 10_000
    /// Larger text isn't kept, so one copy can't swell `items.json`, which is
    /// read at launch and rewritten on every change.
    nonisolated static let maxTextBytes = 256 * 1024

    private(set) var items: [ClipboardItem]
    /// Feedback for an explicit copy or a failed insertion.
    private(set) var notice: ClipboardNotice?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let maxItems: Int
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// False when `items.json` exists but couldn't be read, so an empty list
    /// never replaces it.
    @ObservationIgnored private var canSave = true
    /// Writes happen one after another, off the main thread.
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "ClipboardHistory.io", qos: .utility)
    @ObservationIgnored private let thumbnails: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 30 * 1024 * 1024
        return cache
    }()

    /// How long the chip stays up.
    private static let noticeDuration: Duration = .seconds(2.2)
    nonisolated private static let thumbnailPixels = 160
    /// Encrypted while the phone is locked. "Unless open" still lets a save
    /// that starts as the screen locks finish. Backups include these files
    /// as usual.
    nonisolated private static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Clipboard", directoryHint: .isDirectory),
        maxItems: Int = ClipboardHistory.defaultLimit
    ) {
        self.directory = directory
        self.maxItems = maxItems
        let file = directory.appending(path: "items.json")
        items = []
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        guard let data = try? Data(contentsOf: file) else {
            canSave = false
            return
        }
        if let saved = try? JSONDecoder().decode([ClipboardItem].self, from: data) {
            items = saved
        } else {
            // Keep it for recovery rather than saving over it.
            let aside = directory.appending(path: "items.unreadable.json")
            try? FileManager.default.removeItem(at: aside)
            // If it can't be kept aside, don't risk saving over it either.
            if (try? FileManager.default.moveItem(at: file, to: aside)) == nil { canSave = false }
        }
    }

    // MARK: Adding

    /// Remembers copied text. True if it's new, false if it was already
    /// there (it moves to the top) or is blank. With `addsNew` off, only
    /// items already in the history move; nothing new is kept.
    @discardableResult
    func record(text: String, addsNew: Bool = true) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxTextBytes else { return false }
        if let index = items.firstIndex(where: { $0.kind == .text && $0.text == text }) {
            moveToTop(index)
            return false
        }
        guard addsNew else { return false }
        add(ClipboardItem(kind: .text, text: text, date: .now))
        return true
    }

    /// Remembers a copied picture. True if it's new.
    @discardableResult
    func record(image: ClipboardImage, addsNew: Bool = true) -> Bool {
        if let index = items.firstIndex(where: { $0.imageHash == image.hash }) {
            moveToTop(index)
            return false
        }
        guard addsNew else { return false }
        let item = ClipboardItem(kind: .image, imageType: image.type, imageHash: image.hash, date: .now)
        let file = imageFile(for: item)
        let directory = directory
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? image.data.write(to: file, options: Self.writeOptions)
        }
        add(item)
        return true
    }

    private func add(_ item: ClipboardItem) {
        items.insert(item, at: 0)
        if items.count > maxItems {
            removeFiles(for: Array(items[maxItems...]))
            items.removeSubrange(maxItems...)
        }
        scheduleSave()
    }

    private func moveToTop(_ index: Int) {
        var item = items.remove(at: index)
        item.date = .now
        items.insert(item, at: 0)
        scheduleSave()
    }

    // MARK: Using

    /// Puts the item back on the clipboard and at the top of the history.
    /// False, with a chip saying so, if a picture's file can't be read.
    @discardableResult
    func copyToPasteboard(_ item: ClipboardItem, announces: Bool = true, title: String = "Copied") -> Bool {
        switch item.kind {
        case .text:
            UIPasteboard.general.string = item.text
        case .image:
            guard let type = item.imageType,
                  let data = try? Data(contentsOf: imageFile(for: item)) else {
                show(ClipboardNotice(title: "Couldn’t copy that image", item: nil))
                return false
            }
            UIPasteboard.general.setData(data, forPasteboardType: type)
        }
        // It's already in the history; the pasteboard read that follows must
        // not treat it as something new.
        ClipboardCache.shared.noteHistoryWrite(text: item.kind == .text ? item.text : nil)
        if let index = items.firstIndex(where: { $0.id == item.id }) { moveToTop(index) }
        if announces { show(ClipboardNotice(title: title, item: item)) }
        return true
    }

    /// Copies the item and types it into the field that has the keyboard.
    /// Pictures can't be typed, so they are pasted where the field takes them.
    /// If nothing can take it, it stays copied and the chip says so.
    @discardableResult
    func insert(_ item: ClipboardItem) -> Bool {
        guard copyToPasteboard(item, announces: false) else { return false }
        // Some web editors accept paste through the responder chain without
        // exposing UIKeyInput. Use that path if direct text insertion fails.
        let inserted: Bool
        if item.kind == .text, Self.typeIntoField(item.text) {
            inserted = true
        } else {
            inserted = Self.pasteIntoField()
        }
        if !inserted {
            show(ClipboardNotice(title: item.kind == .image ? "Image copied" : "Copied. Paste it into the field", item: item))
        }
        return inserted
    }

    /// Types `text` into the field that has the keyboard, as the keyboard
    /// would: over any selection, at the cursor, keeping the keyboard up.
    /// False if no field has the keyboard.
    @discardableResult
    static func typeIntoField(_ text: String) -> Bool {
        guard let input = UIResponder.currentFirstResponder() as? UIKeyInput else { return false }
        // A one-line field would take a line break as the return key.
        input.insertText(input is UITextField ? text.replacing(/\s*\n\s*/, with: " ") : text)
        return true
    }

    @discardableResult
    static func pasteIntoField() -> Bool {
        UIApplication.shared.sendAction(#selector(UIResponder.paste(_:)), to: nil, from: nil, for: nil)
    }

    // MARK: Removing

    func delete(_ item: ClipboardItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        removeFiles(for: [item])
        scheduleSave()
    }

    func clear() {
        removeFiles(for: items)
        items = []
        notice = nil
        scheduleSave()
    }

    private func removeFiles(for removed: [ClipboardItem]) {
        let files = removed.filter { $0.kind == .image }.map(imageFile(for:))
        guard !files.isEmpty else { return }
        for item in removed { thumbnails.removeObject(forKey: item.id.uuidString as NSString) }
        ioQueue.async {
            for file in files { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: The chip

    private func show(_ notice: ClipboardNotice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self.notice = nil
        }
    }

    // MARK: Images

    private func imageFile(for item: ClipboardItem) -> URL {
        directory.appending(path: "\(item.id.uuidString).img")
    }

    /// A small version of an image item, decoded off the main thread.
    func thumbnail(for item: ClipboardItem) async -> UIImage? {
        guard item.kind == .image else { return nil }
        let key = item.id.uuidString as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        let file = imageFile(for: item)
        let image = await Task.detached(priority: .utility) { Self.decode(file) }.value
        if let image {
            thumbnails.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0)
        }
        return image
    }

    nonisolated private static func decode(_ file: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .map { UIImage(cgImage: $0) }
    }

    // MARK: Saving

    /// Saves soon, but not on every copy.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    func save() {
        saveTask?.cancel()
        guard canSave else { return }
        let snapshot = items
        let directory = directory
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: directory.appending(path: "items.json"), options: Self.writeOptions)
        }
    }

    /// Returns once everything queued so far is on disk.
    func waitForWrites() {
        ioQueue.sync {}
    }
}

private extension UIResponder {
    private static weak var captured: UIResponder?

    @objc private func captureAsFirstResponder() { Self.captured = self }

    /// Whatever has the keyboard right now: sending an action to no one in
    /// particular delivers it to the first responder.
    static func currentFirstResponder() -> UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(captureAsFirstResponder), to: nil, from: nil, for: nil)
        return captured
    }
}
