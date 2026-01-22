import SwiftUI
import WebKit
import UIKit

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

        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

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

    private func updateState(from webView: WKWebView) {
        DispatchQueue.main.async {
            self.canGoBack = webView.canGoBack
            self.canGoForward = webView.canGoForward
            self.currentURL = webView.url
        }
    }
}

struct WebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct WebContainerView: View {
    @StateObject private var store = WebViewStore()

    var body: some View {
        NavigationStack {
            WebView(webView: store.webView)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(action: store.goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!store.canGoBack)

                        Button(action: store.goForward) {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!store.canGoForward)

                        Spacer()

                        Button(action: store.reload) {
                            Image(systemName: "arrow.clockwise")
                        }

                        Button(action: shareCurrentURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(store.currentURL == nil)
                    }
                }
        }
    }

    private func shareCurrentURL() {
        guard let url = store.currentURL else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = store.webView

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = scene.windows.first?.rootViewController else {
            return
        }

        rootViewController.present(controller, animated: true)
    }
}
