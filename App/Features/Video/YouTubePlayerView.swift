import SwiftUI
import WebKit

/// Embedded YouTube player that reports `currentTime` to Swift.
/// Tries the IFrame API first; on embed-blocked errors (101 / 150 / 152)
/// falls back to the full watch page so music videos still play.
struct YouTubePlayerView: NSViewRepresentable {
    let videoID: String
    var onTimeUpdate: (TimeInterval) -> Void
    var onReady: (() -> Void)?
    var seekRequest: Binding<TimeInterval?>

    func makeCoordinator() -> Coordinator {
        Coordinator(videoID: videoID, onTimeUpdate: onTimeUpdate, onReady: onReady)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "timeUpdate")
        userController.add(context.coordinator, name: "playerReady")
        userController.add(context.coordinator, name: "playerError")

        let config = WKWebViewConfiguration()
        config.userContentController = userController
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        #if os(macOS)
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        if #available(macOS 12.3, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        #endif

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.loadEmbed(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onTimeUpdate = onTimeUpdate
        context.coordinator.onReady = onReady
        context.coordinator.videoID = videoID

        if context.coordinator.loadedVideoID != videoID {
            context.coordinator.loadEmbed(in: webView)
        }

        if let seek = seekRequest.wrappedValue {
            let seconds = seek
            webView.evaluateJavaScript("window.melingoSeekTo && window.melingoSeekTo(\(seconds));", completionHandler: nil)
            DispatchQueue.main.async {
                if seekRequest.wrappedValue == seek {
                    seekRequest.wrappedValue = nil
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        let uc = nsView.configuration.userContentController
        uc.removeScriptMessageHandler(forName: "timeUpdate")
        uc.removeScriptMessageHandler(forName: "playerReady")
        uc.removeScriptMessageHandler(forName: "playerError")
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var videoID: String
        var loadedVideoID: String?
        var onTimeUpdate: (TimeInterval) -> Void
        var onReady: (() -> Void)?
        weak var webView: WKWebView?
        private var usedWatchFallback = false

        init(videoID: String, onTimeUpdate: @escaping (TimeInterval) -> Void, onReady: (() -> Void)?) {
            self.videoID = videoID
            self.onTimeUpdate = onTimeUpdate
            self.onReady = onReady
        }

        func loadEmbed(in webView: WKWebView) {
            usedWatchFallback = false
            loadedVideoID = videoID
            webView.loadHTMLString(Self.embedHTML(videoID: videoID), baseURL: URL(string: "https://www.youtube.com"))
        }

        func loadWatchFallback(in webView: WKWebView) {
            usedWatchFallback = true
            loadedVideoID = videoID
            guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)&hl=en") else { return }
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            webView.load(request)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "playerReady":
                DispatchQueue.main.async { self.onReady?() }
            case "playerError":
                let code: Int
                if let n = message.body as? Int {
                    code = n
                } else if let n = message.body as? NSNumber {
                    code = n.intValue
                } else {
                    code = -1
                }
                // 101 / 150 / 152 = embedding disabled / unavailable in iframe.
                if [101, 150, 152].contains(code), !usedWatchFallback, let webView {
                    DispatchQueue.main.async {
                        self.loadWatchFallback(in: webView)
                    }
                }
            case "timeUpdate":
                let value: Double?
                if let number = message.body as? Double {
                    value = number
                } else if let number = message.body as? NSNumber {
                    value = number.doubleValue
                } else {
                    value = nil
                }
                if let value {
                    DispatchQueue.main.async { self.onTimeUpdate(value) }
                }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard usedWatchFallback else { return }
            webView.evaluateJavaScript(Self.watchBridgeJS, completionHandler: nil)
        }

        private static func embedHTML(videoID: String) -> String {
            """
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
              <style>
                html, body { margin: 0; padding: 0; background: #0b0b0b; height: 100%; overflow: hidden; }
                #player { position: absolute; inset: 0; width: 100%; height: 100%; }
              </style>
            </head>
            <body>
              <div id="player"></div>
              <script>
                var player;
                var lastPosted = -1;
                function postTime() {
                  if (!player || typeof player.getCurrentTime !== 'function') return;
                  try {
                    var t = player.getCurrentTime();
                    if (Math.abs(t - lastPosted) >= 0.05) {
                      lastPosted = t;
                      window.webkit.messageHandlers.timeUpdate.postMessage(t);
                    }
                  } catch (e) {}
                }
                window.melingoSeekTo = function(seconds) {
                  if (player && typeof player.seekTo === 'function') {
                    player.seekTo(seconds, true);
                    postTime();
                  }
                };
                function onYouTubeIframeAPIReady() {
                  player = new YT.Player('player', {
                    width: '100%',
                    height: '100%',
                    videoId: '\(videoID)',
                    host: 'https://www.youtube.com',
                    playerVars: {
                      autoplay: 0,
                      playsinline: 1,
                      rel: 0,
                      modestbranding: 1,
                      enablejsapi: 1,
                      origin: 'https://www.youtube.com',
                      widget_referrer: 'https://www.youtube.com'
                    },
                    events: {
                      onReady: function() {
                        window.webkit.messageHandlers.playerReady.postMessage(true);
                        setInterval(postTime, 100);
                      },
                      onStateChange: function() { postTime(); },
                      onError: function(event) {
                        var code = (event && event.data != null) ? event.data : -1;
                        window.webkit.messageHandlers.playerError.postMessage(code);
                      }
                    }
                  });
                }
              </script>
              <script src="https://www.youtube.com/iframe_api"></script>
            </body>
            </html>
            """
        }

        /// Bridge for full watch-page fallback (when embed is blocked).
        private static let watchBridgeJS = """
        (function() {
          if (window.__melingoWatchBridge) return;
          window.__melingoWatchBridge = true;
          var lastPosted = -1;
          function videoEl() {
            return document.querySelector('video.html5-main-video')
              || document.querySelector('video');
          }
          window.melingoSeekTo = function(seconds) {
            var v = videoEl();
            if (v) {
              try { v.currentTime = seconds; } catch (e) {}
            }
          };
          function postTime() {
            var v = videoEl();
            if (!v) return;
            var t = v.currentTime || 0;
            if (Math.abs(t - lastPosted) >= 0.05) {
              lastPosted = t;
              try { window.webkit.messageHandlers.timeUpdate.postMessage(t); } catch (e) {}
            }
          }
          setInterval(postTime, 200);
          try { window.webkit.messageHandlers.playerReady.postMessage(true); } catch (e) {}
        })();
        """
    }
}
