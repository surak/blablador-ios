import SwiftUI
import WebKit

/// Runs Python on the device with Pyodide (CPython compiled to WebAssembly) in a hidden web view, for the
/// run_python tool. The browser sandbox keeps code away from the user's files and apps; matplotlib figures
/// come back as PNG images.
@MainActor
final class PythonRunner: NSObject, WKNavigationDelegate {
    static let shared = PythonRunner()
    static let pyodideURL = "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/"
    /// Longest run, including the first download of Pyodide and packages.
    static let timeout: Duration = .seconds(180)

    struct Result {
        var output = ""
        var value: String?
        var error: String?
        var images: [Data] = []
    }

    enum RunnerError: LocalizedError {
        case timedOut, failed(String)
        var errorDescription: String? {
            switch self {
            case .timedOut: "The code ran longer than 3 minutes and was stopped."
            case let .failed(message): message
            }
        }
    }

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "run_python",
            "description": "Run Python code on the user's device (Pyodide: numpy, pandas, matplotlib, scipy, sympy, scikit-learn and more; other pure-Python packages via micropip). Use it for calculations, data analysis and plots. Print what you need to see; the value of the last line is returned too. Matplotlib figures are shown to the user automatically. Variables don't persist between calls.",
            "parameters": [
                "type": "object",
                "properties": [
                    "code": ["type": "string", "description": "The Python code to run."]
                ],
                "required": ["code"]
            ]
        ]
    ]

    static let systemPrompt = "You can run Python with run_python for calculations, data analysis and plots; use it instead of computing by hand. Files the user attached are in /data as text. Figures you create with matplotlib are shown to the user automatically, so don't save them to files or include image links. There is no internet access from the code except sites that allow it."

    private var webView: WKWebView?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// Runs code with the given text files placed in /data.
    func run(_ code: String, files: [String: String] = [:]) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask { try await self.execute(code, files: files) }
            group.addTask {
                try await Task.sleep(for: Self.timeout)
                throw RunnerError.timedOut
            }
            defer { group.cancelAll() }
            do {
                return try await group.next()!
            } catch RunnerError.timedOut {
                // A runaway loop blocks the page; start over with a fresh one next time.
                reset()
                throw RunnerError.timedOut
            }
        }
    }

    private func execute(_ code: String, files: [String: String]) async throws -> Result {
        let webView = try await loadedWebView()
        let raw = try await webView.callAsyncJavaScript("return await runPython(code, files);",
                                                        arguments: ["code": code, "files": files], contentWorld: .page)
        guard let json = raw as? String, let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw RunnerError.failed("Python returned no result.")
        }
        var result = Result()
        result.output = object["out"] as? String ?? ""
        result.value = object["result"] as? String
        result.error = object["error"] as? String
        result.images = (object["images"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
        return result
    }

    private func loadedWebView() async throws -> WKWebView {
        if let webView, ready { return webView }
        if webView == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default() // caches Pyodide between runs
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            webView.navigationDelegate = self
#if os(iOS)
            // Off-screen web views may be suspended; keep it in the window, invisible.
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
            if let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first {
                webView.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
                window.addSubview(webView)
            }
#endif
            self.webView = webView
            webView.loadHTMLString(Self.page, baseURL: URL(string: "https://blablador.local/"))
        }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
        guard let webView else { throw RunnerError.failed("Python could not start.") }
        return webView
    }

    private func reset() {
        webView?.removeFromSuperview()
        webView = nil
        ready = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        readyWaiters.forEach { $0.resume() }
        readyWaiters = []
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        reset()
        readyWaiters.forEach { $0.resume(throwing: error) }
        readyWaiters = []
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reset() }

    private static let page = """
    <!doctype html><html><head><meta charset="utf-8">
    <script src="\(pyodideURL)pyodide.js"></script>
    </head><body><script>
    let pyodideReady = null;
    function boot() {
      if (!pyodideReady) {
        pyodideReady = loadPyodide({ indexURL: '\(pyodideURL)' }).then(py => {
          py.runPython("import os; os.environ['MPLBACKEND'] = 'AGG'");
          return py;
        });
        pyodideReady.catch(() => { pyodideReady = null; });
      }
      return pyodideReady;
    }
    async function runPython(code, files) {
      const py = await boot();
      let out = '';
      const append = s => { if (out.length < 200000) out += s + '\\n'; };
      py.setStdout({ batched: append });
      py.setStderr({ batched: append });
      try { py.FS.mkdirTree('/data'); } catch (e) {}
      for (const [name, text] of Object.entries(files || {})) {
        try { py.FS.writeFile('/data/' + name, text); } catch (e) {}
      }
      let error = null, result = null, images = [];
      const globals = py.toPy({});
      try {
        await py.loadPackagesFromImports(code, { messageCallback: () => {} });
        const value = await py.runPythonAsync(code, { globals });
        if (value !== undefined && value !== null) {
          result = String(value);
          if (value.destroy) value.destroy();
        }
      } catch (e) {
        error = String(e.message || e);
      }
      try {
        const figures = py.runPython(`
    import sys
    _figures = []
    if 'matplotlib.pyplot' in sys.modules:
        import io, base64
        import matplotlib.pyplot as plt
        for _number in plt.get_fignums():
            _buffer = io.BytesIO()
            plt.figure(_number).savefig(_buffer, format='png', dpi=144, bbox_inches='tight')
            _figures.append(base64.b64encode(_buffer.getvalue()).decode())
        plt.close('all')
    _figures
    `);
        images = figures.toJs();
        figures.destroy();
      } catch (e) {}
      globals.destroy();
      return JSON.stringify({ out, error, result, images });
    }
    boot();
    </script></body></html>
    """
}
