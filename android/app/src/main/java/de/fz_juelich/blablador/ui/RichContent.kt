package de.fz_juelich.blablador.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.SaveAlt
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/** What a web block shows. */
enum class WebBlockKind {
    /** Markdown with inline or display maths (marked + KaTeX). */
    Markdown,
    /** A Mermaid diagram. */
    Mermaid,
    /** A complete HTML or SVG document written by the model. */
    Document,
}

/** Inline maths like $x^2$ or \(x\), but not prices like "$5 and $10". */
object MathDetection {
    private val parens = Regex("""\\\(.+?\\\)""")
    private val dollars = Regex("""(?<![\\$\w])\$(?![\s\d])[^$\n]+?(?<![\s\\])\$(?![\w$])""")
    fun hasInlineMath(text: String) = parens.containsMatchIn(text) || dollars.containsMatchIn(text)
}

private const val SCRIPTS_MARKDOWN = """<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
<script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/marked@12.0.2/marked.min.js"></script>"""
private const val SCRIPTS_MERMAID = """<script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.0/dist/mermaid.min.js"></script>"""

/** Keeps track of what the web view shows, so streaming text is pushed in with JavaScript instead of reloading. */
private class WebBlockState {
    var shown: String? = null
    var loaded = false
    var pageLoaded = false
    var pending: String? = null
}

private fun hex(color: Color) = String.format("#%06X", 0xFFFFFF and color.toArgb())

/**
 * Maths, diagrams and HTML previews in a web view sized to its content. Links open in the browser, only
 * http(s) and mailto; the web view has no file access and keeps no storage.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WebBlock(kind: WebBlockKind, content: String, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    var height by remember { mutableIntStateOf(24) }
    val state = remember { WebBlockState() }
    val dark = isSystemInDarkTheme()
    val textColor = hex(MaterialTheme.colorScheme.onSurface)
    val fontSize = (MaterialTheme.typography.bodyLarge.fontSize.value).toInt().coerceAtLeast(12)

    fun run(view: WebView, text: String) {
        val json = JsonArray(listOf(JsonPrimitive(text))).toString()
        view.evaluateJavascript("render($json[0], '${if (kind == WebBlockKind.Mermaid) "mermaid" else "markdown"}')", null)
    }

    AndroidView(
        modifier = modifier.fillMaxWidth().height(height.dp),
        factory = { ctx ->
            WebView(ctx).apply {
                settings.javaScriptEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                settings.domStorageEnabled = false
                settings.databaseEnabled = false
                setBackgroundColor(if (kind == WebBlockKind.Document) android.graphics.Color.WHITE else android.graphics.Color.TRANSPARENT)
                isVerticalScrollBarEnabled = kind == WebBlockKind.Document
                val main = Handler(Looper.getMainLooper())
                addJavascriptInterface(object {
                    @JavascriptInterface
                    fun size(value: Double) { if (value > 0) main.post { height = value.toInt().coerceAtMost(4_000) } }
                }, "Bridge")
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        // Only the page itself loads in place; links open in the browser.
                        val url = request.url.toString()
                        if (isSafeLink(url)) runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
                        return true
                    }

                    override fun onPageFinished(view: WebView, url: String?) {
                        state.pageLoaded = true
                        if (kind == WebBlockKind.Document) {
                            view.evaluateJavascript("new ResizeObserver(() => Bridge.size(Math.ceil(document.documentElement.scrollHeight))).observe(document.documentElement);", null)
                        } else state.pending?.let { state.pending = null; run(view, it) }
                    }
                }
            }
        },
        update = { view ->
            if (content == state.shown) return@AndroidView
            state.shown = content
            when {
                kind == WebBlockKind.Document -> { state.pageLoaded = false; view.loadDataWithBaseURL(null, content, "text/html", "utf-8", null) }
                !state.loaded -> {
                    state.loaded = true
                    state.pending = content
                    val template = view.context.assets.open("webblock.html").use { it.readBytes().decodeToString() }
                        .replace("%SCRIPTS%", if (kind == WebBlockKind.Mermaid) SCRIPTS_MERMAID else SCRIPTS_MARKDOWN)
                        .replace("%FONT%", fontSize.toString())
                        .replace("%COLOR%", textColor)
                        .replace("%LINK%", hex(Brand.blue))
                        .replace("%SCHEME%", if (dark) "dark" else "light")
                        .replace("%DARK%", dark.toString())
                    view.loadDataWithBaseURL("https://blablador.local/", template, "text/html", "utf-8", null)
                }
                state.pageLoaded -> run(view, content)
                else -> state.pending = content
            }
        },
    )
}

/** A fenced block the model wrote as HTML, SVG or Mermaid: shown rendered, with the code a tap away. */
@Composable
fun ArtifactBlock(language: String, code: String) {
    var showCode by remember { mutableStateOf(false) }
    val kind = if (language == "mermaid") WebBlockKind.Mermaid else WebBlockKind.Document
    val document = if (language == "svg" && !code.contains("<html", ignoreCase = true))
        "<!doctype html><html><head><meta name=viewport content='width=device-width'><style>body{margin:0}svg{max-width:100%;height:auto}</style></head><body>$code</body></html>"
    else code
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp), verticalAlignment = Alignment.CenterVertically) {
            FilterChip(selected = !showCode, onClick = { showCode = false }, label = { Text("Preview") })
            androidx.compose.foundation.layout.Spacer(Modifier.padding(4.dp))
            FilterChip(selected = showCode, onClick = { showCode = true }, label = { Text("Code") })
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            CodeActions(language, code)
        }
        if (showCode) {
            Text(code, fontFamily = FontFamily.Monospace, fontSize = 13.sp,
                modifier = Modifier.horizontalScroll(rememberScrollState()).padding(start = 12.dp, end = 12.dp, bottom = 12.dp))
        } else {
            WebBlock(kind, if (kind == WebBlockKind.Mermaid) code else document,
                Modifier.padding(8.dp).heightIn(max = 600.dp).clip(RoundedCornerShape(8.dp)))
        }
    }
}

/** Copy and save buttons for a code block. */
@Composable
fun CodeActions(language: String, code: String) {
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val saver = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("text/plain")) { uri ->
        if (uri != null) runCatching { context.contentResolver.openOutputStream(uri)?.use { it.write(code.toByteArray()) } }
    }
    Row {
        IconButton(onClick = { clipboard.setText(AnnotatedString(code)) }) { Icon(Icons.Outlined.ContentCopy, "Copy code", Modifier.padding(2.dp)) }
        IconButton(onClick = { saver.launch("snippet.${CodeFile.fileExtension(language)}") }) { Icon(Icons.Outlined.SaveAlt, "Save as a file", Modifier.padding(2.dp)) }
    }
}

object CodeFile {
    fun fileExtension(language: String): String {
        val name = language.lowercase().trim()
        val known = mapOf("python" to "py", "py" to "py", "javascript" to "js", "js" to "js", "typescript" to "ts", "ts" to "ts", "swift" to "swift",
            "kotlin" to "kt", "java" to "java", "c" to "c", "cpp" to "cpp", "c++" to "cpp", "csharp" to "cs", "go" to "go", "rust" to "rs",
            "ruby" to "rb", "php" to "php", "html" to "html", "css" to "css", "svg" to "svg", "json" to "json", "yaml" to "yaml", "yml" to "yaml",
            "toml" to "toml", "xml" to "xml", "sql" to "sql", "bash" to "sh", "sh" to "sh", "zsh" to "sh", "shell" to "sh", "markdown" to "md",
            "md" to "md", "r" to "r", "julia" to "jl", "latex" to "tex", "tex" to "tex", "mermaid" to "mmd", "dockerfile" to "Dockerfile")
        return known[name] ?: if (name.isEmpty() || name.length > 10) "txt" else name
    }
}
