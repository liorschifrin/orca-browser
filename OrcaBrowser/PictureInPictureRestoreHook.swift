import ObjectiveC
import UIKit

/// Tells the app the moment you tap "return to app" in the picture in
/// picture window.
///
/// The page only reports that the video left picture in picture after the
/// window has finished its own return animation, which is too late to start
/// switching tabs. WebKit's own handler for that button runs right at the tap,
/// so this wraps it: our code runs first, then WebKit's. The close button
/// doesn't call it.
///
/// This uses a private WebKit class (`WebAVPlayerViewControllerDelegate`), so
/// it isn't allowed in App Store apps, and an iOS update may rename it. If the
/// class or method isn't found, nothing is installed and the app falls back
/// to the page's later report (`Tab.pictureInPictureChanged`).
enum PictureInPictureRestoreHook {
    static let didTapRestore = Notification.Name("OrcaPictureInPictureRestoreTapped")
    private static var isInstalled = false

    static func install() {
        guard !isInstalled, let delegate = NSClassFromString("WebAVPlayerViewControllerDelegate") else { return }
        let selector = NSSelectorFromString("playerViewController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:")
        guard let method = class_getInstanceMethod(delegate, selector) else { return }
        isInstalled = true

        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> Void = { object, controller, completion in
            if Thread.isMainThread {
                NotificationCenter.default.post(name: didTapRestore, object: nil)
            } else {
                DispatchQueue.main.async { NotificationCenter.default.post(name: didTapRestore, object: nil) }
            }
            original(object, selector, controller, completion)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
