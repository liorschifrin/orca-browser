import AVFoundation
import WebKit

/// Keeps YouTube videos playing in picture in picture, in a hidden tab, and
/// with the app in the background.
///
/// YouTube's page fights all three without Premium:
/// - It pauses when the page reports itself hidden, which happens on a tab
///   switch (the tab's web view is hidden) and when the app goes to the
///   background.
/// - It watches the video's presentation mode and switches picture in
///   picture straight back to the inline player.
///
/// The user script below runs in the page's own script world, before
/// YouTube's code, so YouTube sees a page that is always visible and a video
/// that never left the page. The app side is the `audio` background mode in
/// AppInfo.plist and the `.playback` audio session set at launch, without
/// which iOS silences the app and closes picture in picture in the background.
/// YouTube changes its player often, so this may need updating.
enum BackgroundPlayback {
    // Playback setup and microphone changes share an ordered background queue.
    nonisolated static let audioQueue = DispatchQueue(label: "OrcaBrowser.audio", qos: .userInitiated)

    /// Lets web audio keep playing with the screen locked or the app in the
    /// background. Voice search switches to recording and restores this after.
    static func configureAudioSession() {
        Self.audioQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
    }

    /// The script message handler the page reports picture in picture changes to.
    nonisolated static let pictureInPictureMessageName = "orcaPictureInPicture"

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart,
                     forMainFrameOnly: false, in: .page)
    }

    private static let source = """
    (() => {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;

      // Always visible, so YouTube doesn't pause on a tab switch or in the background.
      const always = (proto, name, value) =>
        Object.defineProperty(proto, name, { configurable: true, get: () => value });
      always(Document.prototype, 'hidden', false);
      always(Document.prototype, 'webkitHidden', false);
      always(Document.prototype, 'visibilityState', 'visible');
      always(Document.prototype, 'webkitVisibilityState', 'visible');

      // Capture listeners on window run before any of the page's own, so
      // these events never reach YouTube. The system picture in picture
      // window doesn't depend on them.
      // The app is told when picture in picture opens or closes, so it can
      // switch back to this tab when you return to the video.
      const tellApp = () => {
        const active = [...document.querySelectorAll('video')].some(inPictureInPicture);
        window.webkit?.messageHandlers?.\(pictureInPictureMessageName)?.postMessage({ active });
      };
      const swallow = event => {
        if (event.type === 'webkitpresentationmodechanged') tellApp();
        event.stopImmediatePropagation();
      };
      for (const type of ['visibilitychange', 'webkitvisibilitychange',
                          'webkitpresentationmodechanged',
                          'enterpictureinpicture', 'leavepictureinpicture']) {
        window.addEventListener(type, swallow, true);
      }

      const video = HTMLVideoElement.prototype;
      const modeGetter = Object.getOwnPropertyDescriptor(video, 'webkitPresentationMode')?.get;
      const realMode = element => modeGetter ? modeGetter.call(element) : 'inline';
      const inPictureInPicture = element => realMode(element) === 'picture-in-picture';

      // Report picture in picture as inline, so YouTube has nothing to undo.
      if (modeGetter) {
        Object.defineProperty(video, 'webkitPresentationMode', {
          configurable: true,
          get() { return inPictureInPicture(this) ? 'inline' : realMode(this); }
        });
      }

      // Ignore the page's requests to leave picture in picture. Closing it or
      // returning to the app from the floating window is native and still works.
      const setMode = video.webkitSetPresentationMode;
      if (setMode) {
        video.webkitSetPresentationMode = function (mode) {
          if (inPictureInPicture(this) && mode !== 'picture-in-picture') return;
          return setMode.call(this, mode);
        };
      }
      const exitFullscreen = video.webkitExitFullscreen;
      if (exitFullscreen) {
        video.webkitExitFullscreen = function () {
          if (inPictureInPicture(this)) return;
          return exitFullscreen.call(this);
        };
      }
      const exitPictureInPicture = Document.prototype.exitPictureInPicture;
      if (exitPictureInPicture) {
        Document.prototype.exitPictureInPicture = function () {
          if ([...document.querySelectorAll('video')].some(inPictureInPicture)) {
            return Promise.resolve();
          }
          return exitPictureInPicture.call(this);
        };
      }

      // Keep the picture in picture button available.
      Object.defineProperty(video, 'disablePictureInPicture', {
        configurable: true, get: () => false, set: () => {}
      });
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (this instanceof HTMLVideoElement && String(name).toLowerCase() === 'disablepictureinpicture') return;
        return setAttribute.call(this, name, value);
      };
    })();
    """
}
