import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// What a web block shows.
enum WebBlockKind: Equatable {
    /// Markdown with inline or display maths (marked + KaTeX).
    case markdown
    /// A Mermaid diagram.
    case mermaid
    /// A complete HTML or SVG document written by the model.
    case document
}

/// Maths, diagrams and HTML previews in a web view sized to its content. Content changes are pushed in with
/// JavaScript, so streaming text doesn't reload the page. Links open in the browser, only http(s) and mailto.
struct WebBlock: View {
    let kind: WebBlockKind
    let content: String
    var fixedHeight: CGFloat?
    @Environment(\.textScale) private var textScale
    @State private var height: CGFloat = 40

    var body: some View {
        WebBlockView(kind: kind, content: content, fontSize: 15 * textScale, height: $height)
            .frame(height: fixedHeight ?? max(height, 24))
    }

    static func page(kind: WebBlockKind, fontSize: CGFloat) -> String {
        let scripts: String
        switch kind {
        case .markdown:
            scripts = """
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
            <script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>
            """
        case .mermaid:
            scripts = #"<script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.0/dist/mermaid.min.js"></script>"#
        case .document:
            scripts = ""
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(scripts)
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; }
        body { font: \(Int(fontSize))px -apple-system, system-ui, sans-serif; line-height: 1.45; color: CanvasText; overflow-x: auto; }
        #content > :first-child { margin-top: 0; } #content > :last-child { margin-bottom: 0; }
        a { color: #8b5cf6; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
        table { border-collapse: collapse; } td, th { border: 1px solid #8884; padding: 4px 8px; }
        .katex-display { overflow-x: auto; overflow-y: hidden; padding: 4px 0; }
        .mermaid { text-align: center; }
        </style></head><body><div id="content"></div>
        <script>
        function reportSize() {
          const h = Math.ceil(document.getElementById('content').getBoundingClientRect().height) + 2;
          window.webkit.messageHandlers.size.postMessage(h);
        }
        new ResizeObserver(reportSize).observe(document.getElementById('content'));
        let mermaidReady = false;
        async function render(text, kind) {
          const box = document.getElementById('content');
          if (kind === 'markdown') {
            // Keep maths away from the Markdown parser, then typeset it.
            const maths = [];
            const hold = s => { maths.push(s); return '@@MATH' + (maths.length - 1) + '@@'; };
            // Inline $…$ is rewritten to the backslash-paren form, so prices like "$5 and $10" are never read as maths.
            let source = text.replace(/\\$\\$[\\s\\S]+?\\$\\$|\\\\\\[[\\s\\S]+?\\\\\\]|\\\\\\([\\s\\S]+?\\\\\\)/g, hold)
              .replace(/(?<![\\\\$\\w])\\$(?![\\s\\d])([^$\\n]+?)(?<![\\s\\\\])\\$(?![\\w$])/g, (_, m) => hold('\\\\(' + m + '\\\\)'));
            let html = window.marked ? marked.parse(source) : source.replace(/</g, '&lt;');
            html = html.replace(/@@MATH(\\d+)@@/g, (_, i) => maths[i].replace(/&/g, '&amp;').replace(/</g, '&lt;'));
            box.innerHTML = html;
            if (window.renderMathInElement) renderMathInElement(box, { delimiters: [
              { left: '$$', right: '$$', display: true }, { left: '\\\\[', right: '\\\\]', display: true },
              { left: '\\\\(', right: '\\\\)', display: false }],
              throwOnError: false });
          } else if (kind === 'mermaid') {
            if (!window.mermaid) { box.textContent = text; reportSize(); return; }
            if (!mermaidReady) {
              mermaid.initialize({ startOnLoad: false, securityLevel: 'strict',
                theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default' });
              mermaidReady = true;
            }
            try {
              const { svg } = await mermaid.render('diagram' + Date.now(), text);
              box.innerHTML = '<div class="mermaid">' + svg + '</div>';
            } catch (e) { box.textContent = 'Diagram error: ' + e.message; }
          }
          reportSize();
        }
        </script></body></html>
        """
    }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

private struct WebBlockView: PlatformViewRepresentable {
    let kind: WebBlockKind
    let content: String
    let fontSize: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "size")
        if kind == .document {
            // Report the document's height; scripts in it run, but can't reach the app or other sites' data.
            let script = "new ResizeObserver(() => window.webkit.messageHandlers.size.postMessage(Math.ceil(document.documentElement.scrollHeight))).observe(document.documentElement);"
            configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
#if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
#else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = kind == .document
        webView.scrollView.backgroundColor = .clear
#endif
        context.coordinator.webView = webView
        return webView
    }

    private func update(_ webView: WKWebView, context: Context) {
        context.coordinator.show(content, kind: kind, fontSize: fontSize)
    }

#if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ view: WKWebView, context: Context) { update(view, context: context) }
#else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ view: WKWebView, context: Context) { update(view, context: context) }
#endif

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        @Binding var height: CGFloat
        weak var webView: WKWebView?
        private var loaded = false
        private var pageLoaded = false
        private var shown: String?
        private var pending: String?
        private var kind = WebBlockKind.markdown

        init(height: Binding<CGFloat>) { _height = height }

        func show(_ content: String, kind: WebBlockKind, fontSize: CGFloat) {
            guard content != shown, let webView else { return }
            shown = content
            self.kind = kind
            if kind == .document {
                pageLoaded = false
                webView.loadHTMLString(content, baseURL: nil)
                return
            }
            if !loaded {
                loaded = true
                pending = content
                webView.loadHTMLString(WebBlock.page(kind: kind, fontSize: fontSize), baseURL: URL(string: "https://blablador.local/"))
            } else if pageLoaded {
                run(content)
            } else {
                pending = content
            }
        }

        private func run(_ content: String) {
            guard let data = try? JSONSerialization.data(withJSONObject: [content]),
                  let json = String(data: data, encoding: .utf8) else { return }
            let kindName = kind == .mermaid ? "mermaid" : "markdown"
            webView?.evaluateJavaScript("render(\(json)[0], '\(kindName)')")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            if let pending {
                self.pending = nil
                run(pending)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only the page itself loads in place; links open in the browser.
            if action.navigationType == .linkActivated, let url = action.request.url {
                decisionHandler(.cancel)
                if SafeLinks.allows(url) {
#if os(macOS)
                    NSWorkspace.shared.open(url)
#else
                    UIApplication.shared.open(url)
#endif
                }
                return
            }
            decisionHandler(action.targetFrame?.isMainFrame == false || action.navigationType == .other || action.navigationType == .reload ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let value = message.body as? Double, value > 0 { height = min(CGFloat(value), 4_000) }
            else if let value = message.body as? Int, value > 0 { height = min(CGFloat(value), 4_000) }
        }
    }
}

/// A fenced block the model wrote as HTML, SVG or Mermaid: shown rendered, with the code a tap away.
struct ArtifactBlock: View {
    let language: String
    let code: String
    @State private var showCode = false
    @State private var fullScreen = false

    private var kind: WebBlockKind { language == "mermaid" ? .mermaid : .document }
    private var document: String {
        language == "svg" && !code.lowercased().contains("<html")
            ? "<!doctype html><html><head><meta name=viewport content='width=device-width'><style>body{margin:0}svg{max-width:100%;height:auto}</style></head><body>\(code)</body></html>"
            : code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $showCode) {
                    Text("Preview").tag(false)
                    Text("Code").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if kind == .document {
                    Button { fullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .help("Open larger")
                }
                CodeActions(language: language, code: code)
            }
            .buttonStyle(.plain)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showCode {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .scaledFont(.footnote, design: .monospaced)
                        .textSelection(.enabled)
                        .padding(12)
                }
            } else {
                WebBlock(kind: kind, content: kind == .mermaid ? code : document)
                    .frame(maxHeight: kind == .document ? 600 : .infinity)
                    .padding(8)
                    .background(kind == .document ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $fullScreen) {
            NavigationStack {
                WebBlock(kind: .document, content: document, fixedHeight: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { fullScreen = false } }
                    }
            }
#if os(macOS)
            .frame(minWidth: 800, minHeight: 600)
#endif
        }
    }
}

/// Copy, share and save buttons for a code block.
struct CodeActions: View {
    let language: String
    let code: String
    @State private var copied = false
    @State private var saving = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Clipboard.copy(code)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            Button { saving = true } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .labelStyle(.iconOnly)
                .help("Save as a file")
        }
        .fileExporter(isPresented: $saving, document: CodeFile(text: code), contentType: CodeFile.type(for: language),
                      defaultFilename: "snippet.\(CodeFile.fileExtension(for: language))") { _ in }
    }
}

struct CodeFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

    static func fileExtension(for language: String) -> String {
        let language = language.lowercased().trimmingCharacters(in: .whitespaces)
        let known = ["python": "py", "py": "py", "javascript": "js", "js": "js", "typescript": "ts", "ts": "ts", "swift": "swift",
                     "kotlin": "kt", "java": "java", "c": "c", "cpp": "cpp", "c++": "cpp", "csharp": "cs", "go": "go", "rust": "rs",
                     "ruby": "rb", "php": "php", "html": "html", "css": "css", "svg": "svg", "json": "json", "yaml": "yaml", "yml": "yaml",
                     "toml": "toml", "xml": "xml", "sql": "sql", "bash": "sh", "sh": "sh", "zsh": "sh", "shell": "sh", "markdown": "md",
                     "md": "md", "r": "r", "julia": "jl", "latex": "tex", "tex": "tex", "mermaid": "mmd", "dockerfile": "Dockerfile"]
        return known[language] ?? (language.isEmpty || language.count > 10 ? "txt" : language)
    }

    static func type(for language: String) -> UTType {
        UTType(filenameExtension: fileExtension(for: language)) ?? .plainText
    }
}

/// Inline maths like $x^2$ or \(x\), but not prices like "$5 and $10".
enum MathDetection {
    static func hasInlineMath(_ text: String) -> Bool {
        text.range(of: #"\\\(.+?\\\)"#, options: .regularExpression) != nil
            || text.range(of: #"(?<![\\$\w])\$(?![\s\d])[^$\n]+?(?<![\s\\])\$(?![\w$])"#, options: .regularExpression) != nil
    }
}
