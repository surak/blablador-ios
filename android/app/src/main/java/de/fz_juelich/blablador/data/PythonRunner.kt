package de.fz_juelich.blablador.data

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebSettings
import android.webkit.WebView
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs Python on the device with Pyodide (CPython compiled to WebAssembly) in a hidden WebView, for the
 * run_python tool. The browser sandbox keeps code away from the user's files and apps; matplotlib figures
 * come back as PNG images.
 */
class PythonRunner(context: Context) {
    data class Result(val output: String, val value: String?, val error: String?, val images: List<ByteArray>)

    companion object {
        const val PYODIDE_URL = "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/"
        /** Longest run, including the first download of Pyodide and packages. */
        const val TIMEOUT_MS = 180_000L

        const val SYSTEM_PROMPT = "You can run Python with run_python for calculations, data analysis and plots; use it instead of computing by hand. Files the user attached are in /data as text. Figures you create with matplotlib are shown to the user automatically, so don't save them to files or include image links. There is no internet access from the code except sites that allow it."

        private val PAGE = """
<!doctype html><html><head><meta charset="utf-8">
<script src="${PYODIDE_URL}pyodide.js"></script>
</head><body><script>
let pyodideReady = null;
function boot() {
  if (!pyodideReady) {
    pyodideReady = loadPyodide({ indexURL: '${PYODIDE_URL}' }).then(py => {
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
  const append = s => { if (out.length < 200000) out += s + '\n'; };
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
function start(id, code, files) {
  runPython(code, files)
    .then(json => Bridge.done(id, json))
    .catch(e => Bridge.done(id, JSON.stringify({ out: '', error: String(e.message || e), result: null, images: [] })));
}
boot();
</script></body></html>
"""
    }

    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private val runs = ConcurrentHashMap<Int, CompletableDeferred<String>>()
    private val nextId = AtomicInteger(1)

    /** Answers from the page, one per run. */
    private inner class Bridge {
        @JavascriptInterface
        fun done(id: Int, json: String) { runs.remove(id)?.complete(json) }
    }

    /** Runs code with the given text files placed in /data. */
    suspend fun run(code: String, files: Map<String, String> = emptyMap()): Result {
        val id = nextId.getAndIncrement()
        val answer = CompletableDeferred<String>()
        runs[id] = answer
        val args = BlabladorApi.json.encodeToString(JsonArray.serializer(), JsonArray(listOf(
            kotlinx.serialization.json.JsonPrimitive(code),
            buildJsonObject { files.forEach { (name, text) -> put(name, text) } },
        )))
        withContext(Dispatchers.Main) {
            // Waits for the page to load: the script runs once pyodide.js and start() exist.
            webView().evaluateJavascript("(function wait(){ if (typeof start === 'function') { const a = $args; start($id, a[0], a[1]); } else setTimeout(wait, 100); })();", null)
        }
        val json = try {
            withTimeout(TIMEOUT_MS) { answer.await() }
        } catch (e: TimeoutCancellationException) {
            runs.remove(id)
            // A runaway loop blocks the page; start over with a fresh one next time.
            withContext(Dispatchers.Main) { reset() }
            throw IllegalStateException("The code ran longer than 3 minutes and was stopped.")
        }
        val result = BlabladorApi.json.parseToJsonElement(json).jsonObject
        val images = (result["images"] as? JsonArray).orEmpty().mapNotNull {
            runCatching { Base64.decode(it.jsonPrimitive.content, Base64.DEFAULT) }.getOrNull()
        }
        return Result(
            output = result["out"]?.jsonPrimitive?.contentOrNull.orEmpty(),
            value = result["result"]?.jsonPrimitive?.contentOrNull,
            error = result["error"]?.jsonPrimitive?.contentOrNull,
            images = images,
        )
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun webView(): WebView = webView ?: WebView(appContext).also { view ->
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true // lets Pyodide cache its packages
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        view.addJavascriptInterface(Bridge(), "Bridge")
        view.loadDataWithBaseURL("https://blablador.local/", PAGE, "text/html", "utf-8", null)
        webView = view
    }

    private fun reset() {
        webView?.destroy()
        webView = null
        runs.values.forEach { it.completeExceptionally(IllegalStateException("Python was restarted.")) }
        runs.clear()
    }
}
