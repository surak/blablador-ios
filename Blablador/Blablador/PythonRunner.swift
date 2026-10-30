import SwiftUI
import UniformTypeIdentifiers
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

    static let systemPrompt = "You can run Python with run_python for calculations, data analysis and plots; use it instead of computing by hand. Files the user attached are in /data: data files (CSV, Excel, JSON…) as they are, PDFs and other documents as .txt text. Figures you create with matplotlib are shown to the user automatically, so don't save them to files or include image links. There is no internet access from the code except sites that allow it."

    private var webView: WKWebView?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// Runs code with the given files placed in /data.
    func run(_ code: String, files: [String: Data] = [:]) async throws -> Result {
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

    private func execute(_ code: String, files: [String: Data]) async throws -> Result {
        let webView = try await loadedWebView()
        let encoded = files.mapValues { $0.base64EncodedString() }
        let raw = try await webView.callAsyncJavaScript("return await runPython(code, files);",
                                                        arguments: ["code": code, "files": encoded], contentWorld: .page)
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
      for (const [name, base64] of Object.entries(files || {})) {
        try { py.FS.writeFile('/data/' + name, Uint8Array.from(atob(base64), c => c.charCodeAt(0))); } catch (e) {}
      }
      let error = null, result = null, images = [];
      const globals = py.toPy({});
      try {
        await py.loadPackagesFromImports(code, { messageCallback: () => {} });
        // Excel support isn't bundled with Pyodide; it comes from PyPI on first use.
        if (/read_excel|to_excel|openpyxl|\\.xlsx/.test(code)) {
          await py.loadPackage('micropip', { messageCallback: () => {} });
          await py.pyimport('micropip').install('openpyxl');
        }
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

/// Data files attached to a chat (CSV, Excel, JSON…), kept encrypted and handed to Python as real files in /data.
enum DataFiles {
    static let extensions: Set<String> = ["csv", "tsv", "json", "jsonl", "xlsx", "xls", "parquet", "txt", "xml", "yaml", "yml", "dat", "npy", "npz"]
    static let maxSize = 25 * 1024 * 1024
    private static let previewLines = 40

    enum DataFileError: LocalizedError {
        case tooLarge
        var errorDescription: String? { "Data files can be at most 25 MB." }
    }

    static func supports(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// For the file picker.
    static var contentTypes: [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) } + [.commaSeparatedText, .tabSeparatedText, .json, .plainText]
    }

    /// Stores the file encrypted and describes it for the model, with the first lines of text formats.
    static func attach(_ url: URL) throws -> DocumentAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= maxSize else { throw DataFileError.tooLarge }
        let name = url.lastPathComponent.replacingOccurrences(of: "/", with: "_")
        let stored = UUID().uuidString + "." + url.pathExtension.lowercased()
        EncryptedStorage.write(data, to: directory.appendingPathComponent(stored))
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        var text = "Data file \(name) (\(size)), available to run_python as /data/\(name)."
        if let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
           !["xlsx", "xls", "parquet", "npy", "npz"].contains(url.pathExtension.lowercased()) {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            text += " \(lines.count) lines; the first \(min(lines.count, previewLines)):\n" + lines.prefix(previewLines).map { String($0.prefix(500)) }.joined(separator: "\n")
        } else {
            text += " Binary file; read it with Python (for Excel: pandas.read_excel)."
        }
        return DocumentAttachment(name: name, text: text, pageCount: 0, dataFile: stored)
    }

    static func data(for stored: String) -> Data? {
        EncryptedStorage.readFile(directory.appendingPathComponent(stored), isPlain: { _ in false })
    }

    static func delete(_ names: [String]) {
        for name in names { EncryptedStorage.delete(directory.appendingPathComponent(name)) }
    }

    private static var directory: URL {
        let url = AppFolder.url.appendingPathComponent("DataFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
