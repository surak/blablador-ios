package de.fz_juelich.blablador.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Google Docs, Sheets and Slides without any Google sign-in: documents shared as "anyone with the link" are read
 * through Google's export links. Native Google files can't be changed in place; results go back by pasting or as
 * new files.
 */
object GoogleDocs {
    enum class Kind { document, spreadsheets, presentation }

    data class Link(val kind: Kind, val id: String, val gid: String? = null)

    const val NOT_SHARED = "This Google file isn't shared as “anyone with the link”, so it can't be read without signing in to Google. " +
        "Ask the user to share it by link, or to download it (File → Download → Word, PDF or CSV) and attach it."

    /** The Google file a link points to, or null for other links. */
    fun link(address: String): Link? {
        val url = address.trim().toHttpUrlOrNull() ?: return null
        if (url.host.lowercase() != "docs.google.com") return null
        val parts = url.pathSegments
        val index = parts.indexOfFirst { part -> Kind.entries.any { it.name == part } }
        if (index < 0 || index + 2 >= parts.size || parts[index + 1] != "d") return null
        val id = parts[index + 2]
        if (id.length < 20 || !id.all { it.isLetterOrDigit() || it == '-' || it == '_' }) return null
        val gid = (url.fragment ?: url.query)?.split('&')?.firstOrNull { it.startsWith("gid=") }?.removePrefix("gid=")
        return Link(Kind.valueOf(parts[index]), id, gid)
    }

    /** Export addresses to try, best first: Markdown keeps a document's headings, lists and tables. */
    fun exports(link: Link): List<Pair<String, String>> {
        val base = "https://docs.google.com/${link.kind.name}/d/${link.id}/export"
        return when (link.kind) {
            Kind.document -> listOf("$base?format=md" to "md", "$base?format=txt" to "txt")
            Kind.spreadsheets -> listOf("$base?format=csv" + (link.gid?.let { "&gid=$it" } ?: "") to "csv")
            Kind.presentation -> listOf("$base?format=txt" to "txt")
        }
    }

    /** Reads a shared Google file as Markdown, CSV or text. */
    suspend fun read(link: Link, original: String): WebPage.Page = withContext(Dispatchers.IO) {
        val client = BlabladorApi.client.newBuilder().callTimeout(25, TimeUnit.SECONDS).build()
        var lastError: Exception = WebPage.PageException(NOT_SHARED)
        for ((address, _) in exports(link)) {
            try {
                val request = Request.Builder().url(address).header("User-Agent", "Mozilla/5.0 (compatible; Blablador)").build()
                client.newCall(request).await().use { response ->
                    val type = response.header("Content-Type").orEmpty().lowercase()
                    // Private files answer 401/403, or a sign-in page after redirects.
                    if (response.code == 401 || response.code == 403 || "html" in type || "accounts.google" in response.request.url.host) {
                        throw NotShared()
                    }
                    if (!response.isSuccessful) throw BlabladorException(response.code, "Google couldn't export this file.")
                    val text = response.body?.string().orEmpty().trim()
                    val first = text.lineSequence().firstOrNull()?.replace("#", "")?.trim()?.take(80)
                    val name = when (link.kind) {
                        Kind.document -> "Google Doc"
                        Kind.spreadsheets -> "Google Sheet (CSV)"
                        Kind.presentation -> "Google Slides"
                    }
                    return@withContext WebPage.Page(listOfNotNull(name, first?.ifEmpty { null }).joinToString(": "), original, text.take(WebPage.MAX_CHARACTERS))
                }
            } catch (e: NotShared) {
                throw WebPage.PageException(NOT_SHARED)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                lastError = e
            }
        }
        throw lastError
    }

    private class NotShared : Exception()
}
