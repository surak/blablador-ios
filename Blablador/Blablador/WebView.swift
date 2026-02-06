import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum WebConstants {
    static let startURL = URL(string: "https://staging.helmholtz-blablador.fz-juelich.de")
}

final class WebViewStore: NSObject, ObservableObject {
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var currentURL: URL?

    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences

        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

#if os(iOS)
        if #available(iOS 16.0, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }
#endif

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

#if os(macOS)
        webView.setValue(true, forKey: "autofillEnabled")
#endif

        if let startURL = WebConstants.startURL {
            webView.load(URLRequest(url: startURL))
        }
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

}

extension WebViewStore: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateState(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateState(from: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            let credential = URLCredential(user: "", password: "", persistence: .none)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func updateState(from webView: WKWebView) {
        DispatchQueue.main.async {
            self.canGoBack = webView.canGoBack
            self.canGoForward = webView.canGoForward
            self.currentURL = webView.url
        }
    }
}

#if os(iOS)
struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#elseif os(macOS)
struct WebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

struct WebContainerView: View {
    @StateObject private var store = WebViewStore()

    var body: some View {
#if os(macOS)
        NavigationStack {
            WebView(webView: store.webView)
                .frame(minWidth: 800, minHeight: 600)
                .toolbar {
                    ToolbarItemGroup(placement: .automatic) {
                        Button(action: { store.goBack() }) {
                            Label("Back", systemImage: "arrow.left")
                        }
                        .disabled(!store.canGoBack)
                        Button(action: { store.goForward() }) {
                            Label("Forward", systemImage: "arrow.right")
                        }
                        .disabled(!store.canGoForward)
                        Button(action: { store.reload() }) {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        Button(action: openPasswordsForCurrentSite) {
                            Label("Open Passwords", systemImage: "key.fill")
                        }
                        Button(action: openInSafari) {
                            Label("Open in Safari", systemImage: "safari")
                        }
                        Button(action: shareCurrentURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
        }
#else
        WebView(webView: store.webView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
    }

#if os(macOS)
    private func openInSafari() {
        if let url = store.currentURL ?? WebConstants.startURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPasswordsForCurrentSite() {
        if let host = (store.currentURL ?? WebConstants.startURL)?.host {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(host, forType: .string)
        }

        let passwordsAppURL = URL(fileURLWithPath: "/System/Applications/Passwords.app")
        if FileManager.default.fileExists(atPath: passwordsAppURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: passwordsAppURL, configuration: configuration)
        } else if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Passwords") {
            NSWorkspace.shared.open(settingsURL)
        } else if let settingsURL = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(settingsURL)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let url = store.currentURL ?? WebConstants.startURL {
                store.webView.load(URLRequest(url: url))
            }
        }
    }
#endif

    private func shareCurrentURL() {
        guard let url = store.currentURL else { return }
#if os(iOS)
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = store.webView

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = scene.windows.first?.rootViewController else {
            return
        }

        rootViewController.present(controller, animated: true)
#elseif os(macOS)
        let sharingService = NSSharingServicePicker(items: [url])
        sharingService.show(relativeTo: .zero, of: store.webView, preferredEdge: .minY)
#endif
    }
}