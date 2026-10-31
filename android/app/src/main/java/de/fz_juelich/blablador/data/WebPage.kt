package de.fz_juelich.blablador.data

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.util.concurrent.TimeUnit

/** Fetches a web page (or PDF) and reduces it to readable text, for the read_page tool. */
object WebPage {
    /** Characters of page text handed to the model. */
    const val MAX_CHARACTERS = 24_000

    data class Page(val title: String, val url: String, val text: String)

    class PageException(message: String) : Exception(message)

    /** Refuses local addresses, so a page or prompt can't make the app read from the user's own network. */
    fun isPublic(address: String): Boolean {
        val url = address.toHttpUrlOrNull() ?: return false
        val host = url.host.lowercase()
        if (host.isEmpty() || host == "localhost" || host.endsWith(".local") || host.endsWith(".localhost") || host.endsWith(".internal")) return false
        if (!host.contains('.') || host.contains(':') || host.startsWith("[")) return false // single labels and IPv6 literals
        val parts = host.split('.').map { it.toIntOrNull() }
        if (parts.size == 4 && parts.all { it != null }) {
            val (a, b) = parts[0]!! to parts[1]!!
            if (a == 10 || a == 127 || a == 0 || (a == 169 && b == 254) || (a == 192 && b == 168) ||
                (a == 172 && b in 16..31) || (a == 100 && b in 64..127)) return false
        }
        return true
    }

    suspend fun read(address: String): Page = withContext(Dispatchers.IO) {
        GoogleDocs.link(address.trim())?.let { return@withContext GoogleDocs.read(it, address.trim()) }
        var url = address.trim()
        if (url.startsWith("http://", ignoreCase = true)) url = "https://" + url.substring(7)
        if (!url.startsWith("https://", ignoreCase = true) || !isPublic(url)) throw PageException("Only public http(s) pages can be read.")
        val client = BlabladorApi.client.newBuilder().callTimeout(30, TimeUnit.SECONDS).build()
        val request = Request.Builder().url(url)
            .header("User-Agent", "Mozilla/5.0 (compatible; Blablador)")
            .header("Accept", "text/html,application/xhtml+xml,application/pdf,text/plain;q=0.9,*/*;q=0.5")
            .build()
        client.newCall(request).await().use { response ->
            val final = response.request.url.toString()
            if (!isPublic(final)) throw PageException("Only public http(s) pages can be read.")
            if (!response.isSuccessful) throw BlabladorException(response.code, "The page could not be loaded.")
            val type = response.header("Content-Type").orEmpty().lowercase()
            val data = response.body!!.byteStream().use { it.readNBytesCompat(3_000_000) }
            val name = final.substringBefore('?').trimEnd('/').substringAfterLast('/').ifEmpty { final }
            if (type.startsWith("application/pdf") || (data.size > 4 && String(data, 0, 4) == "%PDF")) {
                val text = PDDocument.load(data).use { PDFTextStripper().getText(it) }.trim()
                return@use Page(name, final, text.take(MAX_CHARACTERS))
            }
            if (type.isNotEmpty() && !(type.startsWith("text/") || "html" in type || "xml" in type || "json" in type)) {
                throw PageException("This link is not a web page or PDF (${type.substringBefore(';')}).")
            }
            val html = data.decodeToString()
            if ("html" !in type && !html.contains("<html", ignoreCase = true)) return@use Page(name, final, html.take(MAX_CHARACTERS))
            Page(title(html) ?: response.request.url.host, final, readableText(html).take(MAX_CHARACTERS))
        }
    }

    private fun java.io.InputStream.readNBytesCompat(limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(16_384)
        while (out.size() < limit) {
            val n = read(buffer, 0, minOf(buffer.size, limit - out.size()))
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    fun title(html: String): String? {
        val match = Regex("<title[^>]*>([\\s\\S]*?)</title>", RegexOption.IGNORE_CASE).find(html) ?: return null
        return decodeEntities(match.groupValues[1].replace(Regex("<[^>]+>"), "")).trim().ifEmpty { null }
    }

    private fun Regex.replaceIn(text: String, with: String) = replace(text, with)
    private fun ci(pattern: String) = Regex(pattern, RegexOption.IGNORE_CASE)

    /**
     * The page's main text: the <article> or <main> element when there is one, without scripts, menus and footers;
     * headings, list items and paragraphs kept on their own lines.
     */
    fun readableText(html: String): String {
        var body = html
        for (tag in listOf("article", "main")) {
            val match = ci("<$tag[\\s>][\\s\\S]*</$tag>").find(html)
            if (match != null && match.value.length > 500) { body = match.value; break }
        }
        for (tag in listOf("script", "style", "noscript", "svg", "nav", "footer", "header", "aside", "form", "template", "iframe")) {
            body = ci("<$tag[\\s>][\\s\\S]*?</$tag>").replaceIn(body, " ")
        }
        body = Regex("<!--[\\s\\S]*?-->").replaceIn(body, " ")
        body = ci("<h[1-6][^>]*>").replaceIn(body, "\n\n## ")
        body = ci("<li[^>]*>").replaceIn(body, "\n- ")
        body = ci("<(br|/p|/div|/h[1-6]|/tr|/li|/section|/table|p|div|tr)[^>]*>").replaceIn(body, "\n")
        body = ci("<(td|th)[^>]*>").replaceIn(body, " | ")
        body = Regex("<[^>]+>").replaceIn(body, "")
        body = decodeEntities(body)
        val lines = body.split("\n").map { Regex("[ \\t\\u00A0]+").replace(it, " ").trim() }
        val result = mutableListOf<String>()
        for (line in lines) {
            if (line.isEmpty() && (result.isEmpty() || result.last().isEmpty())) continue
            // A list marker whose text ended up on a later line: join them.
            if (line.isNotEmpty() && result.isNotEmpty()) {
                val last = result.lastIndex
                val previous = if (result[last].isEmpty() && last > 0) last - 1 else last
                if (result[previous] == "-" || result[previous] == "##") {
                    result[previous] = result[previous] + " " + line
                    while (result.size > previous + 1) result.removeAt(result.lastIndex)
                    continue
                }
            }
            result += line
        }
        return result.joinToString("\n").trim()
    }

    fun decodeEntities(text: String): String {
        var result = text
        for ((entity, character) in listOf("&nbsp;" to " ", "&amp;" to "&", "&lt;" to "<", "&gt;" to ">", "&quot;" to "\"", "&#39;" to "'",
            "&apos;" to "'", "&mdash;" to "—", "&ndash;" to "–", "&hellip;" to "…", "&rsquo;" to "’", "&lsquo;" to "‘", "&rdquo;" to "”", "&ldquo;" to "“")) {
            result = result.replace(entity, character)
        }
        return Regex("&#(x?)([0-9a-fA-F]+);").replace(result) { match ->
            val code = match.groupValues[2].toIntOrNull(if (match.groupValues[1] == "x") 16 else 10)
            if (code != null && Character.isValidCodePoint(code)) String(Character.toChars(code)) else match.value
        }
    }
}
